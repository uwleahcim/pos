"""Finding receipt printers on the LAN and telling which language each speaks.

A network receipt printer listens on port 9100 and takes raw bytes, whatever its make, so finding one is
finding that port open; the hub (or the cloud, on a terminal's behalf) tries every address of the subnets
it is told about at once and keeps the ones that answer. Telling the language apart without printing
anything:

- A Star printer in StarPRNT mode sends its status bytes to whoever connects, unasked (the mC-Print3 does;
  `send_raw` drains them for that reason). Bytes before any question: StarPRNT.
- An Epson, and most printers that speak ESC/POS, say nothing until asked. `GS I n` (transmit printer ID)
  asks for the model name (n=67) and the maker (n=66), and the answer is `_` + the name + NUL for each: ESC/POS,
  with the model to show.
- Something that answers neither is listed as reachable with the language unknown, for the manager to set.

The container does not see the LAN's ARP table (Docker's bridge is between), so nothing here reads MAC
addresses; the terminal that asks sends the addresses it has, and the hub scans those subnets.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from dataclasses import asdict, dataclass

from .jobs import PRINTER_PORT

CONNECT_TIMEOUT = 0.35
"""Seconds an address gets to open the port: a printer on the LAN answers in a few milliseconds."""
LISTEN_FOR = 0.8
"""Seconds to wait for a Star's unasked status before asking the Epson question."""
ANSWER_WITHIN = 1.5
"""Seconds an ESC/POS printer gets to answer `GS I`."""
AT_ONCE = 128
MAX_SUBNETS = 6
GS_I_MODEL = b"\x1d\x49\x43"  # GS I 67: model name
GS_I_MAKER = b"\x1d\x49\x42"  # GS I 66: maker name


@dataclass(frozen=True)
class Identity:
    address: str
    reachable: bool
    dialect: str | None = None  # escpos | star | None when it could not be told
    model: str | None = None
    maker: str | None = None

    def as_json(self) -> dict[str, object]:
        return asdict(self)


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


async def identify(address: str, *, port: int = PRINTER_PORT) -> Identity:
    """Which language the printer at `address` (host or host:port) speaks, without printing anything."""
    host, _, given = address.partition(":")
    port = int(given or port)
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 2.0)
    except (OSError, TimeoutError):
        return Identity(address, reachable=False)
    try:
        unasked = await _read_some(reader, LISTEN_FOR)
        if unasked:
            return Identity(address, reachable=True, dialect="star")
        writer.write(GS_I_MODEL + GS_I_MAKER)
        await writer.drain()
        answer = await _read_some(reader, ANSWER_WITHIN)
        if not answer:
            return Identity(address, reachable=True)
        names = _names(answer)
        model = names[0] if names else None
        maker = names[1] if len(names) > 1 else ("EPSON" if b"EPSON" in answer.upper() else None)
        return Identity(address, reachable=True, dialect="escpos", model=model, maker=maker)
    except OSError:
        return Identity(address, reachable=True)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass


async def discover(subnets: list[str], *, port: int = PRINTER_PORT) -> list[Identity]:
    """The printers on `subnets`: every open port 9100, each identified."""
    hosts = await scan(subnets, port=port)
    found = await asyncio.gather(*(identify(f"{h}:{port}" if port != PRINTER_PORT else h, port=port) for h in hosts))
    return list(found)
