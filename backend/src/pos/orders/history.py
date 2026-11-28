"""A check's history: every step the log keeps of one order, oldest first, in a shape a screen can say.

The log already holds it all (`pos.sync.oplog`): each operation with its time, the screen it came from and,
for most, who did it. This walks the operations of one order in the order the replay takes them and says
what each one did to the check as it stood then: a dish rung in, sent, voided with its reason and the
manager who approved, a table moved, a payment taken, the check closed. Nothing is stored and nothing is
left out: an operation that changed nothing (the same dish sent twice by a retry, a field set to what it
already was) has no step, and a dish moved up or down the check is nobody's business.

Each step is a dict:

- `op_id`, `at_ms` (the stamp of the screen that did it), `device`, `what` (below);
- `by`, `by_id`: who, as the operation says, else whoever the audit photo of that operation shows, else
  empty (a build before 2026-11-16 named nobody on a send, a close or a move of the table);
- `approved_by`: the manager behind a void, a comp or a charge taken off, where one was asked;
- `offline`: the screen stamped it while no hub answered;
- `photo`: the id of the audit photo taken with it, while the hub still has the picture.

`what` and what comes with it:

- `opened`: `fields`, the order's fields as it was opened (table, guests, order_type, customer_name, ...;
  `tab` true for a bar tab);
- `table`, `server`, `guests`, `stage`, `promised` (ms), `quoted` (minutes), `split`: `was`, `now`; a
  `stage` of an order that is brought to the customer says `delivery` true (it was delivered, not picked
  up), and one that says it left (`now` is `out`) names the `driver` it left with;
- `driver`: `was`, `now`: a delivery on its way was handed from one driver to another;
- `merged`: `other` (the check this one's dishes went to) and `other_table`;
- `field`: `field` (customer_name, phone, note, order_type, channel, event_guests, handover, address,
  event_note), `was`, `now`; `event_note` says `catering` too: false when the note is for the driver;
- `added`: `dish`, `options`, `qty`, `seat`, `course` (by its name), `note`, `unit_price`, and `changed`
  when it took the place of a dish that was edited; `moved_in` the same with `other`, `other_table` (or
  `other_tab`, the name on the bar tab it came from), `sent` when the kitchen already had it, and
  `rung_by`, who rang it in on the check it came from (the step's own `by` is who brought it over);
- `moved_out`: `dish`, `qty`, `other`, `other_table`;
- `changed`: `dish` and `changes`, each `{field: qty | seat | course | note | checks, was, now}`;
- `taken_off` (before the kitchen saw it) and `voided` (after): `dish`, `qty`, and for a void `reason`;
- `sent`: `course` (by its name; None for the whole check) and `dishes`, each `{dish, qty}`;
- `closed`, `reopened`, `voided_check` (`reason`);
- `discount`: `name`, `kind`, `value`, `dish` (None for the whole check), `note`, and `carried` when it
  came over with its dish from another check; `discount_removed`: `name`, `dish`;
- `charge`: `name`, `kind`, `value`; `charge_removed`: `name`;
- `paid`: `method`, `amount`, `tendered`, `check`, `note`;
- `allergy`: `seat`, `allergens` (by name), `note`; `allergy_cleared`: `seat`;
- `tax_exempt` (a manager marked the check exempt from sales tax): `organisation`, `certificate`;
  `tax_exempt_removed`: `organisation`;
- `bag` (what goes in the bag with a to-go order was answered): `items`, each `{name, qty}` (none: nothing
  was wanted), and `changed` when an earlier answer stood;
- `delivery_fee` (what a delivery costs the customer was picked, changed or taken back): `now` and `was`,
  each `{by, up_to, amount, taxed}` as the order carried it (pos.orders.delivery_fee; an `amount` of "0.00"
  with no band is no fee on purpose, and `by` is `custom` for an amount that was typed for a delivery further
  than the bands reach) or None while nobody had said;
- `shipday` (what Shipday said of the delivery, written on the check by the hub where the check did not
  move with it, pos.shipday.follow: delivered while money is still due, failed, incomplete, or picked up
  while the kitchen never had it): `state` (Shipday's own word) and `said_ms` (the moment the check keeps
  for it). Where Shipday moved the check, the `stage` and `closed` steps say so, by "Shipday";
- `shipday_ready` (Shipday was told the delivery is ready for pickup, pos.shipday.ready): `auto` (the hub
  told it by itself because the check was marked Ready; a person tapped it on the Shipday screen otherwise,
  and is the step's `by`) and `told_ms` (when Shipday answered that it is).
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from typing import Any

from ..shipday.follow import FIELD as SHIPDAY
from ..shipday.follow import READY_FIELD as SHIPDAY_READY
from ..sync.oplog import LINE_FIELDS, Line, Op, OrderState, apply, is_delivery
from .adjustments import PricingRules
from .bag import FIELD as BAG
from .bag import bag_of
from .check import shown_modifiers
from .delivery_fee import FIELD as FEE
from .delivery_fee import fee_of
from .exempt import FIELD as EXEMPT
from .exempt import exemption_of

OPENED_WITH = (
    "table",
    "guests",
    "order_type",
    "tab",
    "customer_name",
    "phone",
    "channel",
    "order_no",
    "promised_at",
    "quoted_minutes",
    "server",
    "note",
    "event_guests",
    "handover",
    "address",
    "event_note",
)
"""What a check says of itself when it is opened, in the order a screen lists it."""
OWN_STEP = {
    "table": "table",
    "server": "server",
    "guests": "guests",
    "stage": "stage",
    "promised_at": "promised",
    "quoted_minutes": "quoted",
    "split": "split",
}
"""The fields whose change is a step with a name of its own."""
PLAIN = (
    "customer_name",
    "phone",
    "note",
    "order_type",
    "channel",
    "event_guests",
    "handover",
    "address",
    "event_note",
)
"""The fields whose change reads as "the name was A, now B". The rest (the server's id, the customer's
language, a ticket number) change with something a step already says, or are the hub's own bookkeeping."""
LINE_SAID = tuple(sorted(LINE_FIELDS - {"rank"}))
"""What a change to a dish can be about. Its place on the check is not in the history."""


def dish_name(line: Line) -> str:
    return str((line.priced or {}).get("name") or line.item or "")


def _options(line: Line) -> list[str]:
    """The choices a check lists under the dish: those that are not its defaults."""
    rows = (line.priced or {}).get("modifiers") or ()
    return [str(m.get("label") or "") for m in shown_modifiers(rows) if m.get("label")]


def _line_said(line: Line) -> dict[str, Any]:
    return {name: getattr(line, name) for name in LINE_SAID}


def history(
    ops: Iterable[Op],
    order_id: str,
    *,
    rules: PricingRules | None = None,
    allergens: Mapping[str, str] | None = None,
    courses: Mapping[str, str] | None = None,
    photo_of: Callable[[str], tuple[str, str | None] | None] | None = None,
    name_of: Callable[[str], str | None] | None = None,
    table_of: Callable[[str], Any] | None = None,
) -> list[dict[str, Any]]:
    """The steps of one order, oldest first (see the module's text for their shape). `ops` are the order's
    operations in any order, duplicates and all; `rules` names discounts and charges, `allergens` names
    allergens and `courses` names courses (their codes and ids otherwise); `photo_of` gives the audit photo
    of an operation (its id and whose it is), `name_of` a person's name from their id, `table_of` the table
    another check stands at."""
    unique: dict[str, Op] = {}
    for op in ops:
        if op.order_id == order_id:
            unique.setdefault(op.op_id, op)
    state = OrderState(order_id=order_id)
    steps: list[dict[str, Any]] = []

    def other_table(other: str | None) -> Any:
        return table_of(other) if table_of is not None and other else None

    def course_name(course: Any) -> Any:
        return (courses or {}).get(course, course) if isinstance(course, str) else course

    for op in sorted(unique.values(), key=lambda o: o.sort_key):
        data = op.data
        photo = photo_of(op.op_id) if photo_of is not None else None
        by, by_id = str(data.get("by") or data.get("applied_by") or ""), data.get("by_id")
        if op.kind == "add_line" and isinstance(data.get("from"), dict):
            # a dish from another check keeps who rang it in there as its `by`: who brought it over is said
            # beside that, by a build that says it (2026-11-16 on), and is nobody named before
            by, by_id = str(data.get("moved_by") or ""), data.get("moved_by_id")
        by_id = by_id if isinstance(by_id, str) and by_id else None
        if not by and by_id is None and photo is not None and photo[1]:
            by_id = photo[1]  # nobody named: whoever stood at the screen when its photo was taken
        if not by and by_id is not None and name_of is not None:
            by = name_of(by_id) or ""
        approved = data.get("approved_by")
        common = {
            "op_id": op.op_id,
            "at_ms": op.hlc.wall_ms,
            "device": op.device,
            "by": by,
            "by_id": by_id,
            "approved_by": str(approved.get("name") or "") if isinstance(approved, dict) else "",
            "offline": bool(data.get("offline")),
            "photo": photo[0] if photo is not None else None,
        }

        def step(what: str, _common: dict[str, Any] = common, **said: Any) -> None:
            steps.append({**_common, "what": what, **said})

        kind = op.kind
        # What the operation is about, as the check stood before it.
        line = state.lines.get(data["line_id"]) if isinstance(data.get("line_id"), str) else None
        before_fields = dict(state.fields)
        before_status = state.status
        first = state.first is None
        was_line = _line_said(line) if line is not None else None
        was_active = line is not None and line.active
        was_sent = line is not None and line.fired_at is not None
        unsent = {each.line_id for each in state.lines.values() if each.active and each.fired_at is None}
        discount = state.discounts.get(str(data.get("discount_id"))) if kind == "remove_discount" else None
        discount_stood = discount is not None and discount.active
        charge = state.charges.get(str(data.get("charge_id"))) if kind == "remove_charge" else None
        charge_stood = charge is not None and charge.active
        new_discount = kind == "discount" and data.get("discount_id") not in state.discounts
        new_charge = kind == "charge" and data.get("charge_id") not in state.charges
        new_payment = kind == "pay" and data.get("payment_id") not in state.payments
        seat = data.get("seat")
        seat_key = seat if isinstance(seat, int) and not isinstance(seat, bool) and seat > 0 else 0
        had_allergy = state.allergies.get(seat_key)

        try:
            apply(state, op)
        except (KeyError, TypeError, ValueError):
            continue  # an operation the replay cannot read is no step; the hub refuses them at the door

        if kind in ("create", "set_field"):
            if first and kind == "create":
                step("opened", fields={k: state.fields[k] for k in OPENED_WITH if state.fields.get(k) is not None})
                if fee_of(state.fields) is not None:  # taken with its delivery fee already picked
                    step("delivery_fee", now=fee_of(state.fields), was=None)
                continue
            for name in state.fields:
                was, now = before_fields.get(name), state.fields.get(name)
                if was == now:
                    continue
                if name == "stage" and is_delivery(state.fields):
                    # it was brought, not picked up; `out` says who it left with
                    left = {"driver": state.fields.get("driver")} if now == "out" else {}
                    step("stage", was=was, now=now, delivery=True, **left)
                elif name == "driver":
                    # handed from one driver to another on the way; leaving and coming back are `stage` steps
                    if now and before_fields.get("stage") == "out" and state.fields.get("stage") == "out":
                        step("driver", was=was, now=now)
                elif name in OWN_STEP:
                    step(OWN_STEP[name], was=was, now=now)
                elif name == "merged_into" and isinstance(now, str):
                    step("merged", other=now, other_table=other_table(now))
                elif name == "event_note":
                    # a catering order's note is about its event; any other order's is for the driver
                    step("field", field=name, was=was, now=now, catering=state.fields.get("channel") == "catering")
                elif name in PLAIN:
                    step("field", field=name, was=was, now=now)
                elif name == EXEMPT:
                    marked, stood = exemption_of({EXEMPT: now}), exemption_of({EXEMPT: was})
                    if marked is not None:
                        step("tax_exempt", organisation=marked["organisation"], certificate=marked["certificate"])
                    elif stood is not None:
                        step("tax_exempt_removed", organisation=stood["organisation"])
                elif name == BAG:
                    answer, stood = bag_of({BAG: now}), bag_of({BAG: was})
                    if answer is not None and answer != stood:
                        items = [{"name": item["name"], "qty": item["qty"]} for item in answer["items"]]
                        step("bag", items=items, changed=stood is not None)
                elif name == FEE:
                    picked, stood = fee_of({FEE: now}), fee_of({FEE: was})
                    if picked != stood:
                        step("delivery_fee", now=picked, was=stood)
                elif name == SHIPDAY:
                    # what Shipday said, where the check stayed as it was: one it moved says so in its stage
                    moved = before_fields.get("stage") != state.fields.get("stage")
                    word = now.get("state") if isinstance(now, Mapping) else None
                    if word and not moved and (not isinstance(was, Mapping) or was.get("state") != word):
                        step("shipday", state=str(word), said_ms=now.get("at_ms"))
                elif name == SHIPDAY_READY:
                    if isinstance(now, Mapping):
                        step("shipday_ready", auto=now.get("auto") is True, told_ms=now.get("at_ms"))

        elif kind == "add_line":
            added = state.lines.get(data.get("line_id"))
            if line is not None or added is None:
                continue  # already on the check: the same dish sent twice is one dish
            said = {
                "line_id": added.line_id,
                "dish": dish_name(added),
                "options": _options(added),
                "qty": added.qty,
                "seat": added.seat,
                "course": course_name(added.course),
                "note": added.note,
                "unit_price": str((added.priced or {}).get("unit_price") or ""),
            }
            if added.moved_from is not None:
                other = added.moved_from.get("order_id")
                table = added.moved_from.get("table") or other_table(other)
                step(
                    "moved_in",
                    **said,
                    other=other,
                    other_table=table,
                    **({"other_tab": added.moved_from["tab"]} if "tab" in added.moved_from else {}),
                    sent=added.arrived_sent,
                    rung_by=added.by,
                )
            else:
                step("added", **said, changed=added.replaces is not None)

        elif kind == "set_line":
            if line is None or was_line is None or not was_active:
                continue
            now_line = _line_said(line)
            changes = [
                {"field": name, "was": was_line[name], "now": now_line[name]}
                for name in LINE_SAID
                if was_line[name] != now_line[name]
            ]
            for change in changes:
                if change["field"] == "course":
                    change["was"], change["now"] = course_name(change["was"]), course_name(change["now"])
            if changes:
                step("changed", line_id=line.line_id, dish=dish_name(line), changes=changes)

        elif kind == "void_line":
            if line is None or not was_active:
                continue  # never on the check, or already off it
            if was_sent:
                voided = line.voided or {}
                reason = str(voided.get("reason_name") or voided.get("reason") or "")
                step("voided", line_id=line.line_id, dish=dish_name(line), qty=line.qty, reason=reason)
            else:
                step("taken_off", line_id=line.line_id, dish=dish_name(line), qty=line.qty)

        elif kind == "move_line":
            if line is None or not was_active or line.moved_to is None:
                continue
            other = line.moved_to.get("order_id")
            step(
                "moved_out",
                line_id=line.line_id,
                dish=dish_name(line),
                qty=line.qty,
                other=other,
                other_table=other_table(other),
            )

        elif kind == "fire":
            went = [each for each in state.ordered_lines() if each.line_id in unsent and each.fired_at is not None]
            if went:
                course = data.get("course", "*")
                step(
                    "sent",
                    course=None if course == "*" else course_name(course),
                    dishes=[{"dish": dish_name(each), "qty": each.qty} for each in went],
                )

        elif kind == "close":
            if before_status == "open" and state.status == "closed":
                step("closed")

        elif kind == "reopen":
            if before_status == "closed" and state.status == "open":
                step("reopened")

        elif kind == "void_order":
            if before_status != "void":
                step("voided_check", reason=str(data.get("reason") or ""))

        elif kind == "discount":
            if new_discount:
                made = state.discounts[data["discount_id"]]
                on = state.lines.get(made.line_id) if made.line_id else None
                step(
                    "discount",
                    name=_discount_name(rules, made.reason),
                    kind=made.kind,
                    value=made.value,
                    dish=dish_name(on) if on is not None else None,
                    note=made.note,
                    carried=made.carried_from is not None,
                )

        elif kind == "remove_discount":
            if discount is not None and discount_stood:
                on = state.lines.get(discount.line_id) if discount.line_id else None
                step(
                    "discount_removed",
                    name=_discount_name(rules, discount.reason),
                    dish=dish_name(on) if on is not None else None,
                )

        elif kind == "charge":
            if new_charge:
                made_charge = state.charges[data["charge_id"]]
                step(
                    "charge",
                    name=_charge_name(rules, made_charge.code, made_charge.name),
                    kind=made_charge.kind,
                    value=made_charge.value,
                )

        elif kind == "remove_charge":
            if charge is None or charge_stood:
                # one staff put on, or (never on the check as an operation) one the rules apply by themselves
                code = charge.code if charge is not None else str(data.get("code") or data.get("charge_id") or "")
                step("charge_removed", name=_charge_name(rules, code, charge.name if charge is not None else ""))

        elif kind == "pay":
            if new_payment:
                paid = state.payments[data["payment_id"]]
                step(
                    "paid",
                    method=paid.method,
                    amount=paid.amount,
                    tendered=paid.tendered,
                    check=paid.check,
                    note=paid.note,
                )

        elif kind == "allergy":
            now_allergy = state.allergies.get(seat_key)
            if now_allergy == had_allergy:
                continue
            if now_allergy is None:
                step("allergy_cleared", seat=seat_key or None)
            else:
                names = [(allergens or {}).get(code, code) for code in now_allergy["allergens"]]
                step("allergy", seat=seat_key or None, allergens=names, note=now_allergy["note"])

    return steps


def _discount_name(rules: PricingRules | None, reason: str) -> str:
    if rules is not None and reason in rules.discounts:
        return rules.discounts[reason].name
    return reason


def _charge_name(rules: PricingRules | None, code: str, name: str) -> str:
    if name:
        return name
    if rules is not None and code in rules.charges:
        return rules.charges[code].name
    return code
