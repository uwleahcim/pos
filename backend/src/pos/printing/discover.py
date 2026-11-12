"""Finding receipt printers on the LAN and telling which language each speaks.

A network receipt printer listens on port 9100 and takes raw bytes, whatever its make, so finding one is
finding that port open; the hub (or the cloud, on a terminal's behalf) tries every address of the subnets
it is told about at once and keeps the ones that answer. An office printer listens there too, so what is
found is then told apart, without printing anything. Nothing printable is sent to a printer that has not
already answered as ESC/POS: a letter sent to the wrong printer waits in its buffer and comes out on the
next ticket, or as a page from a laser.

First its name, asked beside the printer port, both questions at once:

1. SNMP (UDP 161, community `public`), which office printers and Epsons answer: the IEEE 1284 device id
   (maker, model, command set), else the device description.
2. Star's own search (UDP 22222), the question Star's SDK and utilities ask to list printers and read what
   each one is: a Star answers with its model ("mC-Print3"), firmware, maker and command set. Stars answer
   no SNMP, so this is where a Star's name comes from.

A printer whose device id lists a page language (a Canon laser: `CMD:LIPSLX,CPCA`) is listed by its name
and its printer port is sent nothing at all. Every other one is asked on its port for the language it
speaks:

3. `ESC ACK SOH`, sent at once: StarPRNT for "send your status now". A Star answers with its status block
   in a few milliseconds (it says nothing on its own); an Epson ignores it.
4. `DLE EOT 1`: ESC/POS for "send your status now". An ESC/POS printer answers one byte, `0xx1xx10`. A
   TM-T88VII that was left waiting on an open connection takes two or three seconds over its first
   answer, so a printer still silent is asked a second time and given that long.
5. `GS I n`, only to a printer that answered 4: the model name (n=67) and the maker (n=66), each `_` + the
   name + NUL.

Whatever arrives is read for whose it is, not just noticed: an Epson with automatic status on sends four
bytes of its own (`14 00 00 0f`), which is not a Star's block. A receipt printer that kept quiet on its
port gets the language its name implies, marked as a guess; anything else that has a name and no language
is listed as not a receipt printer.

The container does not see the LAN's ARP table (Docker's bridge is between), so nothing here reads MAC
addresses; the terminal that asks sends the addresses it has, and the hub scans those subnets.
"""

from __future__ import annotations

import asyncio
import ipaddress
import re
import socket
from dataclasses import asdict, dataclass, field, replace

from .jobs import PRINTER_PORT

CONNECT_TIMEOUT = 0.35
"""Seconds an address gets to open the port: a printer on the LAN answers in a few milliseconds."""
STATUS_WITHIN = 0.7
"""Seconds a printer gets to answer a status request: a Star takes 10 ms, an Epson 30."""
PATIENT_WITHIN = 3.0
"""Seconds a printer still silent gets to answer the second `DLE EOT 1`: a TM-T88VII that sat on an open
connection for a second answers its first status request about two and a half seconds late."""
ANSWER_WITHIN = 1.5
"""Seconds an ESC/POS printer gets to answer `GS I`."""
SNMP_WITHIN = 1.0
"""Seconds a printer gets to say its name over SNMP."""
STAR_SEARCH_WITHIN = 1.0
"""Seconds a Star gets to answer Star's search."""
TRY_AGAIN_AFTER = 0.6
"""Seconds before a printer that said nothing is asked once more: some take one connection at a time and are
still closing the scan's."""
AT_ONCE = 128
MAX_SUBNETS = 6
STAR_STATUS = b"\x1b\x06\x01"  # ESC ACK SOH: StarPRNT, send the status block now
DLE_EOT_1 = b"\x10\x04\x01"  # DLE EOT 1: ESC/POS, send the printer status now
GS_I_MODEL = b"\x1d\x49\x43"  # GS I 67: model name
GS_I_MAKER = b"\x1d\x49\x42"  # GS I 66: maker name
STAR_SEARCH_PORT = 22222
STAR_SEARCH = b"STR_BCAST" + bytes(7) + b"RQ1.0.0" + bytes([0x00, 0x00, 0x1C, 0x64, 0x31])
"""What Star's SDK broadcasts to find printers; sent here to one address at a time."""
SNMP_PORT = 161
SNMP_OIDS = {
    "id": "1.3.6.1.4.1.2699.1.2.1.2.1.1.3.1",  # ppmPrinterIEEE1284DeviceId: "MFG:Canon;CMD:…;MDL:MF644C;"
    "device": "1.3.6.1.2.1.25.3.2.1.3.1",  # hrDeviceDescr: "Canon MF640C Series"
    "system": "1.3.6.1.2.1.1.1.0",  # sysDescr
}


@dataclass(frozen=True)
class Identity:
    address: str
    reachable: bool
    dialect: str | None = None  # escpos | star | None when it could not be told
    model: str | None = None
    maker: str | None = None
    kind: str | None = None  # receipt | other (it has a name and is not a receipt printer) | None: unknown
    guessed: bool = False  # the language comes from its name, not from an answer on its port
    heard: tuple[str, ...] = field(default=(), compare=False)  # what was asked and what came back, for `identify`

    def as_json(self) -> dict[str, object]:
        return asdict(self) | {"heard": list(self.heard)}


def subnets_for(addresses: list[str], *, limit: int = MAX_SUBNETS) -> list[str]:
    """The /24 of each IPv4 address given, once each, loopback and link-local left out, in the order given."""
    out: list[str] = []
    for text in addresses:
        host = text.strip().rsplit(":", 1)[0] if text.count(":") == 1 else text.strip()
        try:
            ip = ipaddress.IPv4Address(host)
        except ValueError:
            continue
        if ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified:
            continue
        net = str(ipaddress.IPv4Network((int(ip) & 0xFFFFFF00, 24)))
        if net not in out:
            out.append(net)
        if len(out) >= limit:
            break
    return out


def own_addresses() -> list[str]:
    """This machine's IPv4 addresses, as far as a container can tell (its own interfaces)."""
    try:
        infos = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
    except OSError:
        return []
    return sorted({str(info[4][0]) for info in infos})


async def open_port(host: str, port: int, timeout: float = CONNECT_TIMEOUT) -> bool:
    try:
        _reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except (OSError, TimeoutError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except OSError:
        pass
    return True


async def scan(subnets: list[str], *, port: int = PRINTER_PORT, at_once: int = AT_ONCE) -> list[str]:
    """Every address in `subnets` (CIDR, /24 or smaller) with `port` open, in address order."""
    hosts: list[str] = []
    for text in subnets:
        try:
            net = ipaddress.IPv4Network(text, strict=False)
        except ValueError:
            continue
        if net.prefixlen < 24:
            net = ipaddress.IPv4Network((int(net.network_address), 24))
        hosts.extend(str(h) for h in (net.hosts() if net.prefixlen < 31 else net))
    gate = asyncio.Semaphore(at_once)

    async def probe(host: str) -> str | None:
        async with gate:
            return host if await open_port(host, port) else None

    found = await asyncio.gather(*(probe(h) for h in hosts))
    return [h for h in found if h]


async def _read_some(reader: asyncio.StreamReader, seconds: float) -> bytes:
    """Whatever arrives within `seconds`, as one chunk; nothing when the printer stays quiet or hangs up."""
    out = bytearray()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + seconds
    while True:
        left = deadline - loop.time()
        if left <= 0:
            break
        try:
            chunk = await asyncio.wait_for(reader.read(4096), left)
        except (TimeoutError, OSError):
            break
        if not chunk:
            break
        out.extend(chunk)
        if out and left > 0.2:
            # the rest of the answer comes right behind the first byte; a short wait collects it
            try:
                out.extend(await asyncio.wait_for(reader.read(4096), 0.2))
            except (TimeoutError, OSError):
                pass
            break
    return bytes(out)


def _names(answer: bytes) -> list[str]:
    """The strings in a `GS I` answer: each `_` + text + NUL, in the order asked."""
    out = []
    for part in answer.split(b"\x5f")[1:]:
        text = part.split(b"\x00", 1)[0].decode("ascii", "replace").strip()
        if text:
            out.append(text)
    return out


def is_escpos_auto_status(data: bytes) -> bool:
    """The four bytes an ESC/POS printer sends on its own when automatic status is on: `0xx1xx00`, then three
    bytes with bits 4 and 7 clear (`14 00 00 0f` on a TM-T88 with paper in and the cover shut)."""
    return len(data) >= 4 and data[0] & 0x93 == 0x10 and all(b & 0x90 == 0 for b in data[1:4])


def is_star_status(data: bytes) -> bool:
    """A StarPRNT status block: its first byte is odd with bits 4 and 7 clear and holds the block's length
    (7 to 15 bytes) in bits 1 to 3 and 5. An mC-Print3 answers `29 8a 00 00 00 00 00 04 00 00 00 06 00 00`:
    twelve by its header, and two bytes more behind them."""
    if not data or data[0] & 0x91 != 0x01:
        return False
    length = ((data[0] >> 1) & 0x07) | ((data[0] >> 2) & 0x08)
    return 7 <= length <= len(data)


def is_escpos_status(data: bytes) -> bool:
    """The byte an ESC/POS printer answers `DLE EOT 1` with: `0xx1xx10`. No byte of an automatic status, which
    the printer may send at the same moment, has that shape."""
    return any(b & 0x93 == 0x12 for b in data)


def _language(said: bytes) -> str | None:
    """Whose status the bytes are: a Star's block, an ESC/POS printer's answer or automatic status, or nobody's."""
    if is_star_status(said):
        return "star"
    if is_escpos_auto_status(said) or is_escpos_status(said):
        return "escpos"
    return None


def _hex(data: bytes) -> str:
    return data[:24].hex(" ") + (" …" if len(data) > 24 else "") if data else "nothing"


async def _ask_port(host: str, port: int) -> Identity:
    """What the printer's own port says: its language and, for ESC/POS, its model and maker."""
    address = host if port == PRINTER_PORT else f"{host}:{port}"
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 2.0)
    except (OSError, TimeoutError):
        return Identity(address, reachable=False)
    heard: list[str] = []

    async def ask(question: bytes, name: str, seconds: float) -> bytes:
        writer.write(question)
        await writer.drain()
        answer = await _read_some(reader, seconds)
        heard.append(f"{name}: {_hex(answer)}")
        return answer

    def told(dialect: str | None, **more: str | None) -> Identity:
        return Identity(address, reachable=True, dialect=dialect, heard=tuple(heard), **more)

    try:
        # A Star's question first, the moment the port opens; then the ESC/POS one, twice, the second with
        # patience. Each answer is read for either language: a late one counts for whoever it is from.
        questions = (
            (STAR_STATUS, "ESC ACK SOH", STATUS_WITHIN),
            (DLE_EOT_1, "DLE EOT 1", STATUS_WITHIN),
            (DLE_EOT_1, "DLE EOT 1 again", PATIENT_WITHIN),
        )
        dialect = None
        for question, name, seconds in questions:
            dialect = _language(await ask(question, name, seconds))
            if dialect:
                break
        if dialect != "escpos":
            return told(dialect)
        names = _names(await ask(GS_I_MODEL + GS_I_MAKER, "GS I", ANSWER_WITHIN))
        return told("escpos", model=names[0] if names else None, maker=names[1] if len(names) > 1 else None)
    except OSError:
        return told(None)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass


# --- the name a printer gives over SNMP ---------------------------------------------------------------------


def _ber(tag: int, body: bytes) -> bytes:
    size = len(body)
    if size < 0x80:
        return bytes([tag, size]) + body
    count = (size.bit_length() + 7) // 8
    return bytes([tag, 0x80 | count]) + size.to_bytes(count, "big") + body


def _ber_int(value: int) -> bytes:
    return _ber(0x02, value.to_bytes(value.bit_length() // 8 + 1, "big", signed=True))


def _ber_oid(text: str) -> bytes:
    first, second, *rest = (int(part) for part in text.split("."))
    body = bytearray([40 * first + second])
    for number in rest:
        chunk = [number & 0x7F]
        while number := number >> 7:
            chunk.append(0x80 | (number & 0x7F))
        body.extend(reversed(chunk))
    return _ber(0x06, bytes(body))


def snmp_get(oid: str, request_id: int, community: bytes = b"public") -> bytes:
    """An SNMPv1 GetRequest for one object: every printer that speaks SNMP at all speaks v1."""
    binding = _ber(0x30, _ber_oid(oid) + _ber(0x05, b""))
    pdu = _ber(0xA0, _ber_int(request_id) + _ber_int(0) + _ber_int(0) + _ber(0x30, binding))
    return _ber(0x30, _ber_int(0) + _ber(0x04, community) + pdu)


def _tlv(data: bytes, at: int) -> tuple[int, bytes, int]:
    """One BER item at `at`: its tag, its body and where the next one starts."""
    tag, size, at = data[at], data[at + 1], at + 2
    if size & 0x80:
        count = size & 0x7F
        size, at = int.from_bytes(data[at : at + count], "big"), at + count
    if at + size > len(data):
        raise ValueError("cut short")
    return tag, data[at : at + size], at + size


def snmp_answer(packet: bytes) -> tuple[int, bytes | None] | None:
    """The request id of a GetResponse and the string it carries (None when the object is not there)."""
    try:
        _, message, _ = _tlv(packet, 0)
        _, _version, at = _tlv(message, 0)
        _, _community, at = _tlv(message, at)
        tag, pdu, _ = _tlv(message, at)
        if tag != 0xA2:
            return None
        _, request_id, at = _tlv(pdu, 0)
        _, _status, at = _tlv(pdu, at)
        _, _index, at = _tlv(pdu, at)
        _, bindings, _ = _tlv(pdu, at)
        _, binding, _ = _tlv(bindings, 0)
        _, _oid, at = _tlv(binding, 0)
        tag, value, _ = _tlv(binding, at)
    except (IndexError, ValueError):
        return None
    return int.from_bytes(request_id, "big", signed=True), value if tag == 0x04 else None


class _SnmpAnswers(asyncio.DatagramProtocol):
    def __init__(self, want: int) -> None:
        self.want = want
        self.got: dict[int, bytes | None] = {}
        self.done: asyncio.Future[None] = asyncio.get_running_loop().create_future()

    def _finish(self) -> None:
        if not self.done.done():
            self.done.set_result(None)

    def datagram_received(self, data: bytes, addr: object) -> None:
        answer = snmp_answer(data)
        if answer is not None:
            self.got[answer[0]] = answer[1]
            if len(self.got) >= self.want:
                self._finish()

    def error_received(self, exc: Exception) -> None:
        self._finish()  # port unreachable: nothing speaks SNMP there


async def snmp_names(host: str, *, port: int = SNMP_PORT, within: float | None = None) -> dict[str, str]:
    """What the device at `host` says of itself over SNMP, by the keys of `SNMP_OIDS`; empty when it says
    nothing. One request per object: a v1 device refuses a whole request for one object it lacks."""
    keys = list(SNMP_OIDS)
    loop = asyncio.get_running_loop()
    try:
        transport, answers = await loop.create_datagram_endpoint(
            lambda: _SnmpAnswers(len(keys)), remote_addr=(host, port)
        )
    except OSError:
        return {}
    try:
        for n, key in enumerate(keys, start=1):
            transport.sendto(snmp_get(SNMP_OIDS[key], n))
        await asyncio.wait_for(asyncio.shield(answers.done), SNMP_WITHIN if within is None else within)
    except (OSError, TimeoutError):
        pass
    finally:
        transport.close()
    out = {}
    for n, key in enumerate(keys, start=1):
        text = (answers.got.get(n) or b"").decode("utf-8", "replace").replace("\x00", "").strip()
        if text:
            out[key] = text
    return out


# --- the name a Star gives to Star's search --------------------------------------------------------------------


def star_search_answer(packet: bytes) -> dict[str, str] | None:
    """What a Star says of itself in its answer to `STAR_SEARCH`: `model`, `firmware`, `maker`, `commands`,
    `device`, the ones it gave; None when the packet is not such an answer.

    The answer starts `STR_BCAST`, then `RS1.0.1` at 16 and, from 26, where each of its sections starts.
    The first section holds the model (16 bytes, NUL padded) and the firmware (8); the third the maker
    (32), the command set (32) and the device name (64). An mC-Print3: "mC-Print3", "3.81", "Star", "STAR",
    "MCP31 (STR-001)"."""
    if len(packet) < 0x22 or not packet.startswith(b"STR_BCAST") or packet[0x10:0x12] != b"RS":
        return None

    def text(at: int, size: int) -> str:
        return packet[at : at + size].split(b"\x00", 1)[0].decode("ascii", "replace").strip()

    first = int.from_bytes(packet[0x1A:0x1C], "big") + 2  # each section starts with its own length
    third = int.from_bytes(packet[0x1E:0x20], "big") + 2
    fields = {"model": text(first, 16), "firmware": text(first + 16, 8)}
    if third > first:
        fields |= {"maker": text(third, 32), "commands": text(third + 32, 32), "device": text(third + 64, 64)}
    return {key: value for key, value in fields.items() if value}


class _StarAnswer(asyncio.DatagramProtocol):
    def __init__(self) -> None:
        self.said: asyncio.Future[dict[str, str] | None] = asyncio.get_running_loop().create_future()

    def datagram_received(self, data: bytes, addr: object) -> None:
        answer = star_search_answer(data)
        if answer is not None and not self.said.done():
            self.said.set_result(answer)

    def error_received(self, exc: Exception) -> None:
        if not self.said.done():
            self.said.set_result(None)  # port unreachable: not a Star


async def star_search(host: str, *, port: int = STAR_SEARCH_PORT, within: float | None = None) -> dict[str, str] | None:
    """What the printer at `host` answers to Star's search, as `star_search_answer` reads it; None when it
    does not answer (it is not a Star, or UDP does not reach it)."""
    loop = asyncio.get_running_loop()
    try:
        transport, answer = await loop.create_datagram_endpoint(_StarAnswer, remote_addr=(host, port))
    except OSError:
        return None
    try:
        transport.sendto(STAR_SEARCH)
        return await asyncio.wait_for(asyncio.shield(answer.said), STAR_SEARCH_WITHIN if within is None else within)
    except (OSError, TimeoutError):
        return None
    finally:
        transport.close()


STAR_MODELS = re.compile(r"mc-?print|mc-?label|\bmpop\b|\btsp\d{3}|\bsp7\d\d|\bbsc-?10|\bfvp-?10|star micronics", re.I)
ESCPOS_MODELS = re.compile(
    r"\btm-[a-z]{1,2}\d|\bub-[a-z]\d\d|\bsrp-[a-z]?\d|\bct-[a-z]\d|\bbtp-|\blk-t|bixolon|citizen|xprinter|rongta|\bsnbc\b|sewoo|receipt",
    re.I,
)


def named(snmp: dict[str, str]) -> tuple[str | None, str | None, str | None]:
    """Maker, model and the language the name implies (None: no receipt printer we know), from what
    `snmp_names` heard."""
    fields = {}
    for part in snmp.get("id", "").split(";"):
        key, colon, value = part.partition(":")
        if colon and value.strip():
            fields[key.strip().upper()] = value.strip()
    maker = fields.get("MFG") or fields.get("MANUFACTURER")
    described = snmp.get("device") or (snmp.get("system") or "").partition("\n")[0]
    model = " ".join((fields.get("MDL") or fields.get("MODEL") or described).split())[:60]
    if maker and model.lower().startswith(maker.lower() + " "):
        model = model[len(maker) :].strip()
    commands = (fields.get("CMD") or fields.get("COMMAND SET") or "").upper()
    text = f"{maker or ''} {model}"
    language: str | None = None
    if re.search(r"\bSTAR", commands) or (maker or "").lower() in ("star", "star micronics"):
        language = "star"
    elif "ESC/POS" in commands or "ESCPOS" in commands:
        language = "escpos"
    elif STAR_MODELS.search(text):
        language = "star"
    elif ESCPOS_MODELS.search(text):
        language = "escpos"
    return maker, model or None, language


OFFICE_COMMANDS = re.compile(
    r"PCL|POSTSCRIPT|BRSCRIPT|\bPS\d?\b|\bPDF|\bPJL\b|LIPS|CPCA|\bUFR|ESCPL|ESC/P-R|ESCPR|\bURF\b|PWG|\bXPS\b"
    r"|KPDL|RPCS|\bGDI\b|\bHBP\b|\bZJS\b|\bSPL",
    re.I,
)


def office(snmp: dict[str, str]) -> bool:
    """Whether the device id lists a page language (PCL, PostScript, Canon's `LIPSLX,CPCA`, …): a laser or an
    inkjet, to which raw bytes on port 9100 are the start of a page."""
    commands = re.search(r"(?:^|;)\s*(?:CMD|COMMAND SET)\s*:([^;]*)", snmp.get("id", ""), re.I)
    return bool(commands and OFFICE_COMMANDS.search(commands.group(1)))


def star_named(star: dict[str, str]) -> tuple[str | None, str | None, str]:
    """Maker, model and language from a Star's answer to the search. A Star speaks StarPRNT unless it says
    it was set to an ESC/POS emulation."""
    commands = star.get("commands", "").upper()
    language = "escpos" if "ESC" in commands and "STAR" not in commands else "star"
    return star.get("maker") or "Star", star.get("model") or star.get("device"), language


async def identify(
    address: str, *, port: int = PRINTER_PORT, snmp_port: int = SNMP_PORT, star_port: int = STAR_SEARCH_PORT
) -> Identity:
    """Which language the printer at `address` (host or host:port) speaks and what it calls itself, without
    printing anything."""
    host, _, given = address.partition(":")
    port = int(given or port)
    snmp, star = await asyncio.gather(snmp_names(host, port=snmp_port), star_search(host, port=star_port))
    maker, model, language = named(snmp)
    heard = [f"SNMP {key}: {text[:80]}" for key, text in snmp.items()]
    if star:
        maker, model, language = star_named(star)
        heard.append("Star search: " + ", ".join(f"{key} {text}" for key, text in star.items()))
    if language is None and office(snmp):
        # It says it takes pages, not tickets: its printer port is not sent a byte.
        reachable = await open_port(host, port, 2.0)
        heard.append("printer port: not asked, it prints pages" if reachable else "printer port: closed")
        kind = "other" if reachable else None
        return Identity(address, reachable, model=model, maker=maker, kind=kind, heard=tuple(heard))
    found = replace(await _ask_port(host, port), address=address)
    if not found.reachable:
        return found
    found = replace(found, maker=found.maker or maker, model=found.model or model, heard=(*found.heard, *heard))
    if found.dialect is None and language is not None:
        found = replace(found, dialect=language, guessed=True)
    kind = "receipt" if found.dialect else ("other" if found.model or found.maker else None)
    return replace(found, kind=kind)


async def discover(
    subnets: list[str], *, port: int = PRINTER_PORT, snmp_port: int = SNMP_PORT, star_port: int = STAR_SEARCH_PORT
) -> list[Identity]:
    """The printers on `subnets`: every open port 9100, each identified; receipt printers first, then the ones
    that said nothing, then the ones that are something else."""
    hosts = await scan(subnets, port=port)

    async def one(host: str) -> Identity:
        address = f"{host}:{port}" if port != PRINTER_PORT else host
        return await identify(address, port=port, snmp_port=snmp_port, star_port=star_port)

    found = list(await asyncio.gather(*(one(h) for h in hosts)))
    silent = [n for n, f in enumerate(found) if f.kind is None]
    if silent:
        # Asked once more, with the others out of the way: some take one connection at a time and were
        # still closing the scan's.
        await asyncio.sleep(TRY_AGAIN_AFTER)
        for n, again in zip(silent, await asyncio.gather(*(one(hosts[n]) for n in silent)), strict=True):
            found[n] = again
    order = {"receipt": 0, None: 1, "other": 2}
    return sorted(found, key=lambda f: order[f.kind])
