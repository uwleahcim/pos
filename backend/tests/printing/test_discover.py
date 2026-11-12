"""Finding printers on the LAN and telling Epson from Star without printing anything."""

from __future__ import annotations

import asyncio
import socket

import pytest

from pos.printing import discover as lan
from pos.printing.__main__ import main
from pos.printing.discover import (
    SNMP_OIDS,
    discover,
    identify,
    is_escpos_auto_status,
    is_escpos_status,
    is_star_status,
    named,
    scan,
    snmp_answer,
    snmp_get,
    snmp_names,
    subnets_for,
)

from .fake_printer import FakePrinter, FakeSnmp

CANON = {
    SNMP_OIDS["id"]: "MFG:Canon;CMD:LIPSLX,CPCA;MDL:MF644C;CLS:PRINTER;DES:Canon MF644C;",
    SNMP_OIDS["device"]: "Canon MF640C Series",
    SNMP_OIDS["system"]: "Canon MF640C Series /P",
}


@pytest.fixture(autouse=True)
def quick(monkeypatch):
    """The waits a real printer needs, cut down for printers on this machine."""
    monkeypatch.setattr(lan, "LISTEN_FOR", 0.15)
    monkeypatch.setattr(lan, "STATUS_WITHIN", 0.15)
    monkeypatch.setattr(lan, "ANSWER_WITHIN", 0.3)
    monkeypatch.setattr(lan, "SNMP_WITHIN", 0.3)
    monkeypatch.setattr(lan, "TRY_AGAIN_AFTER", 0.01)


def nobody() -> int:
    """A UDP port on this machine where no SNMP agent answers."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def told(printer: FakePrinter, snmp: FakeSnmp | None = None):
    found = asyncio.run(identify(printer.address, snmp_port=snmp.port if snmp else nobody()))
    printer.settle()  # what it was sent is in `heard` before anything is said about it
    return found


def test_the_subnets_come_from_the_addresses_a_terminal_has_loopback_left_out():
    assert subnets_for(["172.19.1.179:8000", "172.19.1.44", "127.0.0.1", "192.168.4.9", "172.19.1.2", "nope"]) == [
        "172.19.1.0/24",
        "192.168.4.0/24",
    ]
    assert subnets_for(["169.254.3.3", "0.0.0.0"]) == []
    assert len(subnets_for([f"10.{n}.0.1" for n in range(20)])) == 6


def test_a_status_is_read_for_whose_it_is_not_just_noticed():
    """Both makes may send a status unasked: the Epson's four bytes are not a Star's block, nor the reverse."""
    epson, star = bytes.fromhex("14 00 00 0f"), bytes.fromhex("23 86 00 00 00 00 00 00 00")
    assert is_escpos_auto_status(epson) and not is_star_status(epson)
    assert is_star_status(star) and not is_escpos_auto_status(star)
    assert is_escpos_auto_status(bytes.fromhex("1c 00 00 0f"))  # drawer open, cover open: still an Epson
    assert is_star_status(bytes.fromhex("23 86 08 00 00 0c 00 00 00"))  # paper out, cover open: still a Star
    assert not is_star_status(bytes.fromhex("23 86 00"))  # a block says how long it is, and this is short of it
    assert not is_star_status(b"") and not is_escpos_auto_status(b"\x00\x00\x00\x00")
    assert is_escpos_status(b"\x16") and is_escpos_status(b"\x12") and is_escpos_status(epson + b"\x1e")
    assert not is_escpos_status(epson) and not is_escpos_status(star) and not is_escpos_status(b"")


def test_an_epson_that_sends_its_status_on_connect_is_still_an_epson():
    """The printer at 10.27.1.14: automatic status left on, so it spoke first, and read as a Star for it."""
    epson = FakePrinter("epson", unasked=True)
    try:
        found = told(epson)
        assert (found.dialect, found.model, found.maker, found.kind) == ("escpos", "TM-T88VII", "EPSON", "receipt")
        assert found.guessed is False and found.heard[0] == "unasked: 14 00 00 0f"
        assert b"\x1b\x06\x01" not in epson.heard[0]  # it had said what it is: no Star question
        assert epson.jobs == []
    finally:
        epson.close()


def test_a_quiet_epson_answers_dle_eot_and_then_says_its_name():
    epson = FakePrinter("epson")
    try:
        found = told(epson)
        assert (found.dialect, found.model, found.maker) == ("escpos", "TM-T88VII", "EPSON")
        assert list(found.heard) == [
            "unasked: nothing",
            "ESC ACK SOH: nothing",
            "DLE EOT 1: 16",
            "GS I: 5f 54 4d 2d 54 38 38 56 49 49 00 5f 45 50 53 4f 4e 00",
        ]
        assert epson.jobs == []  # the questions printed nothing
    finally:
        epson.close()


def test_a_star_is_known_whether_it_speaks_first_or_waits_to_be_asked():
    """The mC-Print3s at 10.27.1.166 and .253 kept quiet on connect and were listed as unknown."""
    eager, quiet = FakePrinter("star"), FakePrinter("star", unasked=False)
    try:
        first = told(eager)
        assert (first.reachable, first.dialect, first.kind, first.guessed) == (True, "star", "receipt", False)
        assert eager.heard == []  # it said so itself: nothing was sent
        asked = told(quiet)
        assert (asked.dialect, asked.kind) == ("star", "receipt")
        assert quiet.heard == [b"\x1b\x06\x01"] and quiet.jobs == []  # no ESC/POS letters in a Star's buffer
    finally:
        eager.close()
        quiet.close()
    gone = asyncio.run(identify(closed_port(), snmp_port=nobody()))
    assert gone.reachable is False and gone.dialect is None and gone.kind is None


def test_a_printer_that_is_no_receipt_printer_is_named_and_sent_nothing_printable():
    canon, agent = FakePrinter("other"), FakeSnmp(CANON)
    try:
        found = told(canon, agent)
        assert (found.reachable, found.dialect, found.kind) == (True, None, "other")
        assert (found.maker, found.model) == ("Canon", "MF644C")
        assert canon.heard == [b"\x1b\x06\x01\x10\x04\x01"]  # two status requests, not one letter: no page
        assert canon.jobs == [] and agent.asked == 3
        unnamed = told(canon)
        assert (unnamed.dialect, unnamed.kind, unnamed.model) == (None, None, None)
    finally:
        canon.close()
        agent.close()


def test_a_receipt_printer_that_keeps_quiet_on_its_port_is_known_by_its_name_as_a_guess():
    silent = FakePrinter("other")
    star = FakeSnmp({SNMP_OIDS["id"]: "MFG:Star;CMD:STAR;MDL:mC-Print3;CLS:PRINTER;"})
    epson = FakeSnmp({SNMP_OIDS["device"]: "EPSON TM-T88VII"})
    try:
        found = told(silent, star)
        assert (found.dialect, found.guessed, found.kind, found.model) == ("star", True, "receipt", "mC-Print3")
        found = told(silent, epson)
        assert (found.dialect, found.guessed, found.kind, found.model) == ("escpos", True, "receipt", "EPSON TM-T88VII")
        assert found.heard[-1] == "SNMP device: EPSON TM-T88VII"
    finally:
        silent.close()
        star.close()
        epson.close()


def test_a_name_is_read_from_the_device_id_then_the_description():
    assert named({"id": "MFG:EPSON;CMD:ESC/POS;MDL:TM-T88VII;CLS:PRINTER;"}) == ("EPSON", "TM-T88VII", "escpos")
    assert named({"id": "MANUFACTURER:Star Micronics;COMMAND SET:StarPRNT;MODEL:Star Micronics mPOP;"}) == (
        "Star Micronics",
        "mPOP",
        "star",
    )
    assert named({"device": "Brother  HL-L2350DW series", "system": "ignored"}) == (
        None,
        "Brother HL-L2350DW series",
        None,
    )
    assert named({"system": "HP ETHERNET MULTI-ENVIRONMENT\nROM none"}) == (None, "HP ETHERNET MULTI-ENVIRONMENT", None)
    assert named({"device": "BIXOLON SRP-350III"})[2] == "escpos" and named({"device": "TSP143IIILAN"})[2] == "star"
    assert named({"device": "EPSON ET-2850 Series"})[2] is None  # an Epson inkjet is not a receipt printer
    assert named({}) == (None, None, None)


def test_the_snmp_question_is_the_standard_one_and_the_answer_is_read_from_real_bytes():
    assert snmp_get("1.3.6.1.2.1.1.1.0", 1) == bytes.fromhex(
        "30 26 02 01 00 04 06 70 75 62 6c 69 63 a0 19 02 01 01 02 01 00 02 01 00"
        "30 0e 30 0c 06 08 2b 06 01 02 01 01 01 00 05 00"
    )
    # 2699 (the printer working group's branch) takes two bytes, 95 0b
    assert snmp_get(SNMP_OIDS["id"], 2).endswith(
        bytes.fromhex("30 15 30 13 06 0f 2b 06 01 04 01 95 0b 01 02 01 02 01 01 03 01 05 00")
    )
    answer = bytes.fromhex(
        "30 32 02 01 00 04 06 70 75 62 6c 69 63 a2 25 02 01 07 02 01 00 02 01 00"
        "30 1a 30 18 06 08 2b 06 01 02 01 01 01 00 04 0c 43 61 6e 6f 6e 20 4d 46 36 34 34 43"
    )
    assert snmp_answer(answer) == (7, b"Canon MF644C")
    long = b"x" * 200  # a length over 127 takes the long form
    packet = bytes.fromhex("30 81 eb 02 01 00 04 06 70 75 62 6c 69 63 a2 81 dd 02 01 02 02 01 00 02 01 00")
    packet += bytes.fromhex("30 81 d1 30 81 ce 06 01 2b 04 81 c8") + long
    assert snmp_answer(packet) == (2, long)
    missing = bytes.fromhex(
        "30 26 02 01 00 04 06 70 75 62 6c 69 63 a2 19 02 01 03 02 01 02 02 01 01"
        "30 0e 30 0c 06 08 2b 06 01 02 01 01 01 00 05 00"
    )
    assert snmp_answer(missing) == (3, None)
    assert snmp_answer(answer[:20]) is None and snmp_answer(b"") is None and snmp_answer(b"\x30\x03abc") is None
    assert snmp_answer(snmp_get("1.3.6.1.2.1.1.1.0", 1)) is None  # a question is not an answer


def test_snmp_gives_what_the_device_has_and_nothing_where_nobody_listens():
    agent = FakeSnmp({SNMP_OIDS["device"]: "Canon MF640C Series"})
    try:
        assert asyncio.run(snmp_names("127.0.0.1", port=agent.port)) == {"device": "Canon MF640C Series"}
    finally:
        agent.close()
    assert asyncio.run(snmp_names("127.0.0.1", port=nobody())) == {}


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


def test_a_printer_found_silent_is_asked_once_more():
    """A printer that takes one connection at a time may still be closing the scan's when it is asked."""
    canon = FakePrinter("other")
    try:
        found = asyncio.run(discover(["127.0.0.1/32"], port=canon.port, snmp_port=nobody()))
        assert [(f.address, f.reachable, f.kind) for f in found] == [(canon.address, True, None)]
        canon.settle()
        assert len(canon.heard) == 2
    finally:
        canon.close()


def test_the_command_line_says_what_a_printer_is_and_what_it_answered(capsys):
    epson = FakePrinter("epson", unasked=True)
    try:
        assert main(["--printer", epson.address, "identify"]) == 0
        epson.settle()
        out = capsys.readouterr().out.splitlines()
        assert out[0] == f"{epson.address}: EPSON TM-T88VII: ESC/POS"
        assert out[1] == "  unasked: 14 00 00 0f" and out[2].startswith("  GS I: 5f 54 4d")
        assert epson.jobs == []
    finally:
        epson.close()
    assert main(["--printer", closed_port(), "identify"]) == 1
    assert "nothing answers" in capsys.readouterr().out
