"""StarPRNT bytes for Star printers such as the mC-Print3 and TSP series.

A Star printer in its default mode cuts the paper whenever a raster graphics block ends (an mC-Print3 did,
whatever the end-of-page settings said), so a Star ticket is one tall image: every line, plain or Chinese,
is drawn with the font, the strips are stacked, raster mode is entered once, and the cut at the end comes
from leaving raster mode. The drawer is `BEL` in line mode. In ESC/POS emulation a Star takes the Epson
bytes instead.
"""

from __future__ import annotations

from PIL import Image, ImageDraw

from .escpos import ESC, Builder, _split, is_plain

RASTER_IN = ESC + b"*rA" + ESC + b"*rP0\x00"  # enter raster mode, continuous page
RASTER_OUT = ESC + b"*rB"  # back to line mode; the printer runs its end-of-page action here (cut)


class StarBuilder(Builder):
    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._strips: list[Image.Image] = []
        self._tail: list[bytes] = []  # line mode bytes after the image (drawer, nothing else yet)

    def __bytes__(self) -> bytes:
        parts = [self._cmd_init()]
        if self._strips:
            height = sum(s.height for s in self._strips)
            page = Image.new("1", (self.dots, height), 1)
            y = 0
            for strip in self._strips:
                page.paste(strip, (0, y))
                y += strip.height
            row_bytes = self.dots // 8
            data = bytes(255 - b for b in page.tobytes())
            rows = (data[i * row_bytes : (i + 1) * row_bytes] for i in range(height))
            body = b"".join(b"b" + bytes([row_bytes & 0xFF, row_bytes >> 8]) + row for row in rows)
            parts.append(RASTER_IN + body + RASTER_OUT)
        parts.extend(self._tail)
        return b"".join(parts)

    # Everything printable becomes a strip ------------------------------------------------------------------
    def line(
        self, text: str = "", *, bold: bool = False, big: bool = False, center: bool = False, invert: bool = False
    ) -> Builder:
        if not text:
            return self.feed(1)
        if is_plain(text):
            width = self.chars // 2 if big else self.chars
            if len(text) > width:
                head, tail = _split(text, width)
                self.line(head, bold=bold, big=big, center=center, invert=invert)
                return self.line("  " + tail, bold=bold, big=big, center=center, invert=invert)
        return self.image_line(text, bold=bold, big=big, center=center, invert=invert)

    def columns(self, left: str, right: str, *, bold: bool = False, big: bool = False, hang: str = "  ") -> Builder:
        """Left text at the left edge, right text flush right, drawn on one strip; a left too long for the
        line goes on below it."""
        return self.image_columns(left, right, bold=bold, big=big, hang=hang)

    def rule(self) -> Builder:
        strip = Image.new("1", (self.dots, 8), 1)
        ImageDraw.Draw(strip).line((0, 4, self.dots, 4), fill=0, width=2)
        return self.image(strip)

    def feed(self, lines: int = 1) -> Builder:
        if lines > 0:
            self._strips.append(Image.new("1", (self.dots, 30 * lines), 1))
        return self

    def image(self, img: Image.Image) -> Builder:
        if img.mode != "1":
            img = img.convert("1")
        if img.width != self.dots:
            fitted = Image.new("1", (self.dots, img.height), 1)
            fitted.paste(img.crop((0, 0, min(img.width, self.dots), img.height)), (0, 0))
            img = fitted
        self._strips.append(img)
        return self

    # Hardware ----------------------------------------------------------------------------------------------
    def cut(self, *, feed: int = 4) -> Builder:
        return self.feed(2)  # leaving raster mode cuts; a little space so the cut clears the last line

    def drawer_kick(self, pin: int = 0) -> Builder:
        # ESC BEL sets the pulse (10 ms units) for drawer 1, BEL fires it; EM fires drawer 2.
        self._tail.append(ESC + b"\x07\x14\x14" + (b"\x1a" if pin else b"\x07"))
        return self

    def beep(self, times: int = 2) -> Builder:
        return self  # the mC-Print3 buzzer is an option; nothing sent until one is on the bench
