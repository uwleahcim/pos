"""The resolver: load, validate, price, route, explode, derive allergens, snapshot.

`MenuEngine.resolve` is a pure function of (definitions, live availability, request, time, locale).
Every derived value carries its provenance, and anything wrong with a request comes back as a
`Problem` on the line rather than an exception, so a screen can show it inline.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from .defs import (
    ONE,
    Availability,
    Definitions,
    Entry,
    Group,
    Item,
    Option,
    UnitError,
    Variant,
    dec,
    menu_open,
    money,
)
from .request import ComponentRequest, LineRequest, Selection
from .resolved import (
    AllergenProfile,
    CostBreakdown,
    EffectResult,
    IngredientUsage,
    KitchenLine,
    Problem,
    ResolvedLine,
    ResolvedModifier,
    Snapshot,
)

ENGINE_VERSION = "0.1.0"
ZERO = Decimal(0)


@dataclass
class Working:
    """A component of the working recipe, before explosion."""

    ref: str
    qty: Decimal
    unit: str
    role: str | None
    source: str
    scales: bool = True


@dataclass
class _Usage:
    unit: str
    qty: Decimal = ZERO
    purchased: Decimal = ZERO
    cost: Decimal = ZERO


@dataclass
class _Ctx:
    item: Item
    variant: Variant
    at: datetime
    locale: str
    header: str | None
    preset_defaults: Mapping[str, str]
    working: list[Working] = field(default_factory=list)
    children: list[ResolvedLine] = field(default_factory=list)
    problems: list[Problem] = field(default_factory=list)
    stations: set[str] = field(default_factory=set)
    depth: int = 0  # how many slots and components above this dish
    fold_into: str | None = None  # the parent's station, whose line names this slot dish among its choices


@dataclass(frozen=True)
class VariantOffer:
    variant_id: str
    name: str
    price: Decimal
    price_source: str
    status: str


@dataclass(frozen=True)
class ResolvedEntry:
    entry_id: str
    number: str | None
    item: str
    name: str
    variants: tuple[VariantOffer, ...]
    contains: tuple[str, ...]
    may_contain: tuple[str, ...]
    featured: bool = False
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class ResolvedSection:
    section_id: str
    name: str
    entries: tuple[ResolvedEntry, ...]
    sections: tuple[ResolvedSection, ...] = ()


@dataclass(frozen=True)
class ResolvedMenu:
    menu: str
    name: str
    priority: int
    sections: tuple[ResolvedSection, ...]


@dataclass(frozen=True)
class Hit:
    item: str
    name: str
    matched_on: str
    score: int
    entry_id: str | None = None
    number: str | None = None


@dataclass(frozen=True)
class OptionDetail:
    option_id: str
    name: str
    price: Decimal
    price_mode: str
    is_default: bool
    linked_variant: str | None
    status: str
    kitchen_label: str | None
    linked_item: str | None = None
    groups: tuple[GroupDetail, ...] = ()
    """A linked dish's own groups, as this slot exposes them: the questions to ask once the option is chosen,
    answered in the selection's `children`. The screen reveals one level at a time."""


@dataclass(frozen=True)
class GroupDetail:
    group_id: str
    name: str
    min_select: int
    max_select: int | None
    free_count: int
    allow_quantity: bool
    options: tuple[OptionDetail, ...]


MAX_DEPTH = 8
"""How deep a dish may nest through slots and components before the engine stops: a combo in a combo in a
combo is data, a dish that offers itself is a mistake `check` reports."""


@dataclass(frozen=True)
class ItemDetail:
    item: str
    name: str
    kind: str
    variants: tuple[VariantOffer, ...]
    groups: tuple[GroupDetail, ...]
    tax_class: str
    station: str | None


def all_problems(line: ResolvedLine) -> Iterable[Problem]:
    yield from line.problems
    for child in line.children:
        yield from all_problems(child)


def flatten_modifiers(mods: Iterable[ResolvedModifier]) -> Iterable[ResolvedModifier]:
    for mod in mods:
        yield mod
        yield from flatten_modifiers(mod.children)


def ticket_labels(mods: Iterable[ResolvedModifier], depth: int = 0) -> Iterable[tuple[int, str]]:
    """The choices a ticket lists under a dish, each with how far in it prints. A choice the dish comes with
    and nobody changed (`defaulted`) is left off: the station knows the dish. It is listed after all when
    something under it changed, so the change reads under the choice it is on, one step further in."""
    for mod in mods:
        named = bool(mod.kitchen_label)
        inner_depth = depth + 1 if named else depth
        inner = [(inner_depth + d, text) for d, text in mod.under]
        inner.extend(ticket_labels(mod.children, inner_depth))
        if named and (inner or not mod.defaulted):
            yield depth, mod.kitchen_label
        yield from inner


def one_line(labels: Sequence[tuple[int, str]]) -> str:
    """`ticket_labels` on one line, a choice's own choices in brackets after it: `White Rice · Miso (No tofu)`."""
    out: list[str] = []
    i = 0
    while i < len(labels):
        depth, text = labels[i]
        j = i + 1
        while j < len(labels) and labels[j][0] > depth:
            j += 1
        out.append(f"{text} ({one_line(labels[i + 1 : j])})" if j > i + 1 else text)
        i = j
    return " · ".join(out)


PREFIXES: dict[str, str] = {"no": "NO", "extra": "EXTRA", "side": "SIDE", "light": "LIGHT"}
"""The one-tap instructions a selection may carry (`Selection.prefix`), printed in front of the option's
kitchen label: NO 加虾, SIDE 糙米. "no" also makes the option free and skips its recipe effects; the other
three keep the option's price and effects. A price per instruction waits for a real need."""


def prefixed_label(prefix: str | None, kitchen_label: str | None, name: str) -> str:
    """The kitchen label with its instruction in front. An option without a kitchen label prints only when
    it carries an instruction, under its name."""
    if prefix is None:
        return kitchen_label or ""
    return f"{PREFIXES[prefix]} {kitchen_label or name}"


class MenuEngine:
    def __init__(self, defs: Definitions, now=None) -> None:
        self.defs = defs
        self.availability: dict[str, Availability] = {}
        self._now = now or (lambda: datetime.now(UTC))

    # --- live state ----------------------------------------------------------------------------

    def set_availability(
        self,
        target_id: str,
        status: str,
        until: datetime | None = None,
        reason: str | None = None,
        by: str | None = None,
    ) -> None:
        if status == "available":
            self.availability.pop(target_id, None)
            return
        self.availability[target_id] = Availability(target_id, status, until, reason, by, self._now())

    def status_of(self, target_id: str, at: datetime | None = None) -> str:
        state = self.availability.get(target_id)
        if state is None:
            return "available"
        if state.until is not None and (at or self._now()) >= state.until:
            return "available"
        return state.status

    # --- ordering ------------------------------------------------------------------------------

    def resolve(self, request: LineRequest, at: datetime | None = None, locale: str = "en") -> ResolvedLine:
        return self._resolve(
            variant_id=request.variant_id,
            qty=request.qty,
            selections=request.selections,
            components=request.components,
            notes=request.notes,
            entry_id=request.menu_entry_id,
            origin="line",
            at=at or self._now(),
            locale=locale,
        )

    def validate(self, request: LineRequest, at: datetime | None = None) -> list[Problem]:
        return list(all_problems(self.resolve(request, at)))

    def _resolve(
        self,
        *,
        variant_id: str,
        qty: int,
        selections: tuple[Selection, ...],
        components: tuple[ComponentRequest, ...],
        notes: str | None,
        at: datetime,
        locale: str,
        entry_id: str | None = None,
        origin: str = "line",
        unit_price: Decimal | None = None,
        expose: Any = "all",
        preset_defaults: Mapping[str, str] | None = None,
        locked: bool = False,
        component_id: str | None = None,
        option_id: str | None = None,
        header: str | None = None,
        depth: int = 0,
        fold_into: str | None = None,
    ) -> ResolvedLine:
        defs = self.defs
        loc = defs.localizer
        variant = defs.variants.get(variant_id)
        if variant is None:
            return self._broken(
                variant_id, qty, entry_id, origin, at, Problem("unknown_variant", f"no variant {variant_id}")
            )
        if depth > MAX_DEPTH:
            return self._broken(
                variant_id,
                qty,
                entry_id,
                origin,
                at,
                Problem("too_deep", f"{variant_id} nests deeper than {MAX_DEPTH}"),
            )
        item = defs.items[variant.item]
        ctx = _Ctx(item, variant, at, locale, header, dict(preset_defaults or {}), depth=depth, fold_into=fold_into)
        entry = defs.entry(entry_id) if entry_id else None

        # --- validate the head of the request
        if entry_id and entry is None:
            ctx.problems.append(Problem("unknown_entry", f"no menu entry {entry_id}"))
        if entry and entry.item != item.code:
            ctx.problems.append(Problem("entry_mismatch", f"{entry.id} is {entry.item}, not {item.code}"))
        elif entry and entry.variants is not None and variant_id not in entry.variants:
            ctx.problems.append(Problem("variant_not_offered", f"{variant_id} is not offered on {entry.id}"))
        if qty < 1:
            ctx.problems.append(Problem("qty", "quantity must be at least 1"))
            qty = 1
        if not variant.active or not item.active:
            ctx.problems.append(Problem("inactive", f"{variant_id} is not active"))
        status = self.status_of(variant_id, at)
        if status != "available":
            ctx.problems.append(Problem("sold_out", f"{variant_id} is {status}"))

        # --- price of the line itself
        if origin == "line":
            if entry and variant_id in entry.price_overrides:
                unit_price, price_source = money(entry.price_overrides[variant_id]), "entry_override"
            else:
                unit_price, price_source = money(variant.base_price), "variant_base"
        elif origin == "slot":
            unit_price, price_source = money(unit_price or ZERO), "slot"
        else:
            unit_price, price_source = ZERO, "included"

        # --- the recipe: ingredient components to the working list, nested items to child lines
        kitchen_name = loc.kitchen(item.names)
        own_header = f"{entry.number} {kitchen_name}" if entry and entry.number else kitchen_name
        recipe, scaled = defs.recipe_for_variant(variant)
        scale = variant.recipe_scale if scaled else ONE
        requests = {c.component_id: c for c in components}
        if recipe:
            for comp in sorted(recipe.components, key=lambda c: c.sort):
                amount = comp.qty * (scale if comp.scales else ONE)
                if comp.kind == "ingredient":
                    ctx.working.append(
                        Working(comp.ref, amount, comp.unit, comp.role, f"recipe:{comp.id}", comp.scales)
                    )
                    continue
                req = requests.pop(comp.id, None)
                if amount != amount.to_integral_value():
                    if req is not None:
                        ctx.problems.append(
                            Problem(
                                "locked",
                                f"{comp.id} is a fractional portion and cannot be customized",
                                component_id=comp.id,
                            )
                        )
                    self._inline(comp.ref, amount, comp.id, ctx)
                    continue
                if comp.locked and req is not None and (req.selections or req.components):
                    ctx.problems.append(Problem("locked", f"{comp.id} is locked on this dish", component_id=comp.id))
                    req = None
                ctx.children.append(
                    self._resolve(
                        variant_id=comp.ref,
                        qty=int(amount),
                        selections=req.selections if req else (),
                        components=req.components if req else (),
                        notes=req.notes if req else None,
                        at=at,
                        locale=locale,
                        origin="component",
                        preset_defaults=comp.defaults,
                        locked=comp.locked,
                        component_id=comp.id,
                        header=own_header,
                        depth=depth + 1,
                    )
                )
        for comp_id in requests:
            ctx.problems.append(
                Problem("unknown_component", f"{comp_id} is not a component of {variant_id}", component_id=comp_id)
            )
        for override in variant.component_overrides:
            ctx.working = [w for w in ctx.working if w.role != override.role]
            ctx.working.append(
                Working(
                    override.ingredient, override.qty, override.unit, override.role, f"override:{variant.id}", False
                )
            )

        # --- modifier groups: the item's, filtered by what a slot exposes
        attached = defs.attachments_for(item.code)
        if expose == "none":
            groups = []
        elif expose == "all":
            groups = attached
        else:
            groups = [(g, o) for g, o in attached if g.code in set(expose)]
        group_map = {g.code: (g, o) for g, o in groups}
        by_group: dict[str, list[Selection]] = {}
        for sel in selections:
            if sel.group_id not in group_map:
                why = "is locked on this slot" if expose == "none" else f"is not offered on {item.code}"
                ctx.problems.append(Problem("group_not_attached", f"{sel.group_id} {why}", group_id=sel.group_id))
                continue
            by_group.setdefault(sel.group_id, []).append(sel)
        station = defs.inherited(item, "station")
        if station:
            ctx.stations.add(station)
        modifiers: list[ResolvedModifier] = []
        for group, overrides in groups:
            modifiers.extend(self._apply_group(ctx, group, overrides, by_group.get(group.code, []), own_header))

        # --- explode, cost, allergens, kitchen lines, totals
        usage, own_cost = self._explode(ctx.working, qty, ctx.problems)
        children = tuple(ctx.children)
        allergens = self._allergens({u.ingredient for u in usage}, ctx.stations, item, variant, children)
        kitchen = self._kitchen_lines(ctx, item, variant, qty, modifiers, children, origin, header, kitchen_name, notes)
        if origin == "slot" and fold_into:
            # the slot's label on the parent's line carries this dish and its choices (`_slot`)
            kitchen = tuple(
                k for k in kitchen if not (k.origin == "slot" and k.station == fold_into and k.header == header)
            )
        modifier_total = sum((m.price_delta for m in modifiers), ZERO)
        children_total = sum((c.line_total for c in children), ZERO)
        line_total = money((unit_price + modifier_total + children_total) * qty)
        cost = money(own_cost + sum((c.cost for c in children), ZERO))
        return ResolvedLine(
            variant_id=variant_id,
            menu_entry_id=entry_id,
            qty=qty,
            names=dict(item.names),
            variant_names=dict(variant.names),
            unit_price=unit_price,
            price_source=price_source,
            modifiers=tuple(modifiers),
            children=children,
            line_total=line_total,
            tax_class=defs.inherited(item, "tax_class"),
            kitchen_lines=kitchen,
            usage=usage,
            allergens=allergens,
            cost=cost,
            snapshot=Snapshot(recipe.id if recipe else None, at, ENGINE_VERSION),
            problems=tuple(ctx.problems),
            origin=origin,
            component_id=component_id,
            option_id=option_id,
            locked=locked,
            notes=notes,
        )

    def _broken(
        self, variant_id: str, qty: int, entry_id: str | None, origin: str, at: datetime, problem: Problem
    ) -> ResolvedLine:
        return ResolvedLine(
            variant_id=variant_id,
            menu_entry_id=entry_id,
            qty=qty,
            names={},
            variant_names={},
            unit_price=ZERO,
            price_source="variant_base",
            modifiers=(),
            children=(),
            line_total=ZERO,
            tax_class="",
            kitchen_lines=(),
            usage=(),
            allergens=AllergenProfile(),
            cost=ZERO,
            snapshot=Snapshot(None, at, ENGINE_VERSION),
            problems=(problem,),
            origin=origin,
        )

    def _inline(self, variant_id: str, portion: Decimal, comp_id: str, ctx: _Ctx) -> None:
        """A fractional nested dish: its recipe folded into the working list, no customization."""
        variant = self.defs.variants.get(variant_id)
        if variant is None:
            ctx.problems.append(Problem("unknown_variant", f"{comp_id}: no variant {variant_id}", component_id=comp_id))
            return
        recipe, scaled = self.defs.recipe_for_variant(variant)
        if recipe is None:
            return
        scale = (variant.recipe_scale if scaled else ONE) * portion
        for comp in recipe.components:
            if comp.kind == "ingredient":
                ctx.working.append(
                    Working(
                        comp.ref,
                        comp.qty * (scale if comp.scales else portion),
                        comp.unit,
                        comp.role,
                        f"inline:{comp_id}",
                        comp.scales,
                    )
                )
            else:
                self._inline(comp.ref, comp.qty * scale, comp.id, ctx)
        nested_station = self.defs.inherited(self.defs.items[variant.item], "station")
        if nested_station:
            ctx.stations.add(nested_station)

    def _apply_group(
        self, ctx: _Ctx, group: Group, overrides: Mapping[str, Any], chosen: list[Selection], own_header: str
    ) -> list[ResolvedModifier]:
        defs = self.defs
        options = {o.code: o for o in defs.options_of(group.code)}
        hidden = set(overrides.get("hidden", ()))
        prices = overrides.get("prices", {})
        min_select = overrides.get("min", group.min_select)
        max_select = overrides.get("max", group.max_select)
        defaulted = False
        named = ctx.preset_defaults.get(group.code) or overrides.get("default")
        if not chosen:
            default = named
            if default is None:
                default = next(
                    (o.code for o in options.values() if o.is_default and o.active and o.code not in hidden), None
                )
            if default is not None and default in options:
                chosen = [Selection(group.code, options[default].id, 1)]
                defaulted = True
            elif min_select > 0:
                ctx.problems.append(Problem("too_few", f"{group.code} needs a choice", group_id=group.code))
                return []
        results: list[ResolvedModifier] = []
        units = 0
        free_left = group.free_count
        seen: set[str] = set()
        for sel in chosen:
            opt = defs.options.get(sel.option_id)
            units += max(sel.qty, 1)  # a rejected choice still counts: the rejection is the problem, not too_few
            if opt is None or opt.group != group.code:
                ctx.problems.append(
                    Problem(
                        "unknown_option",
                        f"{sel.option_id} is not in {group.code}",
                        group_id=group.code,
                        option_id=sel.option_id,
                    )
                )
                continue
            if not opt.active or opt.code in hidden:
                ctx.problems.append(
                    Problem("option_hidden", f"{opt.id} is not offered here", group_id=group.code, option_id=opt.id)
                )
                continue
            if self.status_of(opt.id, ctx.at) != "available":
                ctx.problems.append(Problem("sold_out", f"{opt.id} is sold out", group_id=group.code, option_id=opt.id))
                continue
            if opt.code in seen and not group.allow_duplicates:
                ctx.problems.append(
                    Problem("duplicate", f"{opt.id} chosen twice", group_id=group.code, option_id=opt.id)
                )
                continue
            seen.add(opt.code)
            sq = sel.qty
            if sq < 1:
                ctx.problems.append(Problem("qty", f"{opt.id}: quantity must be at least 1", option_id=opt.id))
                sq = 1
            if sq > 1 and not group.allow_quantity:
                ctx.problems.append(
                    Problem("qty", f"{group.code} does not take quantities", group_id=group.code, option_id=opt.id)
                )
                sq = 1
            if opt.max_qty is not None and sq > opt.max_qty:
                ctx.problems.append(Problem("max_qty", f"{opt.id}: at most {opt.max_qty}", option_id=opt.id))
                sq = opt.max_qty
            units += sq - max(sel.qty, 1)  # settle the count on the clamped quantity
            price = money(prices.get(opt.code, opt.price))
            prefix = sel.prefix
            if prefix is not None and prefix not in PREFIXES:
                ctx.problems.append(
                    Problem("bad_prefix", f"{opt.id}: no instruction {prefix!r}", group_id=group.code, option_id=opt.id)
                )
                prefix = None
            label = prefixed_label(
                prefix, defs.option_kitchen_label(opt), defs.localizer.text(defs.option_names(opt), "en")
            )
            # The dish's default picked by hand (a screen sends the defaults it filled in) is the default all
            # the same; with a word on it or more than one of it, it is a change.
            standing = (opt.code == named) if named else opt.is_default
            as_default = defaulted or (standing and prefix is None and sq == 1)
            if opt.linked_variant:
                results.append(self._slot(ctx, group, overrides, opt, sel, sq, price, as_default, own_header, label))
                continue
            if opt.price_mode == "free" or prefix == "no":
                delta = ZERO
            elif opt.price_mode == "delta":
                free_units = min(free_left, sq)
                free_left -= free_units
                delta = money(price * (sq - free_units))
            else:  # absolute: charged as-is, outside the free count
                delta = money(price * sq)
            if prefix == "no":
                # "no shrimp": nothing goes into the dish, so nothing comes out of inventory
                effects = tuple(
                    EffectResult(effect.op, effect.role or effect.ingredient or "", "no_op", "no")
                    for effect in opt.effects
                )
            else:
                effects = tuple(self._apply_effect(ctx, effect, opt, sq) for effect in opt.effects)
            if opt.station:
                ctx.stations.add(opt.station)
            children: list[ResolvedModifier] = []
            child_by_group: dict[str, list[Selection]] = {}
            for child in sel.children:
                if child.group_id not in opt.child_groups:
                    ctx.problems.append(
                        Problem(
                            "group_not_attached",
                            f"{child.group_id} is not a question under {opt.id}",
                            group_id=child.group_id,
                        )
                    )
                    continue
                child_by_group.setdefault(child.group_id, []).append(child)
            for code in opt.child_groups:
                child_group = defs.groups.get(code)
                if child_group is None:
                    ctx.problems.append(Problem("unknown_group", f"{opt.id} asks unknown group {code}", group_id=code))
                    continue
                children.extend(self._apply_group(ctx, child_group, {}, child_by_group.get(code, []), own_header))
            results.append(
                ResolvedModifier(
                    group.code,
                    opt.id,
                    sq,
                    label,
                    delta,
                    effects,
                    tuple(children),
                    as_default,
                    opt.station,
                    prefix,
                    opt.routes_to,
                )
            )
        if max_select is not None and units > max_select:
            ctx.problems.append(Problem("too_many", f"{group.code} takes at most {max_select}", group_id=group.code))
        if units < min_select:
            ctx.problems.append(Problem("too_few", f"{group.code} needs at least {min_select}", group_id=group.code))
        return results

    def _slot(
        self,
        ctx: _Ctx,
        group: Group,
        overrides: Mapping[str, Any],
        opt: Option,
        sel: Selection,
        sq: int,
        price: Decimal,
        defaulted: bool,
        own_header: str,
        label: str,
    ) -> ResolvedModifier:
        """A slot option: the linked variant becomes a child line priced by the slot's mode."""
        linked = self.defs.variants.get(opt.linked_variant or "")
        if opt.price_mode == "linked":
            child_price = money(linked.base_price) if linked else ZERO
        elif opt.price_mode == "free":
            child_price = ZERO
        else:
            child_price = price
        expose = overrides.get("expose_linked_groups", "all")
        # A dish that prints its own line (not a combo) names the slot's dish among its choices, so the dish's
        # own line at the same station would say it twice: it folds into the parent's. At another station
        # (the soup with a lunch special) it prints there, under the parent's header.
        parent_station = self.defs.inherited(ctx.item, "station") if ctx.item.kind != "combo" else None
        child = self._resolve(
            variant_id=opt.linked_variant or "",
            qty=sq,
            selections=sel.children,
            components=sel.components,
            notes=sel.notes,
            at=ctx.at,
            locale=ctx.locale,
            origin="slot",
            unit_price=child_price,
            expose=expose,
            preset_defaults=overrides.get("child_defaults"),
            locked=expose == "none",
            option_id=opt.id,
            header=own_header,
            depth=ctx.depth + 1,
            fold_into=parent_station,
        )
        ctx.children.append(child)
        if not label:
            label = self.defs.localizer.kitchen(child.names) or self.defs.localizer.text(child.names, "en")
        under = list(ticket_labels(child.modifiers))
        if child.notes:
            under.append((0, child.notes))  # the note on the dish reads with it, on whichever line names it
        return ResolvedModifier(group.code, opt.id, sq, label, ZERO, (), (), defaulted, None, under=tuple(under))

    def _apply_effect(self, ctx: _Ctx, effect: Any, opt: Option, sq: int) -> EffectResult:
        defs = self.defs
        work = ctx.working
        target = effect.role or effect.ingredient or ""
        if effect.op == "note":
            return EffectResult("note", opt.kitchen_label or opt.code, "applied", "kitchen label only")
        if effect.op == "add":
            ing = defs.ingredients.get(effect.ingredient or "")
            if ing is None:
                return EffectResult("add", target, "error", "unknown ingredient")
            work.append(
                Working(
                    ing.code,
                    dec(effect.qty or 1) * sq,
                    effect.unit or ing.base_unit,
                    effect.role,
                    f"add:{opt.id}",
                    False,
                )
            )
            return EffectResult(
                "add", ing.code, "applied", f"+{dec(effect.qty or 1) * sq} {effect.unit or ing.base_unit}"
            )
        matches = [
            w
            for w in work
            if (effect.role and w.role == effect.role) or (effect.ingredient and w.ref == effect.ingredient)
        ]
        if effect.op == "remove":
            if not matches:
                return EffectResult("remove", target, "no_op", "nothing to remove")
            for w in matches:
                work.remove(w)
            return EffectResult("remove", target, "applied", "removed " + ", ".join(w.ref for w in matches))
        if effect.op == "scale":
            if not matches:
                return EffectResult("scale", target, "no_op", "nothing to scale")
            factor = ONE + (dec(effect.factor or 1) - ONE) * sq
            for w in matches:
                w.qty = w.qty * factor
            return EffectResult("scale", target, "applied", f"x{factor}")
        if effect.op == "substitute":
            ing = defs.ingredients.get(effect.ingredient or "")
            if ing is None:
                return EffectResult("substitute", target, "error", "unknown replacement ingredient")
            if not matches:
                return EffectResult(
                    "substitute", target, "no_op", f"no component with role {effect.role}; kitchen note still prints"
                )
            if effect.qty is not None:
                qty, unit = dec(effect.qty) * sq, effect.unit or ing.base_unit
            else:
                if any(not defs.same_dimension(w.unit, ing.base_unit) for w in matches):
                    return EffectResult(
                        "substitute", target, "error", "replacement cannot inherit a quantity across dimensions"
                    )
                try:
                    qty = sum((defs.convert(w.qty, w.unit, ing) for w in matches), ZERO)
                except UnitError as err:
                    return EffectResult("substitute", target, "error", str(err))
                unit = ing.base_unit
            for w in matches:
                work.remove(w)
            work.append(Working(ing.code, qty, unit, effect.role or matches[0].role, f"substitute:{opt.id}", False))
            removed = ", ".join(w.ref for w in matches)
            return EffectResult("substitute", target, "applied", f"{removed} -> {qty} {unit} {ing.code}")
        return EffectResult(effect.op, target, "error", "unknown effect")

    # --- explosion -----------------------------------------------------------------------------

    def _explode(
        self, working: list[Working], line_qty: int, problems: list[Problem]
    ) -> tuple[tuple[IngredientUsage, ...], Decimal]:
        """Usage of one unit of the line, scaled by its quantity. Costs are exact; round them for display."""
        acc: dict[str, _Usage] = {}
        for w in working:
            ing = self.defs.ingredients.get(w.ref)
            if ing is None:
                problems.append(Problem("unknown_ingredient", f"no ingredient {w.ref} ({w.source})"))
                continue
            try:
                base_qty = self.defs.convert(w.qty, w.unit, ing)
            except UnitError as err:
                problems.append(Problem("unit", str(err)))
                continue
            self._expand(ing, base_qty, acc, 0, problems, ())
        usage = tuple(
            IngredientUsage(code, u.qty * line_qty, u.purchased * line_qty, u.unit, u.cost * line_qty)
            for code, u in sorted(acc.items())
        )
        return usage, sum((u.cost for u in usage), ZERO)

    def _expand(
        self,
        ing: Any,
        base_qty: Decimal,
        acc: dict[str, _Usage],
        depth: int,
        problems: list[Problem],
        seen: tuple[str, ...],
    ) -> None:
        if ing.kind == "prep" and ing.code not in seen:
            recipe = self.defs.current_recipe("ingredient", ing.code)
            if recipe is not None:
                batch = recipe.yield_qty
                if recipe.yield_unit and recipe.yield_unit != ing.base_unit:
                    try:
                        batch = self.defs.convert(recipe.yield_qty, recipe.yield_unit, ing)
                    except UnitError as err:
                        problems.append(Problem("unit", str(err)))
                share = base_qty / batch if batch else ZERO
                for comp in recipe.components:
                    child = self.defs.ingredients.get(comp.ref) if comp.kind == "ingredient" else None
                    if child is None:
                        problems.append(Problem("unknown_ingredient", f"{ing.code} uses unknown component {comp.ref}"))
                        continue
                    try:
                        child_qty = self.defs.convert(comp.qty, comp.unit, child) * share
                    except UnitError as err:
                        problems.append(Problem("unit", str(err)))
                        continue
                    self._expand(child, child_qty, acc, depth + 1, problems, (*seen, ing.code))
                return
        usage = acc.setdefault(ing.code, _Usage(ing.base_unit))
        purchased = base_qty / (ing.yield_pct / 100) if depth == 0 and ing.yield_pct else base_qty
        usage.qty += base_qty
        usage.purchased += purchased
        usage.cost += purchased * ing.cost_per_base_unit

    def explode(self, line: ResolvedLine) -> list[IngredientUsage]:
        """Usage of the whole tree, aggregated by ingredient."""
        acc: dict[str, _Usage] = {}

        def walk(node: ResolvedLine) -> None:
            for u in node.usage:
                a = acc.setdefault(u.ingredient, _Usage(u.unit))
                a.qty += u.qty
                a.purchased += u.purchased
                a.cost += u.cost
            for child in node.children:
                walk(child)

        walk(line)
        return [IngredientUsage(code, u.qty, u.purchased, u.unit, u.cost) for code, u in sorted(acc.items())]

    # --- allergens -----------------------------------------------------------------------------

    def _allergens(
        self,
        ingredients: set[str],
        stations: set[str],
        item: Item,
        variant: Variant,
        children: tuple[ResolvedLine, ...],
    ) -> AllergenProfile:
        defs = self.defs
        tracked = set(defs.allergens)
        contains: set[str] = set()
        may: set[str] = set()
        forced_free: set[str] = set()
        sources: dict[str, list[str]] = {}
        reviewed = True
        for code in sorted(ingredients):
            ing = defs.ingredients[code]
            if ing.allergens_reviewed_at is None:
                reviewed = False
            for decl in ing.allergens:
                (contains if decl.level == "contains" else may).add(decl.allergen)
                sources.setdefault(decl.allergen, []).append(f"{code}:{decl.level}")
        for code in sorted(stations):
            station = defs.stations.get(code)
            for allergen in sorted(station.cross_contact) if station else ():
                may.add(allergen)
                sources.setdefault(allergen, []).append(f"station:{code}")
        for child in children:
            contains |= child.allergens.contains
            may |= child.allergens.may_contain
            if child.allergens.unknown:
                reviewed = False
            for allergen, src in child.allergens.sources.items():
                sources.setdefault(allergen, []).extend(f"{child.variant_id}/{s}" for s in src)
        overrides = [o for o in defs.overrides if o.owner_kind == "item" and o.owner == item.code]
        overrides += [o for o in defs.overrides if o.owner_kind == "variant" and o.owner == variant.id]
        for ov in overrides:
            contains.discard(ov.allergen)
            may.discard(ov.allergen)
            forced_free.discard(ov.allergen)
            {"contains": contains, "may_contain": may, "free": forced_free}[ov.level].add(ov.allergen)
            sources[ov.allergen] = [f"override:{ov.owner_kind}:{ov.reason}"]
        may -= contains
        rest = (tracked - contains - may) if tracked else set()
        free = (rest if reviewed else set()) | (forced_free - contains - may)
        unknown = rest - free
        return AllergenProfile(
            frozenset(contains),
            frozenset(may),
            frozenset(free),
            frozenset(unknown),
            {k: tuple(v) for k, v in sources.items()},
        )

    # --- kitchen -------------------------------------------------------------------------------

    def _kitchen_lines(
        self,
        ctx: _Ctx,
        item: Item,
        variant: Variant,
        qty: int,
        modifiers: list[ResolvedModifier],
        children: tuple[ResolvedLine, ...],
        origin: str,
        header: str | None,
        kitchen_name: str,
        notes: str | None = None,
    ) -> tuple[KitchenLine, ...]:
        loc = self.defs.localizer
        lines: list[KitchenLine] = []
        station = self.defs.inherited(item, "station")
        listed = tuple(ticket_labels(modifiers))
        labels = tuple(text for _, text in listed)
        depths = tuple(depth for depth, _ in listed)
        own = not (item.kind == "combo" and children)
        if own and station:
            text = f"{qty} {kitchen_name}"
            if len(self.defs.variants_of(item.code)) > 1:
                text += f" ({loc.kitchen(variant.names)})"
            if listed:
                text += " · " + one_line(listed)
            lines.append(
                KitchenLine(
                    station, qty, text, labels, header if origin != "line" else None, origin, note=notes, depths=depths
                )
            )
        for mod in flatten_modifiers(modifiers):
            if mod.station and mod.station != station:
                lines.append(
                    KitchenLine(
                        mod.station,
                        qty * mod.qty,
                        f"{qty * mod.qty} {mod.kitchen_label or mod.option_id}",
                        (),
                        header,
                        "modifier",
                    )
                )
        for child in children:
            for kl in child.kitchen_lines:
                lines.append(kl)
        # A choice that sends the dish somewhere else as well ("take out" to the takeout station): the whole
        # dish, with its choices, prints there too, as it does at its own station.
        routed = {m.routes_to for m in flatten_modifiers(modifiers) if m.routes_to}
        for station_code in sorted(routed):
            for kl in list(lines):
                if kl.origin in ("line", "slot", "component") and kl.station != station_code:
                    lines.append(replace(kl, station=station_code, origin="route"))
            if not any(kl.station == station_code for kl in lines):
                text = f"{qty} {kitchen_name}" + (" · " + one_line(listed) if listed else "")
                lines.append(KitchenLine(station_code, qty, text, labels, header, "route", note=notes, depths=depths))
        return tuple(lines)

    # --- inventory and reporting --------------------------------------------------------------

    def cost(
        self, variant_id: str, selections: tuple[Selection, ...] = (), entry_id: str | None = None
    ) -> CostBreakdown:
        line = self.resolve(LineRequest(variant_id, 1, entry_id, selections))
        return CostBreakdown(
            variant_id,
            line.line_total,
            line.cost,
            money(line.line_total - line.cost),
            line.food_cost_pct,
            tuple(self.explode(line)),
        )

    def dependents(self, ingredient_id: str) -> list[str]:
        """Variants that use an ingredient, through preps, nested dishes and combo slots."""
        defs = self.defs
        result: set[str] = set()
        frontier: list[tuple[str, str]] = [("ingredient", ingredient_id)]
        seen: set[tuple[str, str]] = set()
        while frontier:
            kind, ref = frontier.pop()
            if (kind, ref) in seen:
                continue
            seen.add((kind, ref))
            if kind == "ingredient":
                for variant in defs.variants.values():
                    if any(o.ingredient == ref for o in variant.component_overrides):
                        result.add(variant.id)
                        frontier.append(("variant", variant.id))
            for recipe in defs.recipes:
                if not recipe.is_current or not any(c.kind == kind and c.ref == ref for c in recipe.components):
                    continue
                if recipe.owner_kind == "ingredient":
                    frontier.append(("ingredient", recipe.owner))
                elif recipe.owner_kind == "variant":
                    result.add(recipe.owner)
                    frontier.append(("variant", recipe.owner))
                else:
                    for variant in defs.variants_of(recipe.owner):
                        result.add(variant.id)
                        frontier.append(("variant", variant.id))
            if kind == "variant":
                for opt in defs.options.values():
                    if opt.linked_variant != ref:
                        continue
                    for att in defs.attachments:
                        if att.group != opt.group or att.excluded:
                            continue
                        owners = (
                            [att.owner]
                            if att.owner_kind == "item"
                            else [
                                i.code
                                for i in defs.items.values()
                                if att.owner in {c.code for c in defs.category_chain(i.category)}
                            ]
                        )
                        for code in owners:
                            for variant in defs.variants_of(code):
                                result.add(variant.id)
                                frontier.append(("variant", variant.id))
        return sorted(result)

    # --- presentation --------------------------------------------------------------------------

    def _offers(self, item: Item, entry: Entry | None, at: datetime, locale: str) -> tuple[VariantOffer, ...]:
        loc = self.defs.localizer
        offers = []
        for variant in self.defs.variants_of(item.code):
            if not variant.active or (entry and entry.variants is not None and variant.id not in entry.variants):
                continue
            if entry and variant.id in entry.price_overrides:
                price, source = money(entry.price_overrides[variant.id]), "entry_override"
            else:
                price, source = money(variant.base_price), "variant_base"
            offers.append(
                VariantOffer(variant.id, loc.text(variant.names, locale), price, source, self.status_of(variant.id, at))
            )
        return tuple(offers)

    def menu_for(self, channel: str, at: datetime | None = None, locale: str = "en") -> list[ResolvedMenu]:
        at = at or self._now()
        loc = self.defs.localizer
        result = []
        for menu in sorted(self.defs.menus.values(), key=lambda m: (-m.priority, m.code)):
            if not menu.active or channel not in menu.channels or not menu_open(menu, at):
                continue
            sections = self._sections(menu, self.defs.entries_of(menu.code), None, at, locale)
            result.append(ResolvedMenu(menu.code, loc.text(menu.names, locale), menu.priority, sections))
        return result

    def _sections(
        self, menu: Any, entries: Sequence[Entry], parent: str | None, at: datetime, locale: str
    ) -> tuple[ResolvedSection, ...]:
        loc = self.defs.localizer
        out = []
        for section in sorted(
            (s for s in self.defs.sections.values() if s.menu == menu.code and s.parent == parent),
            key=lambda s: s.sort,
        ):
            rows = []
            for entry in entries:
                if entry.section != section.id or not entry.visible or entry.item not in self.defs.items:
                    continue
                item = self.defs.items[entry.item]
                offers = self._offers(item, entry, at, locale)
                profile = (
                    self.resolve(LineRequest(offers[0].variant_id, 1, entry.id), at, locale).allergens
                    if offers
                    else AllergenProfile()
                )
                rows.append(
                    ResolvedEntry(
                        entry.id,
                        entry.number,
                        item.code,
                        loc.text(item.names, locale),
                        offers,
                        tuple(sorted(profile.contains)),
                        tuple(sorted(profile.may_contain)),
                        entry.featured,
                        item.tags,
                    )
                )
            children = self._sections(menu, entries, section.id, at, locale)
            out.append(ResolvedSection(section.id, loc.text(section.names, locale), tuple(rows), children))
        return tuple(out)

    def search(
        self, query: str, channel: str | None = None, at: datetime | None = None, locale: str = "en"
    ) -> list[Hit]:
        at = at or self._now()
        q = query.strip().lower()
        if not q:
            return []
        loc = self.defs.localizer
        menus = [
            m
            for m in self.defs.menus.values()
            if m.active and (channel is None or (channel in m.channels and menu_open(m, at)))
        ]
        menus.sort(key=lambda m: -m.priority)
        best: dict[str, Hit] = {}

        def offer(item_code: str, matched: str, score: int, entry: Entry | None = None) -> None:
            item = self.defs.items[item_code]
            if not item.active:
                return
            if entry is None:
                entry = next(
                    (e for m in menus for e in self.defs.entries_of(m.code) if e.item == item_code and e.visible), None
                )
            hit = Hit(
                item_code,
                loc.text(item.names, locale),
                matched,
                score,
                entry.id if entry else None,
                entry.number if entry else None,
            )
            if item_code not in best or best[item_code].score < score:
                best[item_code] = hit

        for menu in menus:
            for entry in self.defs.entries_of(menu.code):
                if entry.number and entry.number.lower() == q and entry.item in self.defs.items:
                    offer(entry.item, "number", 100, entry)
        for item in self.defs.items.values():
            if item.code.lower() == q:
                offer(item.code, "code", 95)
            for alias in item.aliases:
                a = alias.lower()
                if a == q:
                    offer(item.code, "alias", 90)
                elif a.startswith(q):
                    offer(item.code, "alias", 80)
                elif q in a:
                    offer(item.code, "alias", 60)
            for name in item.names.values():
                n = name.lower()
                if n == q:
                    offer(item.code, "name", 85)
                elif n.startswith(q):
                    offer(item.code, "name", 70)
                elif q in n:
                    offer(item.code, "name", 50)
        return sorted(best.values(), key=lambda h: (-h.score, h.name))

    def item_detail(
        self, item_id: str, menu_entry_id: str | None = None, at: datetime | None = None, locale: str = "en"
    ) -> ItemDetail:
        at = at or self._now()
        defs, loc = self.defs, self.defs.localizer
        item = defs.items[item_id]
        entry = defs.entry(menu_entry_id) if menu_entry_id else None
        return ItemDetail(
            item.code,
            loc.text(item.names, locale),
            item.kind,
            self._offers(item, entry, at, locale),
            self._group_details(item, "all", {}, at, locale, 0),
            defs.inherited(item, "tax_class"),
            defs.inherited(item, "station"),
        )

    def _group_details(
        self, item: Item, expose: Any, preset: Mapping[str, str], at: datetime, locale: str, depth: int
    ) -> tuple[GroupDetail, ...]:
        """A dish's groups as a screen asks them, as a slot exposes them (`expose_linked_groups`), with the
        slot's `child_defaults` as the defaults. An option linked to a dish carries that dish's groups the
        same way, one level down, so the screen can ask them once the option is chosen."""
        defs, loc = self.defs, self.defs.localizer
        attached = defs.attachments_for(item.code)
        if expose == "none":
            attached = []
        elif expose != "all":
            attached = [(g, o) for g, o in attached if g.code in set(expose)]
        groups = []
        for group, overrides in attached:
            hidden = set(overrides.get("hidden", ()))
            prices = overrides.get("prices", {})
            default = preset.get(group.code) or overrides.get("default")
            options = []
            for o in defs.options_of(group.code):
                if not o.active or o.code in hidden:
                    continue
                linked = defs.linked_item(o)
                status = self.status_of(o.id, at)
                nested: tuple[GroupDetail, ...] = ()
                price = money(prices.get(o.code, o.price))
                if o.linked_variant:
                    variant = defs.variants.get(o.linked_variant)
                    if variant is None or linked is None or not variant.active or not linked.active:
                        continue  # a dish off sale is not offered as a choice either
                    if status == "available":
                        status = self.status_of(variant.id, at)
                    # what the slot charges (`_slot`): the dish's own price, nothing, or the option's
                    if o.price_mode == "linked":
                        price = money(variant.base_price)
                    elif o.price_mode == "free":
                        price = money(ZERO)
                    if depth < MAX_DEPTH:
                        nested = self._group_details(
                            linked,
                            overrides.get("expose_linked_groups", "all"),
                            overrides.get("child_defaults") or {},
                            at,
                            locale,
                            depth + 1,
                        )
                options.append(
                    OptionDetail(
                        o.id,
                        loc.text(defs.option_names(o), locale),
                        price,
                        o.price_mode,
                        (o.code == default) if default else o.is_default,
                        o.linked_variant,
                        status,
                        defs.option_kitchen_label(o),
                        linked.code if linked is not None else None,
                        nested,
                    )
                )
            groups.append(
                GroupDetail(
                    group.code,
                    loc.text(group.names, locale),
                    overrides.get("min", group.min_select),
                    overrides.get("max", group.max_select),
                    group.free_count,
                    group.allow_quantity,
                    tuple(options),
                )
            )
        return tuple(groups)

    # --- validation of the definitions --------------------------------------------------------

    def check(self) -> list[Problem]:
        """`menu check`: every validation across the whole catalog. Codes starting with warn_ are warnings."""
        defs = self.defs
        problems: list[Problem] = []
        seen_numbers: dict[tuple[str, str], str] = {}
        for entry in defs.entries:
            if entry.number:
                key = (entry.menu, entry.number)
                if key in seen_numbers:
                    problems.append(
                        Problem(
                            "duplicate_number",
                            f"{entry.menu}: number {entry.number} used by {seen_numbers[key]} and {entry.id}",
                        )
                    )
                seen_numbers[key] = entry.id
            if entry.item not in defs.items:
                problems.append(Problem("unknown_item", f"{entry.id} points at unknown item {entry.item}"))
            if entry.section not in defs.sections:
                problems.append(Problem("unknown_section", f"{entry.id} points at unknown section {entry.section}"))
            for vid in entry.variants or ():
                if vid not in defs.variants:
                    problems.append(Problem("unknown_variant", f"{entry.id} offers unknown variant {vid}"))
        for item in defs.items.values():
            if item.active and not any(v.active for v in defs.variants_of(item.code)):
                problems.append(Problem("no_variant", f"{item.code} has no active variant"))
            if item.category not in defs.categories:
                problems.append(Problem("unknown_category", f"{item.code} is in unknown category {item.category}"))
        for group in defs.groups.values():
            if group.min_select > 0 and not any(o.active for o in defs.options_of(group.code)):
                problems.append(Problem("empty_required_group", f"{group.code} is required but has no options"))
            if group.source_category and group.source_category not in defs.categories:
                problems.append(
                    Problem(
                        "unknown_category",
                        f"{group.code} takes its options from unknown category {group.source_category}",
                    )
                )
        problems.extend(self._slot_cycles())
        for opt in defs.options.values():
            if opt.linked_variant and opt.linked_variant not in defs.variants:
                problems.append(Problem("unknown_variant", f"{opt.id} links unknown variant {opt.linked_variant}"))
            for code in opt.child_groups:
                if code not in defs.groups:
                    problems.append(Problem("unknown_group", f"{opt.id} asks unknown group {code}"))
            for effect in opt.effects:
                if effect.ingredient and effect.ingredient not in defs.ingredients:
                    problems.append(
                        Problem(
                            "unknown_ingredient",
                            f"{opt.id} {effect.op} unknown ingredient {effect.ingredient}",
                            option_id=opt.id,
                        )
                    )
        for recipe in defs.recipes:
            if not recipe.is_current:
                continue
            for comp in recipe.components:
                if comp.kind == "ingredient":
                    ing = defs.ingredients.get(comp.ref)
                    if ing is None:
                        problems.append(Problem("unknown_ingredient", f"{recipe.id}: unknown ingredient {comp.ref}"))
                        continue
                    try:
                        defs.convert(comp.qty, comp.unit, ing)
                    except UnitError as err:
                        problems.append(Problem("unit", f"{recipe.id}: {err}"))
                elif comp.ref not in defs.variants:
                    problems.append(Problem("unknown_variant", f"{recipe.id}: nested unknown variant {comp.ref}"))
        problems.extend(self._cycles())
        for item in defs.items.values():
            roles: set[str] = set()
            for variant in defs.variants_of(item.code):
                recipe, _ = defs.recipe_for_variant(variant)
                roles |= {c.role for c in (recipe.components if recipe else ()) if c.role}
                roles |= {o.role for o in variant.component_overrides}
            if not roles:
                continue
            for group, _ in defs.attachments_for(item.code):
                for opt in defs.options_of(group.code):
                    for effect in opt.effects:
                        if effect.role and effect.op in ("remove", "substitute", "scale") and effect.role not in roles:
                            problems.append(
                                Problem(
                                    "warn_missing_role",
                                    f"{item.code}: {opt.id} targets role {effect.role!r}, which its recipe lacks",
                                    option_id=opt.id,
                                )
                            )
        for ov in defs.overrides:
            if ov.level != "free":
                continue
            variants = (
                [defs.variants[ov.owner]]
                if ov.owner_kind == "variant" and ov.owner in defs.variants
                else defs.variants_of(ov.owner)
            )
            for variant in variants:
                line = self.resolve(LineRequest(variant.id))
                unreviewed = [
                    u.ingredient
                    for u in self.explode(line)
                    if defs.ingredients[u.ingredient].allergens_reviewed_at is None
                ]
                if unreviewed:
                    problems.append(
                        Problem(
                            "free_claim_unreviewed",
                            f"{variant.id}: free-from {ov.allergen} rests on unreviewed {', '.join(unreviewed)}",
                        )
                    )
        return problems

    def _slot_cycles(self) -> list[Problem]:
        """A dish that offers itself, through its groups' linked options, would never finish resolving."""
        defs = self.defs
        graph: dict[str, set[str]] = {}
        for item in defs.items.values():
            for group, overrides in defs.attachments_for(item.code):
                hidden = set(overrides.get("hidden", ()))
                for opt in defs.options_of(group.code):
                    linked = defs.linked_item(opt)
                    if linked is not None and opt.active and opt.code not in hidden:
                        graph.setdefault(item.code, set()).add(linked.code)
        problems: list[Problem] = []
        state: dict[str, int] = {}

        def visit(node: str, path: list[str]) -> None:
            if state.get(node) == 1:
                problems.append(Problem("cycle", "a dish offers itself as a choice: " + " -> ".join([*path, node])))
                return
            if state.get(node) == 2:
                return
            state[node] = 1
            for nxt in sorted(graph.get(node, ())):
                visit(nxt, [*path, node])
            state[node] = 2

        for node in sorted(graph):
            visit(node, [])
        return problems

    def _cycles(self) -> list[Problem]:
        defs = self.defs
        graph: dict[str, set[str]] = {}
        for recipe in defs.recipes:
            if not recipe.is_current:
                continue
            owner = recipe.owner if recipe.owner_kind != "item" else f"item:{recipe.owner}"
            for comp in recipe.components:
                if comp.kind == "variant":
                    variant = defs.variants.get(comp.ref)
                    target = (
                        f"item:{variant.item}"
                        if variant and defs.current_recipe("variant", variant.id) is None
                        else comp.ref
                    )
                    graph.setdefault(owner, set()).add(target)
                elif (
                    comp.kind == "ingredient"
                    and defs.ingredients.get(comp.ref, None)
                    and defs.ingredients[comp.ref].kind == "prep"
                ):
                    graph.setdefault(owner, set()).add(comp.ref)
        problems = []
        state: dict[str, int] = {}

        def visit(node: str, path: list[str]) -> None:
            if state.get(node) == 1:
                problems.append(Problem("cycle", "recipe cycle: " + " -> ".join([*path, node])))
                return
            if state.get(node) == 2:
                return
            state[node] = 1
            for nxt in graph.get(node, ()):
                visit(nxt, [*path, node])
            state[node] = 2

        for node in list(graph):
            visit(node, [])
        return problems
