"""The staff from the hub's terminal: what `hubctl staff` runs inside the API's container.

    python -m pos.identity.staffctl list
    python -m pos.identity.staffctl pin <id or name>     (the new PIN on standard input, one line)

The staff are changed in the app (Location, Staff and PINs; docs/staff.md), by a manager. This is the way
back in when no manager can sign in any more: somebody who can reach the hub's terminal, which is root on
the hub, sets a person's PIN here. It reads and writes the same list the API does
(`pos.identity.staff_list`), so the rules are the same (four digits, nobody else's), and the API finds the
change within the minute, with no restart. A PIN is read from standard input and never from the command
line, where the hub's process list would show it; nothing printed here repeats it.
"""

from __future__ import annotations

import logging
import os
import sys
from collections.abc import Sequence
from typing import TextIO

from .staff import staff_from_env
from .staff_list import Member, Refused, StaffList, default_staff_store

WHERE = {
    "app": "The staff are kept in the app: Location, Staff and PINs.",
    "hub": "The staff are the hub's own list: POS_STAFF in /opt/pos/.env. Nothing was changed in the app yet.",
    "demo": (
        "The DEMO staff sign in: the hub names nobody (no POS_STAFF), and nothing was changed in the app yet.\n"
        "Their PINs are in the guide. Give each a PIN of their own in the app: Location, Staff and PINs."
    ),
}
PIN_FROM = {
    "app": "PIN set in the app",
    "terminal": "PIN set here, in the terminal",
    "hub": "PIN from POS_STAFF",
    "demo": "demo PIN, from the guide",
}


def from_env() -> StaffList:
    """The hub's staff as the API reads them: its database and its own file."""
    own, source = staff_from_env()
    return StaffList(default_staff_store(), own=own, source=source)


def find(people: Sequence[Member], who: str) -> Member:
    """The person an id or a name means. Raises `Refused` for nobody and for a name two people have."""
    by_id = [m for m in people if m.staff_id == who]
    if by_id:
        return by_id[0]
    named = [m for m in people if m.name.casefold() == who.strip().casefold()]
    if len(named) == 1:
        return named[0]
    if named:
        ids = ", ".join(m.staff_id for m in named)
        raise Refused("unknown_staff", f"{len(named)} people are called {who}. Say which by id: {ids}.")
    raise Refused("unknown_staff", f"Nobody on the staff is called {who}. `hubctl staff` lists everybody.")


def listing(staff: StaffList, environ: dict[str, str] | os._Environ[str]) -> str:
    source = staff.source()
    lines = [WHERE[source]]
    if source == "app" and (environ.get("POS_STAFF") or "").strip():
        lines.append("POS_STAFF in /opt/pos/.env is not read any more: that line can go.")
    people = staff.members()
    wide_id = max((len(m.staff_id) for m in people), default=2)
    wide_name = max((len(m.name) for m in people), default=4)
    wide_role = max((len(m.role) for m in people), default=4)
    for m in people:
        pin = PIN_FROM.get(m.pin_from, m.pin_from)
        lines.append(f"  {m.staff_id:<{wide_id}}  {m.name:<{wide_name}}  {m.role:<{wide_role}}  {pin}")
    if not any(m.role in ("manager", "owner") for m in people):
        lines.append("Nobody here is a manager or an owner: nobody can open Location or approve a void.")
    lines.append("A new PIN for somebody: hubctl staff pin <id or name>")
    return "\n".join(lines)


def main(
    argv: Sequence[str] | None = None,
    *,
    staff: StaffList | None = None,
    stdin: TextIO | None = None,
    out: TextIO | None = None,
    environ: dict[str, str] | None = None,
) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    out = out if out is not None else sys.stdout
    command = args[0] if args else "list"
    if command not in ("list", "pin") or (command == "pin" and len(args) != 2) or (command == "list" and len(args) > 1):
        print("usage: hubctl staff | hubctl staff pin <id or name>", file=out)
        return 2
    if staff is None:
        staff = from_env()
        try:
            return main(args, staff=staff, stdin=stdin, out=out, environ=environ)
        finally:
            close = getattr(staff.store, "close", None)
            if close is not None:
                close()  # the database's connections, so the program ends at once
    if command == "list":
        print(listing(staff, os.environ if environ is None else environ), file=out)
        return 0
    pin = (stdin if stdin is not None else sys.stdin).readline().rstrip("\r\n")
    was = staff.source()
    try:
        person = find(staff.members(), args[1])
        staff.change(person.staff_id, pin=pin, by=None)
    except Refused as err:
        print(f"{err.message} Nothing was changed.", file=out)
        return 1
    print(
        f"{person.name}'s PIN is changed. It works within a minute, with no restart, and the old one does not.",
        file=out,
    )
    if was != "app":
        # the first change, wherever it is made, takes the list over from the hub's own file
        print(
            "From now on the staff are kept in the app (Location, Staff and PINs), everybody with the PIN they had."
            + (" POS_STAFF in /opt/pos/.env is not read any more: that line can go." if was == "hub" else ""),
            file=out,
        )
    return 0


if __name__ == "__main__":
    logging.disable(logging.WARNING)  # what this prints is the answer; the API's own log is the API's
    raise SystemExit(main())
