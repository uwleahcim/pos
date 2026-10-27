"""A fake Epson: a TCP server on a free port that keeps every byte it receives, and a decoder for tests."""

from __future__ import annotations

import socket
import threading
from dataclasses import dataclass, field


class FakePrinter:
    def __init__(self) -> None:
        self._server = socket.create_server(("127.0.0.1", 0))
        self.port = self._server.getsockname()[1]
        self.address = f"127.0.0.1:{self.port}"
        self.jobs: list[bytes] = []
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            with conn:
                conn.sendall(b"\x00\x00\x00\x00")  # status bytes, unasked, like a Star on port 9100
                chunks = []
                while chunk := conn.recv(65536):
                    chunks.append(chunk)
                self.jobs.append(b"".join(chunks))

    def close(self) -> None:
        self._server.close()


@dataclass
class Decoded:
    """What a printer would do with the bytes: text lines, images (width, height), cuts, drawer pulses."""

    text: list[str] = field(default_factory=list)
    images: list[tuple[int, int]] = field(default_factory=list)
    cuts: int = 0
    drawer_pulses: int = 0
    beeps: int = 0
    unknown: list[bytes] = field(default_factory=list)


def decode(data: bytes) -> Decoded:
    out = Decoded()
    i = 0
    text = bytearray()

    def flush() -> None:
        nonlocal text
        if text:
            out.text.extend(text.decode("ascii").split("\n"))
            text = bytearray()

    while i < len(data):
        b = data[i]
        if b == 0x1B:  # ESC
            cmd = data[i + 1 : i + 2]
            if cmd == b"@":
                i += 2
            elif cmd in (b"a", b"E"):
                i += 3
            elif cmd == b"d":
                i += 3
            elif cmd == b"p":
                out.drawer_pulses += 1
                i += 5
            elif cmd == b"B":
                out.beeps += 1
                i += 4
            else:
                out.unknown.append(data[i : i + 2])
                i += 2
        elif b == 0x1D:  # GS
            cmd = data[i + 1 : i + 2]
            if cmd == b"!":
                i += 3
            elif cmd == b"V":
                flush()
                out.cuts += 1
                i += 4
            elif cmd == b"v":
                flush()
                xl, xh, yl, yh = data[i + 4 : i + 8]
                row_bytes, height = xl + 256 * xh, yl + 256 * yh
                out.images.append((row_bytes * 8, height))
                i += 8 + row_bytes * height
            else:
                out.unknown.append(data[i : i + 2])
                i += 2
        else:
            text.append(b)
            i += 1
    flush()
    out.text = [t for t in out.text if t != ""]
    return out
