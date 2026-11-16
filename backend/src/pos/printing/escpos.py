"""A small ESC/POS byte builder for Epson TM printers (and the base for other printer languages).

Plain ASCII goes as text, which every printer renders. Anything else (Chinese, accents, symbols) is drawn
with a font into a one-bit raster and sent as an image, so the ticket looks the same on every printer
model whatever code pages it ships with. Lines mix the two freely.

The ticket logic (wrapping, columns, drawing text) lives here; the bytes for each primitive are in the
`_cmd_*` methods, which `pos.printing.star.StarBuilder` overrides for StarPRNT.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ESC = b"\x1b"
GS = b"\x1d"

FONT_CANDIDATES = (
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/System/Library/Fonts/PingFang.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
)


def find_font() -> str | None:
    """A font that covers Chinese: POS_CJK_FONT, else the first known path that exists."""
    env = os.environ.get("POS_CJK_FONT")
    if env and Path(env).exists():
        return env
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            return path
    return None


def is_plain(text: str) -> bool:
    return all(32 <= ord(ch) < 127 for ch in text)


def _split(text: str, width: int) -> tuple[str, str]:
    """`text` cut at the last space that fits in `width` characters, else at `width`. The spaces a line starts
    with are not a place to cut: an indented word longer than the line would never get any shorter."""
    indent = len(text) - len(text.lstrip(" "))
    cut = text.rfind(" ", indent, width + 1)
    if cut <= indent:
        cut = max(width, indent + 1)
    return text[:cut].rstrip(), text[cut:].lstrip()


def fit(text: str, wide: Callable[[str], int], room: int) -> tuple[str, str]:
    """`text` cut where it stops fitting in `room` dots as `wide` measures it, and what is left over: whole
    words when it can, and always at least one character, so printing the rest on the next line ends."""
    if wide(text) <= room:
        return text, ""
    indent = text[: len(text) - len(text.lstrip(" "))]
    words = text.lstrip(" ").split(" ")
    keep = max(len(words) - 1, 1)
    while keep > 1 and wide(indent + " ".join(words[:keep])) > room:
        keep -= 1
    head, tail = indent + " ".join(words[:keep]), " ".join(words[keep:])
    if wide(head) > room:  # one word longer than the line (or Chinese, which has no spaces): cut it
        cut = len(head) - 1
        while cut > len(indent) + 1 and wide(head[:cut]) > room:
            cut -= 1
        head, tail = head[:cut], f"{head[cut:]} {tail}".strip()
    return head, tail


class Builder:
    """Collects ESC/POS commands; `bytes(builder)` is the job."""

    def __init__(self, *, dots: int = 576, font: str | None = None, chars_per_line: int | None = None) -> None:
        self.dots = dots  # 576 for 80 mm paper, 384 for 58 mm
        self.chars = chars_per_line or (48 if dots >= 576 else 32)
        self._font_path = font or find_font()
        self._parts: list[bytes] = [self._cmd_init()]

    def __bytes__(self) -> bytes:
        return b"".join(self._parts)

    # Text ------------------------------------------------------------------------------------------------
    def line(
        self, text: str = "", *, bold: bool = False, big: bool = False, center: bool = False, invert: bool = False
    ) -> Builder:
        """One line. Plain ASCII as text; anything else as an image at the same size. `invert` prints white
        on a black bar across the paper (a void)."""
        if text and not is_plain(text):
            return self.image_line(text, bold=bold, big=big, center=center, invert=invert)
        width = self.chars // 2 if big else self.chars
        if len(text) > width:  # wrap long plain lines ourselves so a double-width line never splits a word
            head, tail = _split(text, width)
            self.line(head, bold=bold, big=big, center=center, invert=invert)
            return self.line("  " + tail, bold=bold, big=big, center=center, invert=invert)
        if invert:
            text = text.center(width) if center else text.ljust(width)
        self._parts.append(self._cmd_text(text, bold=bold, big=big, center=center, invert=invert))
        return self

    def columns(self, left: str, right: str, *, bold: bool = False, big: bool = False, hang: str = "  ") -> Builder:
        """`left` at the left edge and `right` flush to the right edge, on one line. A `left` too long to
        stand beside `right` goes on over the next lines, each starting with `hang`; `right` stays on the
        first (a long dish on a bill keeps its price in the column)."""
        if not (is_plain(left) and is_plain(right)):
            return self.image_columns(left, right, bold=bold, big=big, hang=hang)
        width = self.chars // 2 if big else self.chars
        room = width - len(right) - 1
        tail = ""
        if len(left) > room > 0:
            left, tail = _split(left, room)
        self.line(f"{left}{' ' * max(1, width - len(right) - len(left))}{right}", bold=bold, big=big)
        return self.line(hang + tail, bold=bold, big=big) if tail else self

    def rule(self) -> Builder:
        return self.line("-" * self.chars)

    def feed(self, lines: int = 1) -> Builder:
        self._parts.append(self._cmd_feed(max(0, min(lines, 255))))
        return self

    # Images ---------------------------------------------------------------------------------------------
    def image_line(
        self, text: str, *, bold: bool = False, big: bool = False, center: bool = False, invert: bool = False
    ) -> Builder:
        """A line drawn with the font. One too wide for the paper goes on below instead of being cut off at
        the edge."""
        size = 48 if big else 26
        font = self._load_font(size)
        probe = ImageDraw.Draw(Image.new("1", (1, 1), 1))

        def wide(part: str) -> int:
            box = probe.textbbox((0, 0), part, font=font, stroke_width=1 if bold else 0)
            return box[2] - box[0]

        text, tail = fit(text, wide, self.dots - 4)
        box = probe.textbbox((0, 0), text, font=font, stroke_width=1 if bold else 0)
        width = min(self.dots, box[2] - box[0] + 4)
        height = box[3] - box[1] + 6
        paper, ink = (0, 1) if invert else (1, 0)
        img = Image.new("1", (self.dots, height), paper)
        x = (self.dots - width) // 2 if center else 0
        stroke = 1 if bold else 0
        ImageDraw.Draw(img).text((x + 2 - box[0], 3 - box[1]), text, font=font, fill=ink, stroke_width=stroke)
        self.image(img)
        return self.image_line("  " + tail, bold=bold, big=big, center=center, invert=invert) if tail else self

    def image_columns(
        self, left: str, right: str, *, bold: bool = False, big: bool = False, hang: str = "  "
    ) -> Builder:
        """`columns` drawn with the font: what a line with Chinese in it needs to keep `right` at the edge,
        and what a printer that draws every line (a Star) prints for all of them."""
        size = 48 if big else 26
        font = self._load_font(size)
        stroke = 1 if bold else 0
        strip = Image.new("1", (self.dots, size + 6 if not big else size + 10), 1)
        draw = ImageDraw.Draw(strip)

        def wide(text: str) -> int:
            box = draw.textbbox((0, 0), text, font=font, stroke_width=stroke)
            return box[2] - box[0]

        left, tail = fit(left, wide, max(self.dots - wide(right) - 4 - size // 2, size))
        draw.text((2, 3), left, font=font, fill=0, stroke_width=stroke)
        draw.text((self.dots - wide(right) - 2, 3), right, font=font, fill=0, stroke_width=stroke)
        self.image(strip)
        return self.line(hang + tail, bold=bold, big=big) if tail else self

    def image(self, img: Image.Image) -> Builder:
        """One bit per dot, 1 = black, rows padded to whole bytes, width capped at the paper."""
        if img.mode != "1":
            img = img.convert("1")
        if img.width > self.dots:
            img = img.crop((0, 0, self.dots, img.height))
        row_bytes = (img.width + 7) // 8
        padded = Image.new("1", (row_bytes * 8, img.height), 1)
        padded.paste(img, (0, 0))
        data = bytes(255 - b for b in padded.tobytes())  # PIL: 1 = white; printer: 1 = black
        self._parts.append(self._cmd_raster(row_bytes, img.height, data))
        return self

    def _load_font(self, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
        if self._font_path:
            try:
                return ImageFont.truetype(self._font_path, size)
            except OSError:
                pass
        return ImageFont.load_default(size=size)

    # Hardware -------------------------------------------------------------------------------------------
    def cut(self, *, feed: int = 4) -> Builder:
        self._parts.append(self._cmd_cut(feed))
        return self

    def drawer_kick(self, pin: int = 0) -> Builder:
        """Pulse the cash drawer solenoid (pin 0 = drawer 1, pin 1 = drawer 2)."""
        self._parts.append(self._cmd_drawer(pin))
        return self

    def beep(self, times: int = 2) -> Builder:
        self._parts.append(self._cmd_beep(times))
        return self

    # The bytes of each primitive: ESC/POS here, overridden per printer language ---------------------------
    def _cmd_init(self) -> bytes:
        return ESC + b"@"

    def _cmd_text(self, text: str, *, bold: bool, big: bool, center: bool, invert: bool = False) -> bytes:
        return (
            (GS + b"B\x01" if invert else b"")  # white on black
            + ESC
            + b"a"
            + (b"\x01" if center else b"\x00")
            + ESC
            + b"E"
            + (b"\x01" if bold else b"\x00")
            + GS
            + b"!"
            + (b"\x11" if big else b"\x00")
            + text.encode("ascii")
            + b"\n"
            + GS
            + b"!\x00"
            + ESC
            + b"E\x00"
            + ESC
            + b"a\x00"
            + (GS + b"B\x00" if invert else b"")
        )

    def _cmd_feed(self, lines: int) -> bytes:
        return ESC + b"d" + bytes([lines])

    def _cmd_raster(self, row_bytes: int, height: int, data: bytes) -> bytes:
        """GS v 0: the whole image in one command."""
        return GS + b"v0\x00" + bytes([row_bytes & 0xFF, row_bytes >> 8, height & 0xFF, height >> 8]) + data

    def _cmd_cut(self, feed: int) -> bytes:
        return GS + b"V\x42" + bytes([feed])  # partial cut after feeding

    def _cmd_drawer(self, pin: int) -> bytes:
        return ESC + b"p" + bytes([pin, 25, 250])  # ESC p

    def _cmd_beep(self, times: int) -> bytes:
        return ESC + b"B" + bytes([times, 5])  # TM-m30 and most Epsons; ignored elsewhere
