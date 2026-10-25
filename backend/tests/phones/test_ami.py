from __future__ import annotations

import asyncio
import io
import json

import pytest

from pos.phones import ami
from pos.phones.ami import AMIClient, AMIError, call_from_event, location_for, originate, probe, set_paused, tail
from tests.phones.fake_ami import FakePBX


def test_login_uses_the_md5_challenge_and_never_sends_the_secret():
    async def go():
        async with FakePBX() as pbx, AMIClient("127.0.0.1", pbx.port) as client:
            assert client.banner.startswith("Asterisk Call Manager")
            response = await client.login("pos", "s3cret")
            assert response["Message"] == "Authentication accepted"
            login = next(p for p in pbx.received if p.get("Action") == "Login")
            assert "Secret" not in login and len(login["Key"]) == 32

    asyncio.run(go())


def test_a_wrong_secret_is_refused():
    async def go():
        async with FakePBX() as pbx, AMIClient("127.0.0.1", pbx.port) as client:
            with pytest.raises(AMIError, match="Authentication failed"):
                await client.login("pos", "nope")

    asyncio.run(go())


def test_probe_lists_version_queues_and_endpoints():
    async def go():
        async with FakePBX() as pbx, AMIClient("127.0.0.1", pbx.port) as client:
            await client.login("pos", "s3cret")
            return await probe(client)

    result = asyncio.run(go())
    assert result["asterisk"] == "20.5.0" and result["system"] == "freepbx-test"
    assert [q["queue"] for q in result["queues"]] == ["6001", "6002"]
    assert result["queues"][1]["callers"] == "1"
    assert [e["name"] for e in result["endpoints"]] == ["201", "202"]
    assert result["channels"] == 0


def test_tail_reports_incoming_calls_with_the_location_from_the_dialed_number():
    out = io.StringIO()

    async def go():
        async with FakePBX() as pbx, AMIClient("127.0.0.1", pbx.port) as client:
            await client.login("pos", "s3cret", events="call")
            await pbx.emit(
                Event="Newchannel",
                Channel="PJSIP/trunk-0001",
                Context="from-trunk",
                Exten="15551230001",
                CallerIDNum="2125550123",
                CallerIDName="JANE",
                Uniqueid="1700000000.1",
            )
            await pbx.emit(  # an internal call: not ours
                Event="Newchannel", Channel="PJSIP/201-0002", Context="from-internal", Exten="6001", CallerIDNum="201"
            )
            await pbx.emit(
                Event="QueueCallerJoin",
                Channel="PJSIP/trunk-0001",
                Queue="6001",
                CallerIDNum="2125550123",
                Position="1",
                Uniqueid="1700000000.1",
            )
            return await tail(client, {"555-123-0001": "Downtown"}, count=2, seconds=5, out=out)

    assert asyncio.run(go()) == 2
    first, second = (json.loads(line) for line in out.getvalue().splitlines())
    assert (first["location"], first["caller"], first["dialed"]) == ("Downtown", "2125550123", "15551230001")
    assert (second["event"], second["queue"], second["uniqueid"]) == ("QueueCallerJoin", "6001", "1700000000.1")


def test_pause_and_originate_send_what_asterisk_expects():
    async def go():
        async with FakePBX() as pbx, AMIClient("127.0.0.1", pbx.port) as client:
            await client.login("pos", "s3cret")
            await set_paused(client, "Local/201@from-queue/n", True, queue="6001")
            await originate(client, "PJSIP/201", "12125550123", callerid="POS <201>")
            return pbx.received

    received = asyncio.run(go())
    pause = next(p for p in received if p.get("Action") == "QueuePause")
    assert (pause["Interface"], pause["Paused"], pause["Queue"]) == ("Local/201@from-queue/n", "true", "6001")
    orig = next(p for p in received if p.get("Action") == "Originate")
    assert (orig["Channel"], orig["Exten"], orig["Context"], orig["Async"]) == (
        "PJSIP/201",
        "12125550123",
        "from-internal",
        "true",
    )
    assert received[-1]["Action"] == "Logoff"


def test_location_matching_ignores_formatting_and_the_country_code():
    locations = {"(555) 123-0001": "Downtown", "15551230002": "Airport"}
    assert location_for("15551230001", locations) == "Downtown"
    assert location_for("5551230002", locations) == "Airport"
    assert location_for("5551239999", locations) is None
    assert location_for("", locations) is None
    assert call_from_event({"Event": "Hangup", "Channel": "x"}) is None


def test_cli_probe_prints_json(monkeypatch, capsys):
    monkeypatch.setenv("AMI_SECRET", "s3cret")

    async def go():
        async with FakePBX() as pbx:
            argv = ["--host", "127.0.0.1", "--port", str(pbx.port), "--user", "pos", "probe"]
            return await ami.run(ami.build_parser().parse_args(argv))

    assert asyncio.run(go()) == 0
    assert json.loads(capsys.readouterr().out)["asterisk"] == "20.5.0"


def test_cli_refuses_to_run_without_the_secret(monkeypatch, capsys):
    monkeypatch.delenv("AMI_SECRET", raising=False)
    assert ami.main(["--host", "127.0.0.1", "--user", "pos", "probe"]) == 2
    assert "AMI_SECRET" in capsys.readouterr().err
