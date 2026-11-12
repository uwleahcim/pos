"""Print the demo ticket on a real printer, or write the bytes to a file.

python -m pos.printing --printer 172.19.1.50 demo        # kitchen ticket with Chinese lines
python -m pos.printing --printer 172.19.1.50 drawer      # open the cash drawer
python -m pos.printing --printer 172.19.1.14 --dialect star demo   # a Star printer in StarPRNT mode
python -m pos.printing --printer 172.19.1.14 --dialect star ascii  # same, no graphics (isolates printer hangs)
python -m pos.printing --dots 384 --out ticket.bin demo  # 58 mm paper, bytes to a file
python -m pos.printing --printer 172.19.1.50 identify    # what the printer is, and each answer it gave (prints nothing)
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from .discover import identify
from .jobs import send_raw
from .ticket import DEMO, DIALECTS, ascii_only, drawer_kick, render


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m pos.printing")
    parser.add_argument(
        "what", choices=["demo", "ascii", "drawer", "identify"], help="ascii = the demo with no graphics"
    )
    parser.add_argument("--printer", help="printer host or host:port (raw port 9100)")
    parser.add_argument("--dots", type=int, default=576, help="576 for 80 mm paper, 384 for 58 mm")
    parser.add_argument("--font", help="path to a font that covers Chinese (default: first known system font)")
    parser.add_argument("--out", help="write the bytes here instead of printing")
    parser.add_argument("--dialect", choices=sorted(DIALECTS), default="escpos", help="printer language")
    args = parser.parse_args(argv)
    if args.what == "identify":
        if not args.printer:
            parser.error("--printer is required")
        return said(args.printer)
    if args.what == "drawer":
        data = drawer_kick(dialect=args.dialect)
    else:
        ticket = DEMO if args.what == "demo" else ascii_only(DEMO)
        data = render(ticket, dots=args.dots, font=args.font, dialect=args.dialect)
    if args.out:
        with open(args.out, "wb") as fh:
            fh.write(data)
        print(f"{len(data)} bytes written to {args.out}")
        return 0
    if not args.printer:
        parser.error("--printer or --out is required")
    send_raw(args.printer, data)
    print(f"{len(data)} bytes sent to {args.printer}")
    return 0


def said(printer: str) -> int:
    """Prints what `discover.identify` makes of the printer and each answer behind it; 1 when nothing answers."""
    found = asyncio.run(identify(printer))
    if not found.reachable:
        print(f"{printer}: nothing answers on the printer port")
        return 1
    name = " ".join(part for part in (found.maker, found.model) if part) or "no name given"
    language = {"escpos": "ESC/POS", "star": "Star (StarPRNT)", None: "language not told"}[found.dialect]
    if found.guessed:
        language += ", going by its name"
    if found.kind == "other":
        language = "not a receipt printer"
    print(f"{printer}: {name}: {language}")
    for line in found.heard:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
