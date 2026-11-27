"""Call recordings on phone orders (docs/call-recordings.md): the PBX records, the hub reads what it has through
one small program there, an order lists the recorded calls with its phone number, and whoever may listen
plays one. The program is the real one (infra/hub/pbx/pos-recordings), run here as sshd runs it on the PBX."""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.identity.staff import Directory, Staff
from pos.menu.service import MenuService, load_definitions
from pos.phones.deskphones import AmiWatcher, AnsweredCalls
from pos.phones.recordings import (
    BACKFILL_DAYS,
    MOST_CALLS,
    CommandPbx,
    Listed,
    Pbx,
    PbxError,
    PgRecordingStore,
    Recording,
    Recordings,
    RecordingStore,
    SshPbx,
    estimate_seconds,
    mp3_info,
    pbx_from_env,
    read_name,
    started_ms_of,
)
from pos.printing.service import PrintService
from pos.settings import SettingStore
from pos.sync.hlc import HLC
from pos.sync.oplog import OpStore
from pos.tax import massachusetts
from tests.phones.fake_ami import FakePBX

DSN = os.environ.get("POS_TEST_DATABASE_URL")
HUB = Path(__file__).resolve().parents[3] / "infra" / "hub" / "pbx"
PROGRAM = HUB / "pos-recordings"
TOOLS = shutil.which("sox") is not None and shutil.which("lame") is not None
needs_tools = pytest.mark.skipif(not TOOLS, reason="sox and lame make and read the recordings of these tests")

LINDA = "7815551234"
DID = "7817293888"


def at(hour: int, minute: int = 0, *, day: int = 26, second: int = 0) -> int:
    """That time of that day of November 2026 on the restaurant's own clock, as wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, second, tzinfo=localtime.zone()).timestamp() * 1000)


def call_id(began_ms: int, serial: int = 101) -> str:
    """A call's id as Asterisk makes it: the second it began, and a serial number."""
    return f"{began_ms // 1000}.{serial}"


def own_name(began_ms: int, *, caller: str = LINDA, serial: int = 101, ext: str = "WAV") -> str:
    """FreePBX's own recording of a call in, where it puts it: a folder a day, the name says who and when."""
    when = datetime.fromtimestamp(began_ms / 1000, localtime.zone())
    return f"{when:%Y/%m/%d}/generic-{DID}-{caller}-{when:%Y%m%d-%H%M%S}-{call_id(began_ms, serial)}.{ext}"


def out_name(began_ms: int, *, dialed: str = LINDA, serial: int = 202) -> str:
    when = datetime.fromtimestamp(began_ms / 1000, localtime.zone())
    return f"{when:%Y/%m/%d}/out-{dialed}-200-{when:%Y%m%d-%H%M%S}-{call_id(began_ms, serial)}.WAV"


def stereo_name(began_ms: int, serial: int = 101) -> str:
    when = datetime.fromtimestamp(began_ms / 1000, localtime.zone())
    return f"{when:%Y/%m/%d}/pos-{call_id(began_ms, serial)}.mp3"


def mp3(seconds: float, *, stereo: bool = True) -> bytes:
    """An MP3 of that length as `lame` writes one at 16 kHz and 64 kbit/s, made by hand: every frame has its
    header and no sound."""
    frame = bytes([0xFF, 0xF3, 0x88, 0x00 if stereo else 0xC0]) + bytes(284)  # 576 samples in 288 bytes
    return frame * round(seconds * 16000 / 576)


class FakePbx(Pbx):
    """A PBX's recordings folder in memory, answering as the program does."""

    def __init__(self) -> None:
        self.files: dict[str, tuple[float, bytes | int]] = {}  # path: when it changed, and what is in it (or its size)
        self.down = False
        self.asked: list[str] = []

    def put(self, path: str, content: bytes | int, *, mtime: float) -> None:
        self.files[path] = (mtime, content)

    def ask(self, request: str, *, timeout: float) -> bytes:
        self.asked.append(request)
        if self.down:
            raise PbxError("unreachable", "ssh: connect to host pbx port 22: No route to host")
        word, _, rest = request.partition(" ")
        if word == "about":
            return (
                b"pos-recordings 1\nfolder /var/spool/asterisk/monitor\nsox yes\nlame yes\nffmpeg no\n"
                b"stereo-script yes\nstereo-dialplan no\n"
            )
        if word == "list":
            lines = [
                f"{mtime:.10f} {content if isinstance(content, int) else len(content)} {path}"
                for path, (mtime, content) in self.files.items()
                if mtime > int(rest)
            ]
            return ("\n".join(lines) + "\n").encode()
        if word == "get":
            if rest not in self.files:
                raise PbxError("gone", "pos-recordings: no such recording")
            content = self.files[rest][1]
            return mp3(3, stereo=False) if isinstance(content, int) else content
        raise PbxError("refused", "pos-recordings: refused")

    def gets(self) -> int:
        return sum(1 for request in self.asked if request.startswith("get "))


STAFF = (
    ("s1", "Amy", "server", "1111"),
    ("s3", "Mike", "manager", "9999"),
    ("s4", "Holly", "host", "3333"),
    ("s6", "Ken", "kitchen", "6666"),
)


class Hub:
    """A hub whose clock the test sets, linked to a PBX's recordings, and the screens' calls to it."""

    def __init__(self, tmp_path: Path, pbx: Pbx | None = None, *, now: int = at(18, 40)) -> None:
        self.now = now
        self.pbx = pbx if pbx is not None else FakePbx()
        self.store = RecordingStore()
        self.recordings = Recordings(self.store, self.pbx, cache=tmp_path / "kept", clock=lambda: self.now / 1000)
        self.ops = OpStore(physical=lambda: self.now)
        self.c = TestClient(
            create_app(
                self.ops,
                staff=Directory([Staff.with_pin(*person) for person in STAFF]),
                menu=MenuService(load_definitions("restaurant")),
                taxes=massachusetts(),
                printing=PrintService([]),
                settings=SettingStore(),
                recordings=self.recordings,
            )
        )

    def order(self, order_id: str, opened: int, **fields) -> None:
        """A phone order opened at that moment."""
        fields = {"order_type": "takeout", "channel": "phone", "customer_name": "Linda", "phone": LINDA, **fields}
        op = {
            "op_id": f"{order_id}-a",
            "order_id": order_id,
            "hlc": str(HLC(opened, 0, "t1")),
            "device": "t1",
            "kind": "create",
            "data": fields,
        }
        answer = self.c.post(f"/orders/{order_id}/ops", json=[op])
        assert answer.status_code == 202 and answer.json()["refused"] == [], answer.text

    def calls(self, order_id: str = "o1") -> dict:
        answer = self.c.get(f"/orders/{order_id}/calls")
        assert answer.status_code == 200, answer.text
        return answer.json()

    def bearer(self, pin: str = "9999", power: str | None = "calls") -> dict[str, str]:
        body = {"device": "t1", "pin": pin} | ({"power": power} if power else {})
        answer = self.c.post("/admin/session", json=body)
        assert answer.status_code == 200, answer.text
        return {"authorization": f"Bearer {answer.json()['token']}"}

    def listen(self, call: str, order_id: str = "o1", *, pin: str = "9999"):
        return self.c.get(f"/orders/{order_id}/calls/{call}/audio", headers=self.bearer(pin))


def refused(answer) -> tuple[int, str]:
    return answer.status_code, answer.json()["detail"]["error"]


# What a recording's name says -------------------------------------------------------------------------------


def test_a_call_in_is_read_off_the_name_freepbx_gives_its_recording():
    began = at(18, 30)
    path = own_name(began)
    assert path == f"2026/11/26/generic-7817293888-7815551234-20261126-183000-{began // 1000}.101.WAV"
    assert read_name(path) == {
        "call_id": call_id(began),
        "number": LINDA,
        "direction": "in",
        "extension": "",
        "dialed": DID,
        "path": path,
    }
    assert started_ms_of(call_id(began)) == began
    # a ring group's and an extension's own recordings are named alike, the caller in the same place
    assert read_name("2026/11/26/rg-600-+17815551234-20261126-183000-1795735800.7.wav")["number"] == LINDA
    assert read_name("2026/11/26/exten-200-7815551234-20261126-183000-1795735800.8.wav")["direction"] == "in"


def test_a_call_out_names_the_number_that_was_dialed_and_the_extension_that_dialed():
    said = read_name("2026/11/26/out-17815551234-200-20261126-190500-1795737900.202.WAV")
    assert (said["number"], said["direction"], said["extension"]) == (LINDA, "out", "200")


def test_the_stereo_file_is_known_by_the_calls_id_alone():
    assert read_name("2026/11/26/pos-1795735800.101.mp3") == {
        "call_id": "1795735800.101",
        "stereo_path": "2026/11/26/pos-1795735800.101.mp3",
    }


@pytest.mark.parametrize(
    "path",
    [
        "2026/11/26/exten-201-200-20261126-183000-1795735800.9.WAV",  # two extensions: no customer on it
        "2026/11/26/out-*97-200-20261126-183000-1795735800.10.WAV",  # a feature code, and no path to ask for
        "2026/11/26/pos-1795735800.101-in.wav",  # a side the stereo step has not put together yet
        "2026/11/26/pos-1795735800.101-out.wav",
        "2026/11/26/pos-1795735800.101.mp3.part",
        "2026/11/26/generic-7817293888-unknown-20261126-183000-1795735800.11.WAV",  # a caller with no number
        "2026/11/26/notes.txt",
        "../etc/generic-7817293888-7815551234-20261126-183000-1795735800.12.WAV",
        "2026/11/26/generic-7817293888-7815551234-20261126-183000-1795735800.12 copy.WAV",
    ],
)
def test_what_is_not_a_call_with_a_customer_is_left_alone(path):
    assert read_name(path) is None


def test_a_recordings_length_is_worked_out_from_its_size_until_it_is_measured():
    assert estimate_seconds("a.WAV", 60 + 1625 * 90) == 90  # FreePBX's own: GSM, about 100 KB a minute
    assert estimate_seconds("pos-1.2.mp3", 8000 * 90) == 90  # the stereo file: 64 kbit/s
    assert estimate_seconds("a.wav", 44 + 16000 * 90) == 90  # plain 8 kHz, 16 bits
    assert estimate_seconds("a.ogg", 5000) is None
    assert estimate_seconds("a.WAV", 0) == 0
    row = Recording("1.2", 1000, LINDA, path="a.WAV", size=60 + 1625 * 90)
    assert row.length == 90 and not row.stereo
    measured = Recording("1.2", 1000, LINDA, path="a.WAV", size=60 + 1625 * 90, seconds=92, measured=60 + 1625 * 90)
    assert measured.length == 92
    # it grew since it was measured (the call was still on): the measure is of an older file
    grown = Recording("1.2", 1000, LINDA, path="a.WAV", size=60 + 1625 * 120, seconds=92, measured=60 + 1625 * 90)
    assert grown.length == 120
    # the stereo file is the one played, and the one measured
    both = Recording("1.2", 1000, LINDA, path="a.WAV", size=60 + 1625 * 90, stereo_path="pos-1.2.mp3", stereo_size=8000)
    assert both.stereo and both.best == ("pos-1.2.mp3", 8000) and both.length == 1


def test_an_mp3_is_measured_frame_by_frame():
    seconds, channels = mp3_info(mp3(12))
    assert round(seconds) == 12 and channels == 2
    assert mp3_info(mp3(3, stereo=False))[1] == 1
    tagged = b"ID3\x04\x00\x00\x00\x00\x00\x0a" + bytes(10) + mp3(5)  # a tag before the sound is stepped over
    assert round(mp3_info(tagged)[0]) == 5
    assert mp3_info(b"RIFF....WAVEfmt " + bytes(4000)) is None
    assert mp3_info(b"") is None


@needs_tools
def test_an_mp3_lame_made_is_measured_right(tmp_path):
    wav, out = tmp_path / "a.wav", tmp_path / "a.mp3"
    subprocess.run(["sox", "-n", "-r", "16000", "-c", "2", str(wav), "synth", "4", "sine", "440"], check=True)
    subprocess.run(["lame", "--quiet", "-m", "s", "-b", "64", str(wav), str(out)], check=True)
    seconds, channels = mp3_info(out.read_bytes())
    assert 3.9 < seconds < 4.2 and channels == 2


# A look at the PBX ------------------------------------------------------------------------------------------


def test_a_look_writes_down_the_calls_the_pbx_has_and_the_next_one_only_asks_for_what_changed(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95.4)
    h.pbx.put("2026/11/26/exten-201-200-20261126-183000-1795735800.9.WAV", 5000, mtime=began / 1000 + 20)
    assert h.recordings.sweep() == 1
    # the first look goes three months back
    assert h.pbx.asked == [f"list {h.now // 1000 - BACKFILL_DAYS * 86400 - 1}"]
    row = h.store.get(call_id(began))
    assert (row.number, row.direction, row.started_ms, row.length) == (LINDA, "in", began, 95)
    assert h.store.count() == 1
    # nothing changed: the next look asks from where the last one came to, and writes nothing
    assert h.recordings.sweep() == 0
    assert h.pbx.asked[-1] == f"list {began // 1000 + 95 - 1}"
    # a call out to her, later
    again = at(19, 5)
    h.pbx.put(out_name(again), 60 + 1625 * 30, mtime=again / 1000 + 30)
    assert h.recordings.sweep() == 1
    assert h.store.get(call_id(again, 202)).direction == "out"
    assert h.store.count() == 2


def test_the_stereo_file_joins_its_call_whenever_it_turns_up(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.recordings.sweep()
    assert not h.store.get(call_id(began)).stereo
    # the PBX put the two sides together a few seconds after the call
    h.pbx.put(stereo_name(began), 8000 * 95, mtime=began / 1000 + 99)
    assert h.recordings.sweep() == 1
    row = h.store.get(call_id(began))
    assert row.stereo and row.best == (stereo_name(began), 8000 * 95) and row.number == LINDA
    # both in one look, the stereo file listed first: the same line
    other = at(18, 50)
    h.pbx.put(stereo_name(other, 303), 8000 * 20, mtime=other / 1000 + 22)
    h.pbx.put(own_name(other, serial=303), 60 + 1625 * 20, mtime=other / 1000 + 20)
    h.recordings.sweep()
    row = h.store.get(call_id(other, 303))
    assert row.stereo and row.number == LINDA and row.path == own_name(other, serial=303)


def test_the_screens_are_told_when_a_look_found_something(tmp_path):
    h = Hub(tmp_path)
    told: list[str] = []
    h.c.app.state.feed.changed = told.append
    h.recordings.sweep()
    assert told == []  # nothing there: nothing to tell
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.recordings.sweep()
    h.recordings.sweep()
    assert told == ["calls"]  # once, for the look that found it


def test_a_recording_that_grew_is_written_down_again(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 10, mtime=began / 1000 + 10)  # the call is still on
    h.recordings.sweep()
    assert h.store.get(call_id(began)).length == 10
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    assert h.recordings.sweep() == 1
    assert h.store.get(call_id(began)).length == 95


def test_a_pbx_that_is_away_fails_the_look_and_leaves_what_was_found(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.recordings.sweep()
    h.pbx.down = True
    with pytest.raises(PbxError) as err:
        h.recordings.sweep()
    assert err.value.code == "unreachable"
    assert h.store.count() == 1
    status = h.recordings.status()
    assert status["problem"]["code"] == "unreachable" and status["calls"] == 1
    h.pbx.down = False
    h.recordings.sweep()
    assert h.recordings.status()["problem"] is None


def test_a_hub_with_no_pbx_knows_nothing_and_says_so(tmp_path):
    recordings = Recordings(cache=tmp_path)
    assert not recordings.configured and recordings.sweep() == 0
    recordings.refresh()
    recordings.start()
    recordings.call_ended("1.2")
    assert recordings.status() == {"configured": False}
    assert recordings.for_order(LINDA, at(18, 31)) == []
    assert pbx_from_env({}) is None and pbx_from_env({"POS_PBX_RECORDINGS": " "}) is None


def test_the_pbx_is_named_by_the_hubs_file_and_asked_with_the_recordings_key_only():
    pbx = pbx_from_env({"POS_PBX_RECORDINGS": "root@freepbx.example.org"})
    argv, env = pbx.command("list 0")
    assert env is None and argv[0] == "ssh" and argv[-3:] == ["--", "root@freepbx.example.org", "list 0"]
    assert argv[argv.index("-i") + 1] == "/pbx-recordings/id_ed25519"
    for option in ("BatchMode=yes", "IdentitiesOnly=yes", "StrictHostKeyChecking=yes"):
        assert option in argv
    assert "UserKnownHostsFile=/pbx-recordings/known_hosts" in argv
    # a name that could be taken for an option of ssh is no name
    assert pbx_from_env({"POS_PBX_RECORDINGS": "-oProxyCommand=sh"}) is None
    with pytest.raises(ValueError):
        SshPbx("root@pbx; rm -rf /", key="k", known_hosts="h")


def test_a_path_that_is_no_recordings_is_never_asked_for():
    pbx = FakePbx()
    for path in ("/etc/passwd", "../x.WAV", "-rf", "a b.WAV", "a;b.WAV", ""):
        with pytest.raises(PbxError):
            pbx.get(path)
    assert pbx.asked == []


def test_the_hub_looks_on_its_own_and_soon_after_a_call_ends(tmp_path, monkeypatch):
    monkeypatch.setattr("pos.phones.recordings.AFTER_A_CALL", (0.05, 0.15))
    pbx = FakePbx()
    recordings = Recordings(RecordingStore(), pbx, cache=tmp_path)
    recordings.call_ended("1.2")  # before it runs, nothing is asked
    assert pbx.asked == []
    recordings.start(interval=3600)
    recordings.start(interval=3600)  # once
    deadline = time.time() + 5
    while len(pbx.asked) < 1 and time.time() < deadline:
        time.sleep(0.01)
    assert len(pbx.asked) == 1  # the look at the start
    recordings.call_ended("1.2")
    while len(pbx.asked) < 3 and time.time() < deadline:
        time.sleep(0.01)
    assert len(pbx.asked) == 3  # one for the recording, one for the stereo file
    assert sum(1 for t in threading.enumerate() if t.name == "call-recordings") >= 1


def test_the_watcher_says_when_a_call_is_over():
    import asyncio

    ended: list[str] = []

    async def go():
        async with FakePBX() as pbx:
            watcher = AmiWatcher("127.0.0.1", pbx.port, "pos", "s3cret", AnsweredCalls(lambda: {}), backoff=(0.05, 0.1))
            watcher.on_call_end = ended.append
            watcher.start()
            try:
                for _ in range(200):
                    if watcher.status()["connected"]:
                        break
                    await asyncio.sleep(0.02)
                # a desk phone's own channel hangs up first: the call is not over
                await pbx.emit(
                    Event="Hangup", Channel="PJSIP/200-00000002", Uniqueid="1795735801.102", Linkedid="1795735800.101"
                )
                await pbx.emit(
                    Event="Hangup", Channel="PJSIP/trunk-00000001", Uniqueid="1795735800.101", Linkedid="1795735800.101"
                )
                for _ in range(200):
                    if ended:
                        break
                    await asyncio.sleep(0.02)
            finally:
                await watcher.stop()

    asyncio.run(go())
    assert ended == ["1795735800.101"]


def test_a_listener_that_fails_never_stops_the_watching():
    watcher = AmiWatcher("127.0.0.1", 1, "pos", "x", AnsweredCalls(lambda: {}))

    def broken(call: str) -> None:
        raise RuntimeError("no")

    watcher.on_call_end = broken
    watcher._ended({"Event": "Hangup", "Uniqueid": "1.2", "Linkedid": "1.2"})  # nothing raised


# An order's calls -------------------------------------------------------------------------------------------


def test_an_order_lists_the_recorded_calls_with_its_number_of_its_day(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.pbx.put(stereo_name(began), 8000 * 95, mtime=began / 1000 + 99)
    back = at(19, 5)
    h.pbx.put(out_name(back), 60 + 1625 * 30, mtime=back / 1000 + 30)  # the restaurant called her back
    h.pbx.put(own_name(at(18, 35), caller="6175550000", serial=7), 9000, mtime=at(18, 36) / 1000)  # somebody else
    h.pbx.put(own_name(at(12, 0, day=25), serial=8), 9000, mtime=at(12, 2, day=25) / 1000)  # her, yesterday
    h.pbx.put(own_name(at(2, 0), serial=9), 9000, mtime=at(2, 1) / 1000)  # her, before today's service began
    h.now = at(19, 10)
    h.order("o1", at(18, 30, second=40))
    answer = h.calls()
    assert (answer["linked"], answer["problem"], answer["phone"]) == (True, None, LINDA)
    assert answer["calls"] == [
        {
            "id": call_id(began),
            "direction": "in",
            "started_ms": began,
            "seconds": 95,
            "stereo": True,
            "extension": "",
            "opened": True,  # the order was opened during this one
        },
        {
            "id": call_id(back, 202),
            "direction": "out",
            "started_ms": back,
            "seconds": 30,
            "stereo": False,
            "extension": "200",
            "opened": False,
        },
    ]
    assert h.pbx.gets() == 0  # reading the list moves no audio


def test_an_order_for_a_later_day_lists_the_calls_up_to_that_day(tmp_path):
    h = Hub(tmp_path)
    for serial, began in enumerate([at(11, 0, day=24), at(15, 0, day=25), at(10, 0, day=26), at(9, 0, day=27)]):
        h.pbx.put(own_name(began, serial=serial + 1), 60 + 1625 * 60, mtime=began / 1000 + 60)
    h.now = at(11, 5, day=24)
    h.order("o1", at(11, 1, day=24), promised_at=at(12, 0, day=26))  # catering for Thursday, rung on Tuesday
    h.now = at(12, 0, day=27)
    assert [c["started_ms"] for c in h.calls()["calls"]] == [at(11, 0, day=24), at(15, 0, day=25), at(10, 0, day=26)]


def test_an_order_without_a_number_or_without_calls_lists_none(tmp_path):
    h = Hub(tmp_path)
    h.order("o1", at(18, 30), phone="")
    h.order("o2", at(18, 31))
    assert h.calls("o1")["calls"] == [] and h.calls("o1")["phone"] == ""
    assert h.pbx.asked == []  # no number: the PBX is not even asked
    assert h.calls("o2")["calls"] == []
    assert h.c.get("/orders/nope/calls").status_code == 404


def test_the_call_that_just_ended_is_on_the_list_and_the_pbx_is_not_asked_on_every_look(tmp_path):
    h = Hub(tmp_path)
    h.order("o1", at(18, 31))
    assert h.calls()["calls"] == []
    looks = len(h.pbx.asked)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.now += 5_000
    assert h.calls()["calls"] == [] and len(h.pbx.asked) == looks  # looked five seconds ago
    h.now += 20_000
    assert len(h.calls()["calls"]) == 1 and len(h.pbx.asked) == looks + 1


def test_a_pbx_that_is_away_leaves_the_list_as_it_was_and_says_so(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 60 + 1625 * 95, mtime=began / 1000 + 95)
    h.order("o1", at(18, 31))
    assert len(h.calls()["calls"]) == 1
    h.pbx.down = True
    h.now += 60_000
    answer = h.calls()
    assert answer["problem"] == "unreachable" and len(answer["calls"]) == 1
    looks = len(h.pbx.asked)
    h.now += 30_000
    h.calls()
    assert len(h.pbx.asked) == looks  # nobody waits for it again within the minute
    h.now += 40_000
    h.pbx.down = False
    assert h.calls()["problem"] is None


def test_an_order_lists_no_more_than_its_share(tmp_path):
    h = Hub(tmp_path)
    for n in range(MOST_CALLS + 5):
        began = at(12, 0) + n * 60_000
        h.pbx.put(own_name(began, serial=n), 60 + 1625 * 20, mtime=began / 1000 + 20)
    h.order("o1", at(12, 0))
    assert len(h.calls()["calls"]) == MOST_CALLS


def test_a_hub_that_is_not_linked_says_so(tmp_path):
    ops = OpStore(physical=lambda: at(18, 40))
    c = TestClient(
        create_app(
            ops,
            menu=MenuService(load_definitions("restaurant")),
            taxes=massachusetts(),
            printing=PrintService([]),
            recordings=Recordings(cache=tmp_path),
        )
    )
    op = {"op_id": "a", "order_id": "o1", "hlc": str(HLC(at(18, 30), 0, "t1")), "device": "t1", "kind": "create"}
    c.post("/orders/o1/ops", json=[{**op, "data": {"order_type": "takeout", "phone": LINDA}}])
    assert c.get("/orders/o1/calls").json() == {
        "order_id": "o1",
        "phone": LINDA,
        "linked": False,
        "problem": None,
        "calls": [],
    }
    assert c.get("/phones/recordings").json() == {"configured": False}


# Listening --------------------------------------------------------------------------------------------------


def test_whoever_may_listen_plays_a_call_and_the_second_listen_asks_the_pbx_nothing(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(95, stereo=False), mtime=began / 1000 + 95)
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]["id"]
    answer = h.listen(call)
    assert answer.status_code == 200 and answer.headers["content-type"] == "audio/mpeg"
    assert answer.content == mp3(95, stereo=False)
    assert h.pbx.gets() == 1
    assert h.listen(call).content == answer.content and h.pbx.gets() == 1  # from the hub's own shelf
    # the length is the measured one now
    row = h.store.get(call)
    assert (row.seconds, row.measured) == (95, row.size)
    # the hub plays what it kept while the PBX is away
    h.pbx.down = True
    assert h.listen(call).status_code == 200


def test_the_stereo_file_is_the_one_played(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(95, stereo=False), mtime=began / 1000 + 95)
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]["id"]
    assert mp3_info(h.listen(call).content)[1] == 1
    # the stereo file turns up: it is fetched, not the one kept from before
    h.pbx.put(stereo_name(began), mp3(95), mtime=began / 1000 + 99)
    h.now += 30_000
    assert h.calls()["calls"][0]["stereo"] is True
    assert mp3_info(h.listen(call).content)[1] == 2 and h.pbx.gets() == 2


def test_listening_takes_the_pin_of_somebody_who_may(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(20), mtime=began / 1000 + 20)
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]["id"]
    assert h.c.get(f"/orders/o1/calls/{call}/audio").status_code == 401
    # to start, a manager's or an owner's: nobody else gets as far as a session for it
    for pin in ("1111", "3333", "6666"):
        assert h.c.post("/admin/session", json={"device": "t1", "pin": pin, "power": "calls"}).status_code == 403
    # a session for something else opens no recording
    manager = h.bearer("9999", None)
    assert h.c.put("/settings/powers", json={"roles": {"notes": ["host"]}}, headers=manager).status_code == 200
    assert refused(h.c.get(f"/orders/o1/calls/{call}/audio", headers=h.bearer("3333", "notes"))) == (403, "not_allowed")
    assert h.pbx.gets() == 0
    # a manager hands it to the servers: Amy's own PIN plays it
    assert h.c.put("/settings/powers", json={"roles": {"calls": ["server"]}}, headers=manager).status_code == 200
    assert h.listen(call, pin="1111").status_code == 200
    assert h.c.post("/admin/session", json={"device": "t1", "pin": "6666", "power": "calls"}).status_code == 403


def test_a_call_is_only_played_through_an_order_it_is_on(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(20), mtime=began / 1000 + 20)
    other = at(18, 35)
    h.pbx.put(own_name(other, caller="6175550000", serial=7), mp3(20), mtime=other / 1000 + 20)
    h.order("o1", at(18, 31))
    h.order("o2", at(18, 36), phone="6175550000")
    h.calls()
    assert refused(h.listen(call_id(other, 7))) == (404, "unknown_call")
    assert refused(h.listen("1.2")) == (404, "unknown_call")
    assert h.listen("..%2F..%2Fetc").status_code == 404
    assert h.listen(call_id(other, 7), "o2").status_code == 200
    assert h.listen(call_id(began), "nope").status_code == 404
    assert h.pbx.gets() == 1


def test_a_recording_the_pbx_no_longer_has_is_gone_and_off_the_list(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(20), mtime=began / 1000 + 20)
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]["id"]
    del h.pbx.files[own_name(began)]  # the PBX cleared its old recordings
    assert refused(h.listen(call)) == (404, "gone")
    assert h.calls()["calls"] == []


def test_a_pbx_that_is_away_when_somebody_presses_play_is_said_so(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), mp3(20), mtime=began / 1000 + 20)
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]["id"]
    h.pbx.down = True
    assert refused(h.listen(call)) == (424, "pbx_unreachable")
    assert len(h.calls()["calls"]) == 1  # still on the list: it plays when the PBX is back
    h.pbx.down = False
    assert h.listen(call).status_code == 200


def test_what_nobody_listened_to_for_a_month_goes_off_the_hubs_shelf(tmp_path):
    h = Hub(tmp_path)
    kept = tmp_path / "kept"
    for serial, began in enumerate([at(18, 30), at(18, 40)]):
        h.pbx.put(own_name(began, serial=serial), mp3(20), mtime=began / 1000 + 20)
    h.now = at(18, 50)
    h.order("o1", at(18, 31))
    first, second = (c["id"] for c in h.calls()["calls"])
    assert h.listen(first).status_code == 200
    old = kept / next(iter(os.listdir(kept)))
    stale = time.time() - 40 * 86400
    os.utime(old, (stale, stale))
    # the hub's own clock runs the shelf, so the test's does here: a month and more later
    h.recordings._clock = time.time
    h.recordings._pruned = None
    h.recordings.audio(second)
    assert [name for name in os.listdir(kept) if name.startswith(first)] == []
    assert [name for name in os.listdir(kept) if name.startswith(second)] != []


def test_how_the_hub_stands_with_the_recordings(tmp_path):
    h = Hub(tmp_path)
    began = at(18, 30)
    h.pbx.put(own_name(began), 9000, mtime=began / 1000 + 20)
    h.recordings.sweep()
    status = h.c.get("/phones/recordings").json()
    assert status == {
        "configured": True,
        "pbx": "",
        "calls": 1,
        "looked_ms": h.now,
        "problem": None,
        "program": "1",
        "tools": {"sox": True, "lame": True, "ffmpeg": False},
        "stereo": False,  # the program is there, its lines in the dialplan are not
    }
    h.pbx.down = True
    h.now += 120_000
    status = h.c.get("/phones/recordings").json()
    assert status["problem"]["code"] == "unreachable" and status["tools"] is None


# The program on the PBX, run as sshd runs it ----------------------------------------------------------------


class LocalPbx(CommandPbx):
    """The real program over a folder here: the request arrives in SSH_ORIGINAL_COMMAND, as sshd hands it."""

    def __init__(self, folder: Path, **more: str) -> None:
        self.folder, self.more = folder, more

    def command(self, request: str):
        env = {
            **os.environ,
            "SSH_ORIGINAL_COMMAND": request,
            "POS_RECORDINGS_DIR": str(self.folder),
            "POS_RECORDINGS_KEEP_ROOT": "1",
            "POS_STEREO_SCRIPT": str(self.folder / "no-such-program"),
            "POS_DIALPLAN_CUSTOM": str(self.folder / "no-such-file"),
            **self.more,
        }
        return ["sh", str(PROGRAM)], env


def tone(path: Path, seconds: int, *, channels: int = 1, rate: int = 8000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    made = path.with_suffix(".made.wav")
    subprocess.run(
        [
            "sox",
            "-n",
            "-r",
            str(rate),
            "-c",
            str(channels),
            "-b",
            "16",
            str(made),
            "synth",
            str(seconds),
            "sine",
            "440",
        ],
        check=True,
    )
    made.rename(path)


def test_the_program_says_what_it_is_and_lists_what_changed(tmp_path):
    folder = tmp_path / "monitor"
    began = at(18, 30)
    file = folder / own_name(began)
    file.parent.mkdir(parents=True)
    file.write_bytes(bytes(60 + 1625 * 95))
    os.utime(file, (began / 1000 + 95, began / 1000 + 95))
    pbx = LocalPbx(folder)
    about = pbx.about()
    assert about["pos-recordings"] == "1" and about["folder"] == str(folder)
    assert about["stereo-script"] == "no" and about["stereo-dialplan"] == "no"
    assert pbx.list(0) == [Listed(began / 1000 + 95, 60 + 1625 * 95, own_name(began))]
    assert pbx.list(began // 1000 + 95) == []  # nothing newer than that second
    assert pbx.list(began // 1000 + 94) != []
    # with the stereo step in place, it says so
    (folder / "pos-stereo").write_text("#!/bin/sh\n")
    (folder / "pos-stereo").chmod(0o755)
    (folder / "custom.conf").write_text((HUB / "pos-stereo.conf").read_text())
    there = LocalPbx(
        folder, POS_STEREO_SCRIPT=str(folder / "pos-stereo"), POS_DIALPLAN_CUSTOM=str(folder / "custom.conf")
    )
    assert (there.about()["stereo-script"], there.about()["stereo-dialplan"]) == ("yes", "yes")


def test_the_program_refuses_everything_else(tmp_path):
    folder = tmp_path / "monitor"
    folder.mkdir()
    (tmp_path / "secret.mp3").write_bytes(b"not yours")
    (folder / "link.mp3").symlink_to(tmp_path / "secret.mp3")
    pbx = LocalPbx(folder)
    for request, code in [
        ("sh", "refused"),
        ("list", None),  # no time: from the beginning
        ("list abc", "refused"),
        ("list 0; id", "refused"),
        ("get ../secret.mp3", "refused"),
        ("get /etc/passwd", "refused"),
        ("get -rf", "refused"),
        ("get a b", "refused"),
        ("get $(id)", "refused"),
        ("get *", "refused"),
        ("get link.mp3", "gone"),  # a link out of the folder is no recording
        ("get none.WAV", "gone"),
        ("about now please", "refused"),
    ]:
        if code is None:
            pbx.ask(request, timeout=20)
            continue
        with pytest.raises(PbxError) as err:
            pbx.ask(request, timeout=20)
        assert err.value.code == code, request


@needs_tools
def test_the_whole_way_from_the_pbxs_folder_to_the_order(tmp_path):
    folder = tmp_path / "monitor"
    began = at(18, 30)
    tone(folder / own_name(began), 5)  # FreePBX's own: one channel, 8 kHz
    h = Hub(tmp_path, LocalPbx(folder))
    h.order("o1", at(18, 31))
    call = h.calls()["calls"][0]
    assert (call["direction"], call["stereo"], call["opened"]) == ("in", False, True)
    heard = h.listen(call["id"])
    assert heard.status_code == 200
    seconds, channels = mp3_info(heard.content)
    assert 4.9 < seconds < 5.3 and channels == 1
    assert h.calls()["calls"][0]["seconds"] == 5  # measured now
    # the stereo step's file beside it: the two sides as the PBX's own pos-stereo puts them together
    legs = stereo_name(began).removesuffix(".mp3")
    tone(folder / f"{legs}-in.wav", 5)
    tone(folder / f"{legs}-out.wav", 3)
    done = subprocess.run(["sh", str(HUB / "pos-stereo"), legs], env={**os.environ, "POS_RECORDINGS_DIR": str(folder)})
    assert done.returncode == 0
    assert (folder / stereo_name(began)).exists() and not (folder / f"{legs}-in.wav").exists()
    h.now += 30_000
    assert h.calls()["calls"][0]["stereo"] is True
    seconds, channels = mp3_info(h.listen(call["id"]).content)
    assert 4.9 < seconds < 5.3 and channels == 2  # the shorter side is padded, nothing is cut


@needs_tools
def test_the_stereo_step_never_loses_a_side_it_could_not_put_together(tmp_path):
    folder = tmp_path / "monitor"
    legs = "2026/11/26/pos-1795735800.101"
    tone(folder / f"{legs}-in.wav", 2)
    (folder / f"{legs}-out.wav").write_bytes(b"this is no sound at all")
    env = {**os.environ, "POS_RECORDINGS_DIR": str(folder), "PATH": os.environ["PATH"]}
    assert subprocess.run(["sh", str(HUB / "pos-stereo"), legs], env=env).returncode == 0
    assert not (folder / f"{legs}.mp3").exists()
    assert (folder / f"{legs}-in.wav").exists() and (folder / f"{legs}-out.wav").exists()
    # and it takes no path out of the folder
    for bad in ("../x", "/etc/x", "-x", "a b", ""):
        assert subprocess.run(["sh", str(HUB / "pos-stereo"), bad], env=env).returncode == 0


# In PostgreSQL ----------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="POS_TEST_DATABASE_URL not set")
def test_the_calls_are_kept_in_postgresql():
    store = PgRecordingStore(DSN)
    try:
        with store._pool.connection() as conn:
            conn.execute("TRUNCATE call_recording, call_recording_cursor")
        assert store.cursor() is None and store.count() == 0
        began = at(18, 30)
        row = Recording(call_id(began), began, LINDA, "in", "", DID, own_name(began), 9000)
        other = Recording(call_id(began, 7), began + 1000, "6175550000", path="x.WAV", size=1)
        store.put([row, other])
        store.put([])
        assert store.get(row.call_id) == row and store.get("1.2") is None
        assert store.get_many([row.call_id, other.call_id, "1.2"]) == {row.call_id: row, other.call_id: other}
        stereo = Recording(
            **{**row.__dict__, "stereo_path": stereo_name(began), "stereo_size": 5, "seconds": 3, "measured": 5}
        )
        store.put([stereo])
        assert store.get(row.call_id) == stereo
        assert store.for_number(LINDA, began, began + 1, 10) == [stereo]
        assert store.for_number(LINDA, began + 1, began + 2, 10) == []
        assert store.count() == 2
        store.set_cursor(5)
        store.set_cursor(9)
        assert store.cursor() == 9
        store.delete(other.call_id)
        assert store.count() == 1
        # a second hub's store reads the same
        again = PgRecordingStore(DSN)
        assert again.get(row.call_id) == stereo and again.cursor() == 9
        again.close()
    finally:
        store.close()
