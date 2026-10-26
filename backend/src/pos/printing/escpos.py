"""A small ESC/POS byte builder for Epson TM printers.

Plain ASCII goes as text, which every printer renders. Anything else (Chinese, accents, symbols) is drawn
with a font into a one-bit raster and sent as an image, so the ticket looks the same on every printer
model whatever code pages it ships with. Lines mix the two freely.
"""

from __future__ import annotations

import os
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
    cut = text.rfind(" ", 0, width + 1)
    if cut <= 0:
        cut = width
    return text[:cut].rstrip(), text[cut:].lstrip()


class Builder:
    """Collects ESC/POS commands; `bytes(builder)` is the job."""

    def __init__(self, *, dots: int = 576, font: str | None = None, chars_per_line: int | None = None) -> None:
        self.dots = dots  # 576 for 80 mm paper, 384 for 58 mm
        self.chars = chars_per_line or (48 if dots >= 576 else 32)
        self._font_path = font or find_font()
        self._parts: list[bytes] = [ESC + b"@"]  # initialize

    def __bytes__(self) -> bytes:
        return b"".join(self._parts)

    # Text ------------------------------------------------------------------------------------------------
    def line(self, text: str = "", *, bold: bool = False, big: bool = False, center: bool = False) -> Builder:
        """One line. Plain ASCII as text; anything else as an image at the same size."""
        if text and not is_plain(text):
            return self.image_line(text, bold=bold, big=big, center=center)
        width = self.chars // 2 if big else self.chars
        if len(text) > width:  # wrap long plain lines ourselves so a double-width line never splits a word
            head, tail = _split(text, width)
            self.line(head, bold=bold, big=big, center=center)
            return self.line("  " + tail, bold=bold, big=big, center=center)
        self._parts.append(ESC + b"a" + (b"\x01" if center else b"\x00"))
        self._parts.append(ESC + b"E" + (b"\x01" if bold else b"\x00"))
        self._parts.append(GS + b"!" + (b"\x11" if big else b"\x00"))
        self._parts.append(text.encode("ascii") + b"\n")
        self._parts.append(GS + b"!\x00" + ESC + b"E\x00" + ESC + b"a\x00")
        return self

    def columns(self, left: str, right: str, *, bold: bool = False) -> Builder:
        """`left` padded, `right` flush to the right edge, on one line."""
        width = self.chars
        space = max(1, width - len(right) - len(left)) if is_plain(left) and is_plain(right) else 1
        return self.line(f"{left}{' ' * space}{right}", bold=bold)

    def rule(self) -> Builder:
        return self.line("-" * self.chars)

    def feed(self, lines: int = 1) -> Builder:
        self._parts.append(ESC + b"d" + bytes([max(0, min(lines, 255))]))
        return self

    # Images ---------------------------------------------------------------------------------------------
    def image_line(self, text: str, *, bold: bool = False, big: bool = False, center: bool = False) -> Builder:
        size = 48 if big else 26
        font = self._load_font(size)
        probe = Image.new("1", (1, 1), 1)
        box = ImageDraw.Draw(probe).textbbox((0, 0), text, font=font, stroke_width=1 if bold else 0)
        width = min(self.dots, box[2] - box[0] + 4)
        height = box[3] - box[1] + 6
        img = Image.new("1", (self.dots, height), 1)
        x = (self.dots - width) // 2 if center else 0
        ImageDraw.Draw(img).text((x + 2 - box[0], 3 - box[1]), text, font=font, fill=0, stroke_width=1 if bold else 0)
        return self.image(img)

    def image(self, img: Image.Image) -> Builder:
        """GS v 0 raster: one bit per dot, 1 = black, rows padded to whole bytes, width capped at the paper."""
        if img.mode != "1":
            img = img.convert("1")
        if img.width > self.dots:
            img = img.crop((0, 0, self.dots, img.height))
        row_bytes = (img.width + 7) // 8
        padded = Image.new("1", (row_bytes * 8, img.height), 1)
        padded.paste(img, (0, 0))
        data = bytes(255 - b for b in padded.tobytes())  # PIL: 1 = white; printer: 1 = black
        header = GS + b"v0\x00" + bytes([row_bytes & 0xFF, row_bytes >> 8, img.height & 0xFF, img.height >> 8])
        self._parts.append(header + data)
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
        self._parts.append(GS + b"V\x42" + bytes([feed]))  # partial cut after feeding
        return self

    def drawer_kick(self, pin: int = 0) -> Builder:
        """ESC p: pulse the cash drawer solenoid (pin 0 = drawer 1, pin 1 = drawer 2)."""
        self._parts.append(ESC + b"p" + bytes([pin, 25, 250]))
        return self

    def beep(self, times: int = 2) -> Builder:
        self._parts.append(ESC + b"B" + bytes([times, 5]))  # TM-m30 and most Epsons; ignored elsewhere
        return self
