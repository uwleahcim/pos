"""Editing the menu: the whole catalog as JSON, and a list of changes checked before anything is saved.

The menu editor reads `catalog()`, sends back changes such as `{"kind": "variant", "op": "put", "data": {...}}`
or `{"kind": "entry", "op": "delete", "key": "dinner:2"}`, and `apply()` makes a new `Definitions` from them.
`problems()` then runs the engine's own `menu check` plus the reference checks the database would make, so
a change that would break the menu is refused with its reasons before it reaches the store.
"""

from __future__ import annotations

import types
import typing
from collections.abc import Callable, Mapping
from dataclasses import dataclass, fields, is_dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from . import defs as d
from . import linked
from .defs import Definitions
from .engine import MenuEngine
from .resolved import Problem


@dataclass(frozen=True)
class Kind:
    """One kind of definition: its class, where `Definitions` keeps it, and the key a change names it by."""

    name: str
    cls: type
    attr: str
    key: Callable[[Any], str]


def _code(obj: Any) -> str:
    return obj.code


def _id(obj: Any) -> str:
    return obj.id


KINDS: dict[str, Kind] = {
    k.name: k
    for k in (
        Kind("unit", d.Unit, "units", _code),
        Kind("allergen", d.Allergen, "allergens", _code),
        Kind("station", d.Station, "stations", _code),
        Kind("category", d.Category, "categories", _code),
        Kind("item", d.Item, "items", _code),
        Kind("variant", d.Variant, "variants", _id),
        Kind("group", d.Group, "groups", _code),
        Kind("word", d.Word, "words", _code),
        Kind("option", d.Option, "options", _id),
        Kind("attachment", d.Attachment, "attachments", lambda a: f"{a.owner_kind}:{a.owner}/{a.group}"),
        Kind("menu", d.Menu, "menus", _code),
        Kind("section", d.Section, "sections", _id),
        Kind("entry", d.Entry, "entries", _id),
        Kind("ingredient", d.Ingredient, "ingredients", _code),
        Kind("override", d.AllergenOverride, "overrides", lambda o: f"{o.owner_kind}:{o.owner}/{o.allergen}"),
        Kind("recipe", d.Recipe, "recipes", _id),
    )
}


class ChangeError(ValueError):
    """A change that cannot even be applied: an unknown kind, a missing field, a value of the wrong type."""


# --- JSON <-> definitions --------------------------------------------------------------------------------


def encode(value: Any) -> Any:
    """A definition as plain JSON: decimals as strings, so a price never passes through a float."""
    if is_dataclass(value) and not isinstance(value, type):
        return {f.name: encode(getattr(value, f.name)) for f in fields(value)}
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Mapping):
        return {k: encode(v) for k, v in value.items()}
    if isinstance(value, frozenset | set):
        return sorted(encode(v) for v in value)
    if isinstance(value, list | tuple):
        return [encode(v) for v in value]
    return value


def decode(cls: type, data: Mapping[str, Any]) -> Any:
    """A definition from JSON. Fields left out take their defaults; unknown fields are refused."""
    if not isinstance(data, Mapping):
        raise ChangeError(f"{cls.__name__}: expected an object")
    hints = typing.get_type_hints(cls)
    known = {f.name for f in fields(cls)}
    extra = set(data) - known
    if extra:
        raise ChangeError(f"{cls.__name__}: unknown fields {', '.join(sorted(extra))}")
    values = {name: _value(hints[name], value, f"{cls.__name__}.{name}") for name, value in data.items()}
    if cls is d.Attachment and "prices" in values.get("overrides", {}):
        # the one free-form field holding money: option prices on this attachment
        prices = values["overrides"]["prices"]
        if not isinstance(prices, Mapping):
            raise ChangeError("Attachment.overrides.prices: expected an object")
        hint = Mapping[str, Decimal]
        values["overrides"] = {**values["overrides"], "prices": _value(hint, prices, "Attachment.overrides.prices")}
    try:
        return cls(**values)
    except TypeError as err:  # a required field missing
        raise ChangeError(f"{cls.__name__}: {err}") from None


def _value(tp: Any, value: Any, where: str) -> Any:
    origin, args = typing.get_origin(tp), typing.get_args(tp)
    if origin in (types.UnionType, typing.Union):
        if value is None and type(None) in args:
            return None
        (inner,) = [a for a in args if a is not type(None)]
        return _value(inner, value, where)
    if tp is Any:
        return value
    if tp is Decimal:
        try:
            return Decimal(str(value))
        except InvalidOperation:
            raise ChangeError(f"{where}: {value!r} is not a number") from None
    if tp is datetime:
        try:
            return datetime.fromisoformat(str(value))
        except ValueError:
            raise ChangeError(f"{where}: {value!r} is not a time") from None
    if tp is bool:
        if not isinstance(value, bool):
            raise ChangeError(f"{where}: expected true or false")
        return value
    if tp is int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ChangeError(f"{where}: expected a whole number")
        return value
    if tp is str:
        if not isinstance(value, str):
            raise ChangeError(f"{where}: expected text")
        return value
    if origin in (tuple, frozenset):
        if not isinstance(value, list | tuple):
            raise ChangeError(f"{where}: expected a list")
        return origin(_value(args[0], v, where) for v in value)
    if origin is Mapping:
        if not isinstance(value, Mapping):
            raise ChangeError(f"{where}: expected an object")
        return {str(k): _value(args[1], v, where) for k, v in value.items()}
    if is_dataclass(tp):
        return decode(tp, value)
    raise ChangeError(f"{where}: cannot read {tp}")  # pragma: no cover - a new field type in defs.py


def catalog(defs: Definitions) -> dict[str, list[dict[str, Any]]]:
    """Every definition, by kind, in the order the editor shows them."""
    out: dict[str, list[dict[str, Any]]] = {}
    for kind in KINDS.values():
        held = getattr(defs, kind.attr)
        values = held.values() if isinstance(held, dict) else held
        out[kind.name] = [{"key": kind.key(v), **encode(v)} for v in values]
    return out


# --- changes ---------------------------------------------------------------------------------------------


def copy_of(defs: Definitions) -> Definitions:
    """A copy whose collections can change without touching the menu being sold from."""
    new = Definitions(defs.localizer)
    for kind in KINDS.values():
        held = getattr(defs, kind.attr)
        setattr(new, kind.attr, dict(held) if isinstance(held, dict) else list(held))
    return new


def _with_ids(kind: str, data: Mapping[str, Any]) -> dict[str, Any]:
    """Fill the ids that follow from codes, so the editor can send a new size as {item, code, ...}."""
    data = dict(data)
    if kind == "variant" and "id" not in data and {"item", "code"} <= data.keys():
        data["id"] = f"{data['item']}:{data['code']}"
    if kind == "option" and "id" not in data and {"group", "code"} <= data.keys():
        data["id"] = f"{data['group']}:{data['code']}"
    if kind == "recipe" and "id" not in data and {"owner", "version"} <= data.keys():
        data["id"] = f"{data['owner']}@{data['version']}"
    return data


def apply(defs: Definitions, changes: list[Mapping[str, Any]]) -> Definitions:
    """A new `Definitions` with the changes made in order. `put` adds or replaces a definition by its key;
    `delete` removes one, and with `"cascade": true` an item takes its sizes, menu entries, modifier
    attachments, allergen overrides and recipes with it, and a modifier group its options and attachments.
    A group whose options come from a category then gets the options the category's dishes call for
    (`linked.sync`), so a dish added to the category is offered where the category is."""
    new = copy_of(defs)
    for n, change in enumerate(changes, 1):
        if not isinstance(change, Mapping):
            raise ChangeError(f"change {n}: expected an object")
        kind = KINDS.get(str(change.get("kind")))
        if kind is None:
            raise ChangeError(f"change {n}: unknown kind {change.get('kind')!r}; one of {', '.join(KINDS)}")
        held = getattr(new, kind.attr)
        op = change.get("op")
        if op == "put":
            try:
                obj = decode(kind.cls, _with_ids(kind.name, change.get("data") or {}))
            except ChangeError as err:
                raise ChangeError(f"change {n}: {err}") from None
            key = kind.key(obj)
            if isinstance(held, dict):
                held[key] = obj
            else:
                held[:] = [v for v in held if kind.key(v) != key]
                held.append(obj)
        elif op == "delete":
            key = str(change.get("key", ""))
            if isinstance(held, dict):
                found = held.pop(key, None) is not None
            else:
                kept = [v for v in held if kind.key(v) != key]
                found, held[:] = len(kept) != len(held), kept
            if not found:
                raise ChangeError(f"change {n}: no {kind.name} {key!r}")
            if change.get("cascade"):
                _cascade(new, kind.name, key)
        else:
            raise ChangeError(f"change {n}: op must be put or delete")
    linked.sync(new)
    return new


def _cascade(defs: Definitions, kind: str, key: str) -> None:
    if kind == "item":
        gone = {vid for vid, v in defs.variants.items() if v.item == key}
        for vid in gone:
            del defs.variants[vid]
        defs.entries = [e for e in defs.entries if e.item != key]
        defs.attachments = [a for a in defs.attachments if not (a.owner_kind == "item" and a.owner == key)]
        owners = {key} | gone
        defs.overrides = [o for o in defs.overrides if o.owner not in owners]
        defs.recipes = [r for r in defs.recipes if not (r.owner_kind in ("item", "variant") and r.owner in owners)]
    elif kind == "group":
        for oid in [oid for oid, o in defs.options.items() if o.group == key]:
            del defs.options[oid]
        defs.attachments = [a for a in defs.attachments if a.group != key]


# --- checks ----------------------------------------------------------------------------------------------


def problems(defs: Definitions) -> tuple[list[Problem], list[Problem]]:
    """(errors, warnings) for a whole menu: the engine's `menu check` plus every reference between
    definitions. Errors stop a save; warnings (codes starting with warn_) are shown and allowed."""
    found = _references(defs)
    if not found:  # the engine resolves dishes while checking, which needs the references whole
        found = MenuEngine(defs).check()
    errors = [p for p in found if not p.code.startswith("warn_")]
    warnings = [p for p in found if p.code.startswith("warn_")]
    return errors, warnings


def _references(defs: Definitions) -> list[Problem]:
    out: list[Problem] = []

    def need(where: str, what: str, ref: str | None, held: Mapping[str, Any]) -> None:
        if ref is not None and ref not in held:
            out.append(Problem("unknown_reference", f"{where}: {what} {ref!r} does not exist"))

    for c in defs.categories.values():
        need(f"category {c.code}", "parent category", c.parent, defs.categories)
        need(f"category {c.code}", "station", c.station, defs.stations)
    for i in defs.items.values():
        need(f"item {i.code}", "category", i.category, defs.categories)
        need(f"item {i.code}", "station", i.station, defs.stations)
    for v in defs.variants.values():
        need(f"size {v.id}", "item", v.item, defs.items)
        if v.id != f"{v.item}:{v.code}":
            out.append(Problem("bad_id", f"size {v.id}: the id must be {v.item}:{v.code}"))
    for g in defs.groups.values():
        need(f"group {g.code}", "category", g.source_category, defs.categories)
        for station in g.hidden_at or ():
            need(f"group {g.code}", "station", station, defs.stations)
    for o in defs.options.values():
        need(f"option {o.id}", "group", o.group, defs.groups)
        need(f"option {o.id}", "station", o.station, defs.stations)
        need(f"option {o.id}", "station", o.routes_to, defs.stations)
        if o.id != f"{o.group}:{o.code}":
            out.append(Problem("bad_id", f"option {o.id}: the id must be {o.group}:{o.code}"))
    for a in defs.attachments:
        need(f"attachment on {a.owner}", "group", a.group, defs.groups)
        need(
            f"attachment of {a.group}", a.owner_kind, a.owner, defs.items if a.owner_kind == "item" else defs.categories
        )
    for s in defs.sections.values():
        need(f"section {s.id}", "menu", s.menu, defs.menus)
        need(f"section {s.id}", "parent section", s.parent, defs.sections)
    for e in defs.entries:
        need(f"entry {e.id}", "menu", e.menu, defs.menus)
        need(f"entry {e.id}", "section", e.section, defs.sections)
        need(f"entry {e.id}", "item", e.item, defs.items)
        for vid in (e.variants or ()) + tuple(e.price_overrides):
            need(f"entry {e.id}", "size", vid, defs.variants)
    for ov in defs.overrides:
        need(f"allergen override on {ov.owner}", "allergen", ov.allergen, defs.allergens)
        need("allergen override", ov.owner_kind, ov.owner, defs.items if ov.owner_kind == "item" else defs.variants)
    for r in defs.recipes:
        if r.id != f"{r.owner}@{r.version}":
            out.append(Problem("bad_id", f"recipe {r.id}: the id must be {r.owner}@{r.version}"))
    seen: set[str] = set()
    for kind in ("attachment", "entry", "override", "recipe"):
        k = KINDS[kind]
        for v in getattr(defs, k.attr):
            key = f"{kind}:{k.key(v)}"
            if key in seen:
                out.append(Problem("duplicate", f"{kind} {k.key(v)} appears twice"))
            seen.add(key)
    return out


def problem_out(p: Problem) -> dict[str, Any]:
    return {"code": p.code, "message": p.message}
