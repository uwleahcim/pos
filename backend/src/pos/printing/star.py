"""StarPRNT (Star Line Mode) bytes for Star printers such as the mC-Print3 and TSP series.

Same ticket logic as ESC/POS (`Builder`), different bytes: Star alignment and size commands, raster
graphics sent row by row inside raster mode, `ESC d` cuts and `BEL` for the drawer. A Star printer in
its default mode takes this; in ESC/POS emulation it takes the Epson bytes instead.
"""

from __future__ import annotations

from .escpos import ESC, Builder

RASTER_IN = ESC + b"*rA" + ESC + b"*rP0\x00"  # enter raster mode, continuous page
RASTER_OUT = ESC + b"*rB"  # back to line mode


class StarBuilder(Builder):
    """`graphics`: "raster" (raster mode, `b` rows) or "column" (line mode `ESC k` 24-dot bands)."""

    def __init__(self, *, graphics: str = "raster", **kwargs) -> None:
        super().__init__(**kwargs)
        if graphics not in ("raster", "column"):
            raise ValueError(graphics)
        self.graphics = graphics

    def _cmd_init(self) -> bytes:
        return ESC + b"@"

    def _cmd_text(self, text: str, *, bold: bool, big: bool, center: bool) -> bytes:
        return (
            ESC
            + b"\x1da"
            + (b"\x01" if center else b"\x00")  # ESC GS a: 0 left, 1 centre
            + (ESC + b"E" if bold else ESC + b"F")
            + ESC
            + b"i"
            + (b"\x01\x01" if big else b"\x00\x00")  # ESC i: height, width magnification
            + text.encode("ascii")
            + b"\n"
            + ESC
            + b"i\x00\x00"
            + ESC
            + b"F"
            + ESC
            + b"\x1da\x00"
        )

    def _cmd_feed(self, lines: int) -> bytes:
        return ESC + b"a" + bytes([lines])

    def _cmd_raster(self, row_bytes: int, height: int, data: bytes) -> bytes:
        if self.graphics == "column":
            return self._column_bands(row_bytes, height, data)
        # Raster mode: `b n1 n2 <row>` per row, then leave raster mode so text can follow.
        rows = (data[i * row_bytes : (i + 1) * row_bytes] for i in range(height))
        body = b"".join(b"b" + bytes([row_bytes & 0xFF, row_bytes >> 8]) + row for row in rows)
        return RASTER_IN + body + RASTER_OUT

    @staticmethod
    def _column_bands(row_bytes: int, height: int, data: bytes) -> bytes:
        """Line mode `ESC k n1 n2 <3 bytes per column>`: 24-dot tall bands at 3 mm line spacing."""
        width = row_bytes * 8
        bands = []
        for top in range(0, height, 24):
            cols = bytearray(width * 3)
            for y in range(top, min(top + 24, height)):
                row = data[y * row_bytes : (y + 1) * row_bytes]
                bit = 0x80 >> ((y - top) % 8)
                byte = (y - top) // 8
                for x in range(width):
                    if row[x >> 3] & (0x80 >> (x & 7)):
                        cols[x * 3 + byte] |= bit
            bands.append(ESC + b"k" + bytes([width & 0xFF, width >> 8]) + bytes(cols) + b"\n")
        return ESC + b"0" + b"".join(bands) + ESC + b"z\x01"  # 3 mm spacing for the bands, 4 mm after

    def _cmd_cut(self, feed: int) -> bytes:
        return ESC + b"a" + bytes([feed]) + ESC + b"d\x03"  # feed, then partial cut at the cut position

    def _cmd_drawer(self, pin: int) -> bytes:
        # ESC BEL sets the pulse (10 ms units) for drawer 1, BEL fires it; EM fires drawer 2.
        return ESC + b"\x07\x14\x14" + (b"\x1a" if pin else b"\x07")

    def _cmd_beep(self, times: int) -> bytes:
        return b""  # the mC-Print3 buzzer is an option; nothing sent until one is on the bench
