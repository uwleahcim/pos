"""Pretend printers: a TCP server on a free port that keeps every byte it receives and answers the questions
`pos.printing.discover` asks, a pretend SNMP agent, a pretend Star answering Star's search, and a decoder
for tests. The answers are the ones the restaurant's TM-T88VII and mC-Print3s gave."""

from __future__ import annotations

import socket
import threading
import time
from dataclasses import dataclass, field

from pos.printing.discover import _ber, _ber_int, _ber_oid, _tlv

STAR_STATUS = bytes.fromhex("29 8a 00 00 00 00 00 04 00 00 00 06 00 00")  # an mC-Print3's status block, all well
EPSON_AUTO_STATUS = bytes.fromhex("14 00 00 0f")  # ESC/POS automatic status: online, paper in
QUESTIONS = (b"\x1b\x06\x01", b"\x10\x04\x01", b"\x1d\x49\x43", b"\x1d\x49\x42")
SETTLE = b"\x00settle\x00"


class FakePrinter:
    """`kind` star: a Star in StarPRNT mode; answers `ESC ACK SOH` with its status block and says nothing on
    its own, as an mC-Print3 does (with `unasked` it sends the block to whoever connects). `kind` epson:
    answers `DLE EOT 1` with a status byte and `GS I 67` / `GS I 66` with its model and maker; with `unasked`
    it also sends its automatic status on connect, as an Epson with ASB on does; with `slow` it takes that
    many seconds over the first status request of a connection, as a TM-T88VII left waiting does. `kind`
    other: an office printer, which answers nothing.

    `jobs` is what would have come out on paper; `heard` is everything received, questions included."""

    def __init__(self, kind: str = "star", model: str = "TM-T88VII", unasked: bool = False, slow: float = 0) -> None:
        self._server = socket.create_server(("127.0.0.1", 0))
        self.port = self._server.getsockname()[1]
        self.address = f"127.0.0.1:{self.port}"
        self.kind = kind
        self.model = model
        self.unasked = unasked
        self.slow = slow
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
            awake = not self.slow
            with conn:
                try:
                    if self.unasked and self.kind == "star":
                        conn.sendall(STAR_STATUS)
                    if self.unasked and self.kind == "epson":
                        conn.sendall(EPSON_AUTO_STATUS)
                    while chunk := conn.recv(65536):
                        chunks.append(chunk)
                        if not awake and QUESTIONS[1] in chunk:
                            time.sleep(self.slow)
                            awake = True
                        if answer := self._answer(chunk):
                            conn.sendall(answer)
                except OSError:
                    pass  # whoever connected hung up without reading: what it sent still counts
                # Kept before the connection is closed: `send_raw` waits for that close, so a job is in `jobs`
                # by the time whoever sent it carries on.
                self._keep(b"".join(chunks))

    def _keep(self, data: bytes) -> None:
        if data == SETTLE:
            self._settled.set()
            return
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


def star_search_reply(model: str = "mC-Print3", commands: str = "STAR", device: str = "MCP31 (STR-001)") -> bytes:
    """An mC-Print3's answer to Star's search, 302 bytes, laid out as the real one: a header that says where
    each section starts, then the model and firmware, the network settings, and the maker, command set,
    device name and class. The hardware address is made up."""

    def padded(text: str, size: int) -> bytes:
        return text.encode().ljust(size, b"\x00")

    header = padded("STR_BCAST", 16) + b"RS1.0.1\x00" + bytes.fromhex("01 2e 00 22 00 74 00 8a 01 2c")
    first = bytes.fromhex("00 52") + padded(model, 16) + padded("3.81", 8) + padded("3.81", 8)
    first += bytes.fromhex("20 00 00 00 00 00 00 00 31 00") + bytes.fromhex("00 11 62 00 00 01") + bytes(4)
    first += bytes([10, 27, 1, 166]) + padded("DHCP", 16) + bytes([255, 255, 255, 0]) + bytes([10, 27, 1, 1])
    second = bytes.fromhex("00 16 31") + bytes(13) + bytes.fromhex("30 00 31 00 31 00")
    third = bytes.fromhex("00 a2") + padded("Star", 32) + padded(commands, 32) + padded(device, 64)
    third += padded("PRINTER", 32)
    reply = header + first + second + third + bytes(2)
    assert len(reply) == 302
    return reply


class FakeStarSearch:
    """A Star's ear for Star's search, on a free UDP port: answers the search with `reply` and nothing else."""

    def __init__(self, reply: bytes | None = None) -> None:
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind(("127.0.0.1", 0))
        self.port = self._socket.getsockname()[1]
        self.reply = star_search_reply() if reply is None else reply
        self.asked: list[bytes] = []
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                packet, sender = self._socket.recvfrom(4096)
            except OSError:
                return
            self.asked.append(packet)
            if packet.startswith(b"STR_BCAST"):
                self._socket.sendto(self.reply, sender)

    def close(self) -> None:
        self._socket.close()


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
