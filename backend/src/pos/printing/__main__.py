"""Print the demo ticket on a real printer, or write the bytes to a file.

python -m pos.printing --printer 172.19.1.50 demo        # kitchen ticket with Chinese lines
python -m pos.printing --printer 172.19.1.50 drawer      # open the cash drawer
python -m pos.printing --printer 172.19.1.14 --dialect star demo   # a Star printer in StarPRNT mode
python -m pos.printing --dots 384 --out ticket.bin demo  # 58 mm paper, bytes to a file
"""

from __future__ import annotations

import argparse
import sys

from .jobs import send_raw
from .ticket import DEMO, drawer_kick, render


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m pos.printing")
    parser.add_argument("what", choices=["demo", "drawer"])
    parser.add_argument("--printer", help="printer host or host:port (raw port 9100)")
    parser.add_argument("--dots", type=int, default=576, help="576 for 80 mm paper, 384 for 58 mm")
    parser.add_argument("--font", help="path to a font that covers Chinese (default: first known system font)")
    parser.add_argument("--out", help="write the bytes here instead of printing")
    parser.add_argument("--dialect", choices=["escpos", "star"], default="escpos", help="printer language")
    args = parser.parse_args(argv)
    if args.what == "demo":
        data = render(DEMO, dots=args.dots, font=args.font, dialect=args.dialect)
    else:
        data = drawer_kick(dialect=args.dialect)
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


if __name__ == "__main__":
    sys.exit(main())
