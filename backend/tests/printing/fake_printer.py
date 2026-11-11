"""A fake Epson: a TCP server on a free port that keeps every byte it receives, and a decoder for tests."""

from __future__ import annotations

import socket
import threading
from dataclasses import dataclass, field


class FakePrinter:
    """`kind` star: sends status bytes to whoever connects, unasked, as a Star in StarPRNT mode does on port
    9100. `kind` epson: quiet until asked, and answers `GS I 67` / `GS I 66` with its model and maker."""

    def __init__(self, kind: str = "star", model: str = "TM-T88VII") -> None:
        self._server = socket.create_server(("127.0.0.1", 0))
        self.port = self._server.getsockname()[1]
        self.address = f"127.0.0.1:{self.port}"
        self.kind = kind
        self.model = model
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
                if self.kind == "star":
                    conn.sendall(b"\x00\x00\x00\x00")  # status bytes, unasked, like a Star on port 9100
                chunks = []
                while chunk := conn.recv(65536):
                    chunks.append(chunk)
                    if self.kind == "epson":
                        answer = b""
                        if b"\x1d\x49\x43" in chunk:
                            answer += b"\x5f" + self.model.encode() + b"\x00"
                        if b"\x1d\x49\x42" in chunk:
                            answer += b"\x5fEPSON\x00"
                        if answer:
                            try:
                                conn.sendall(answer)
                            except OSError:
                                pass
                data = b"".join(chunks)
                if data and not (self.kind == "epson" and data.startswith(b"\x1d\x49")):
                    self.jobs.append(data)

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
    inverted: list[str] = field(default_factory=list)  # text printed white on black (GS B 1)
    unknown: list[bytes] = field(default_factory=list)


def decode(data: bytes) -> Decoded:
    out = Decoded()
    i = 0
    text = bytearray()
    reverse = False

    def flush() -> None:
        nonlocal text
        if text:
            lines = text.decode("ascii").split("\n")
            out.text.extend(lines)
            if reverse:
                out.inverted.extend(t.strip() for t in lines if t.strip())
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
            elif cmd == b"B":
                flush()
                reverse = data[i + 2] == 1
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
