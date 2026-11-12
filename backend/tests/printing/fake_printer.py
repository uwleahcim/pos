"""Pretend printers: a TCP server on a free port that keeps every byte it receives and answers the questions
`pos.printing.discover` asks, a pretend SNMP agent, and a decoder for tests."""

from __future__ import annotations

import socket
import threading
from dataclasses import dataclass, field

from pos.printing.discover import _ber, _ber_int, _ber_oid, _tlv

STAR_STATUS = bytes.fromhex("23 86 00 00 00 00 00 00 00")  # a StarPRNT status block, nine bytes, all well
EPSON_AUTO_STATUS = bytes.fromhex("14 00 00 0f")  # ESC/POS automatic status: online, paper in
QUESTIONS = (b"\x1b\x06\x01", b"\x10\x04\x01", b"\x1d\x49\x43", b"\x1d\x49\x42")
SETTLE = b"\x00settle\x00"


class FakePrinter:
    """`kind` star: a Star in StarPRNT mode; sends its status block to whoever connects (`unasked`, as on port
    9100) and whenever `ESC ACK SOH` asks. `kind` epson: answers `DLE EOT 1` with a status byte and `GS I 67` /
    `GS I 66` with its model and maker; with `unasked` it also sends its automatic status on connect, as an
    Epson with ASB left on does. `kind` other: an office printer, which answers nothing.

    `jobs` is what would have come out on paper; `heard` is everything received, questions included."""

    def __init__(self, kind: str = "star", model: str = "TM-T88VII", unasked: bool | None = None) -> None:
        self._server = socket.create_server(("127.0.0.1", 0))
        self.port = self._server.getsockname()[1]
        self.address = f"127.0.0.1:{self.port}"
        self.kind = kind
        self.model = model
        self.unasked = kind == "star" if unasked is None else unasked
        self.jobs: list[bytes] = []
        self.heard: list[bytes] = []
        self._settled = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _answer(self, chunk: bytes) -> bytes:
        answer = b""
        if self.kind == "star" and QUESTIONS[0] in chunk:
            answer += STAR_STATUS
        if self.kind == "epson":
            if QUESTIONS[1] in chunk:
                answer += b"\x16"
            if QUESTIONS[2] in chunk:
                answer += b"\x5f" + self.model.encode() + b"\x00"
            if QUESTIONS[3] in chunk:
                answer += b"\x5fEPSON\x00"
        return answer

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            chunks = []
            with conn:
                try:
                    if self.unasked and self.kind == "star":
                        conn.sendall(STAR_STATUS)
                    if self.unasked and self.kind == "epson":
                        conn.sendall(EPSON_AUTO_STATUS)
                    while chunk := conn.recv(65536):
                        chunks.append(chunk)
                        if answer := self._answer(chunk):
                            conn.sendall(answer)
                except OSError:
                    pass  # whoever connected hung up without reading: what it sent still counts
            data = b"".join(chunks)
            if data == SETTLE:
                self._settled.set()
                continue
            if data:
                self.heard.append(data)
            for question in QUESTIONS:
                data = data.replace(question, b"")
            if data:
                self.jobs.append(data)

    def settle(self) -> None:
        """Returns once everything sent so far is in `heard` and `jobs`: connections are served one at a time,
        so a last one that says only "settle" is behind all the others."""
        self._settled.clear()
        with socket.create_connection(("127.0.0.1", self.port)) as conn:
            conn.sendall(SETTLE)
        assert self._settled.wait(3), "the pretend printer did not settle"

    def close(self) -> None:
        self._server.close()


class FakeSnmp:
    """What a printer's SNMP agent does, on a free UDP port: answers a GetRequest for an object it has with
    the string, and for one it lacks with noSuchName, as SNMPv1 does."""

    def __init__(self, objects: dict[str, str]) -> None:
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind(("127.0.0.1", 0))
        self.port = self._socket.getsockname()[1]
        self.objects = {_ber_oid(oid): text.encode() for oid, text in objects.items()}
        self.asked = 0
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                packet, sender = self._socket.recvfrom(4096)
            except OSError:
                return
            self.asked += 1
            _, message, _ = _tlv(packet, 0)
            _, _version, at = _tlv(message, 0)
            _, community, at = _tlv(message, at)
            _, pdu, _ = _tlv(message, at)
            _, request_id, at = _tlv(pdu, 0)
            _, _status, at = _tlv(pdu, at)
            _, _index, at = _tlv(pdu, at)
            _, bindings, _ = _tlv(pdu, at)
            _, binding, _ = _tlv(bindings, 0)
            _, oid, _ = _tlv(binding, 0)
            oid = _ber(0x06, oid)
            value = self.objects.get(oid)
            status = 0 if value is not None else 2  # noSuchName
            answer = _ber(0x30, oid + (_ber(0x04, value) if value is not None else _ber(0x05, b"")))
            pdu = _ber(
                0xA2, _ber(0x02, request_id) + _ber_int(status) + _ber_int(0 if value else 1) + _ber(0x30, answer)
            )
            self._socket.sendto(_ber(0x30, _ber_int(0) + _ber(0x04, community) + pdu), sender)

    def close(self) -> None:
        self._socket.close()


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
