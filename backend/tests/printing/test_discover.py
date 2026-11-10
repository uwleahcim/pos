"""Finding printers on the LAN and telling Epson from Star without printing anything."""

from __future__ import annotations

import asyncio
import socket

from pos.printing.discover import identify, scan, subnets_for

from .fake_printer import FakePrinter


def test_the_subnets_come_from_the_addresses_a_terminal_has_loopback_left_out():
    assert subnets_for(["172.19.1.179:8000", "172.19.1.44", "127.0.0.1", "192.168.4.9", "172.19.1.2", "nope"]) == [
        "172.19.1.0/24",
        "192.168.4.0/24",
    ]
    assert subnets_for(["169.254.3.3", "0.0.0.0"]) == []
    assert len(subnets_for([f"10.{n}.0.1" for n in range(20)])) == 6


def test_a_star_is_known_by_the_status_it_sends_unasked_and_an_epson_by_its_answer_to_gs_i():
    star, epson = FakePrinter("star"), FakePrinter("epson")
    try:
        found_star = asyncio.run(identify(star.address))
        assert (found_star.reachable, found_star.dialect, found_star.model) == (True, "star", None)
        found_epson = asyncio.run(identify(epson.address))
        assert (found_epson.dialect, found_epson.model, found_epson.maker) == ("escpos", "TM-T88VII", "EPSON")
        assert epson.jobs == []  # the question printed nothing
    finally:
        star.close()
        epson.close()
    gone = asyncio.run(identify(closed_port()))
    assert gone.reachable is False and gone.dialect is None


def closed_port() -> str:
    """An address on this machine with nothing listening: a port that was free a moment ago."""
    with socket.create_server(("127.0.0.1", 0)) as probe:
        return f"127.0.0.1:{probe.getsockname()[1]}"


def test_a_scan_lists_the_addresses_with_the_port_open():
    printer = FakePrinter("epson")
    try:
        assert asyncio.run(scan(["127.0.0.1/32"], port=printer.port)) == ["127.0.0.1"]
        closed = int(closed_port().rsplit(":", 1)[1])
        assert asyncio.run(scan(["127.0.0.1/32", "not a subnet"], port=closed)) == []
    finally:
        printer.close()
