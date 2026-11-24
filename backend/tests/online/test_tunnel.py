"""The tunnel's keeper (pos.online.tunnel): it starts Cloudflare's program when the API leaves it a token,
starts it anew for another token, ends it when the token is gone, tries again when it ends by itself, and
says how the tunnel stands. Cloudflare's program is stood in for: nothing here reaches Cloudflare."""

from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import sys
import textwrap
import time

import pytest

from pos.online.tunnel import (
    BEAT_SECONDS,
    SLOW_SECONDS,
    STATUS_FILE,
    TOKEN_FILE,
    WAITS,
    Child,
    Tunnel,
    mark_of,
    version_of,
    why,
)
from pos.online.wayin import WayIn

TOKEN = "eyJ-made-up-token-for-a-test-0123456789-abcdefghij"
OTHER = "eyJ-another-made-up-token-for-a-test-9876543210-zyx"
"""Nobody's tokens."""

REFUSED = [
    "2026-11-24T19:13:27Z INF Starting tunnel tunnelID=6ff42ae2-765d-4adf-8112-31c55c1551ef",
    '2026-11-24T19:13:28Z ERR Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"',
    "2026-11-24T19:13:28Z INF Tunnel server stopped",
]


class Stood:
    """Cloudflare's program, stood in for: it runs until it is told to stop, or until the test ends it."""

    def __init__(self, token: str) -> None:
        self.token = token
        self.lines: list[str] = []
        self.registered = False
        self.code: int | None = None
        self.stopped = False

    def poll(self) -> int | None:
        return self.code

    def stop(self) -> None:
        self.stopped = True
        self.code = 0

    def ends(self, code: int, lines: list[str]) -> None:
        self.lines, self.code = list(lines), code


class Kept:
    """A keeper with a folder, a clock moved by hand, and programs that are only stood in for."""

    def __init__(self, tmp_path, *, ready: bool | None = None, spawn=None) -> None:
        self.folder = tmp_path
        self.clock = 1_800_000_000.0
        self.ready = ready
        self.started: list[Stood] = []
        self.out: list[str] = []
        self.tunnel = Tunnel(
            tmp_path,
            spawn=spawn or self._spawn,
            is_ready=lambda: self.ready,
            clock=lambda: self.clock,
            version="2026.3.0",
            out=self.out.append,
        )

    def _spawn(self, token: str) -> Stood:
        self.started.append(Stood(token))
        return self.started[-1]

    def token(self, token: str | None) -> None:
        if token is None:
            (self.folder / TOKEN_FILE).unlink(missing_ok=True)
        else:
            (self.folder / TOKEN_FILE).write_text(token)

    def turn(self, after: float = 2.0) -> dict:
        self.clock += after
        self.tunnel.turn()
        return self.said()

    def said(self) -> dict:
        return json.loads((self.folder / STATUS_FILE).read_text())


def test_without_a_token_nothing_is_started_and_the_keeper_says_so(tmp_path):
    kept = Kept(tmp_path)
    said = kept.turn()
    assert kept.started == [] and kept.tunnel.state == "off"
    assert said == {
        "state": "off",
        "since_ms": 1_800_000_000_000,
        "reason": None,
        "said": "",
        "mark": "",
        "version": "2026.3.0",
        "beat_ms": 1_800_000_002_000,
    }
    assert stat.S_IMODE((tmp_path / STATUS_FILE).stat().st_mode) == 0o600
    kept.token("  \n")  # an empty file is no token
    assert kept.turn()["state"] == "off" and kept.started == []


def test_a_token_starts_the_program_and_it_is_connected_when_the_program_says_it_holds_a_line(tmp_path):
    kept = Kept(tmp_path)
    kept.turn()
    kept.token(TOKEN + "\n")
    said = kept.turn()
    assert [stood.token for stood in kept.started] == [TOKEN], "the line end of the file is not part of it"
    assert (said["state"], said["mark"], said["reason"]) == ("starting", mark_of(TOKEN), None)
    assert TOKEN not in json.dumps(said) and TOKEN not in "\n".join(kept.out)
    kept.ready = False  # it answers, and holds no line yet
    assert kept.turn()["state"] == "starting"
    kept.ready = True
    said = kept.turn()
    assert (said["state"], said["since_ms"]) == ("connected", int(kept.clock * 1000))
    assert "tunnel: connected to Cloudflare" in kept.out
    assert len(kept.started) == 1, "one program, for as long as the token stays"


def test_a_program_that_does_not_say_how_it_is_doing_is_gone_by_what_it_printed(tmp_path):
    kept = Kept(tmp_path, ready=None)
    kept.token(TOKEN)
    assert kept.turn()["state"] == "starting"
    kept.started[0].registered = True  # "Registered tunnel connection" among its lines
    assert kept.turn()["state"] == "connected"


def test_another_token_ends_the_program_and_starts_one_with_it_and_no_token_ends_it(tmp_path):
    kept = Kept(tmp_path, ready=True)
    kept.token(TOKEN)
    assert kept.turn()["state"] == "connected"
    kept.ready = None
    kept.token(OTHER)
    said = kept.turn()
    first, second = kept.started
    assert first.stopped and (second.token, second.stopped) == (OTHER, False)
    assert (said["state"], said["mark"]) == ("starting", mark_of(OTHER))
    kept.token(None)
    said = kept.turn()
    assert second.stopped and (said["state"], said["mark"]) == ("off", "") and len(kept.started) == 2
    kept.token(OTHER)  # and typed again: started at once, whatever went before
    assert kept.turn()["state"] == "starting" and len(kept.started) == 3


def test_a_program_that_ends_is_started_again_later_each_time_and_fails_until_it_holds_a_line(tmp_path):
    kept = Kept(tmp_path, ready=None)
    kept.token(TOKEN)
    kept.turn()
    waits = []
    for n in range(len(WAITS) + 2):
        kept.started[-1].ends(1, REFUSED)
        said = kept.turn(0.5)
        assert (said["state"], said["reason"]) == ("failing", "refused")
        assert said["said"] == 'Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"'
        assert len(kept.started) == n + 1, "not started again at once"
        ended = kept.clock
        while len(kept.started) == n + 1:
            assert kept.turn(1.0)["state"] == "failing", "still failing while it waits and while it tries"
        waits.append(round(kept.clock - ended))
    assert waits == [5, 10, 20, 40, 80, 160, 300, 300, 300]
    first_failed = kept.said()["since_ms"]
    assert first_failed < int(kept.clock * 1000) - 600_000, "failing since the first time, not since the last try"
    # the token is put right at Cloudflare's end: the next try holds a line, and the count starts over
    kept.ready = True
    assert kept.turn()["state"] == "connected"
    kept.ready = None
    kept.started[-1].ends(1, ["2026-11-24T19:20:00Z ERR failed to dial to edge with quic: timeout: no recent network"])
    said = kept.turn(0.5)
    assert (said["state"], said["reason"]) == ("failing", "unreachable")
    started = len(kept.started)
    kept.turn(4.0)
    assert len(kept.started) == started
    kept.turn(1.5)
    assert len(kept.started) == started + 1, "five seconds again, as after a first failure"


def test_another_token_is_tried_at_once_whatever_the_last_one_s_wait_was(tmp_path):
    kept = Kept(tmp_path, ready=None)
    kept.token(TOKEN)
    kept.turn()
    for _ in range(5):
        kept.started[-1].ends(1, REFUSED)
        kept.turn(400.0)
    kept.started[-1].ends(1, REFUSED)
    kept.turn(1.0)
    before = len(kept.started)
    kept.token(OTHER)
    said = kept.turn(1.0)
    assert len(kept.started) == before + 1 and kept.started[-1].token == OTHER
    assert (said["state"], said["reason"]) == ("starting", None), "what the last token did says nothing of this one"


def test_a_program_that_runs_and_finds_no_line_for_long_is_failing_though_it_goes_on_trying(tmp_path):
    kept = Kept(tmp_path, ready=False)
    kept.token(TOKEN)
    kept.turn()
    kept.started[0].lines = [
        "2026-11-24T19:13:27Z INF Starting tunnel",
        '2026-11-24T19:13:30Z ERR Failed to dial a quic connection error="failed to dial to edge with quic: timeout"',
        "2026-11-24T19:13:31Z INF Retrying connection in up to 2s",
    ]
    assert kept.turn(SLOW_SECONDS - 4)["state"] == "starting"
    said = kept.turn(4)
    assert (said["state"], said["reason"]) == ("failing", "unreachable")
    assert said["said"].startswith("Failed to dial a quic connection")
    assert len(kept.started) == 1 and not kept.started[0].stopped, "it is left to go on trying"
    kept.ready = True  # the internet came back
    assert kept.turn()["state"] == "connected"
    # and a line that is lost is "starting" again, and failing only when it stays lost
    kept.ready = False
    kept.started[0].lines = []
    assert kept.turn()["state"] == "starting"
    assert kept.turn(SLOW_SECONDS - 3)["state"] == "starting"
    said = kept.turn(3)
    assert (said["state"], said["reason"], said["said"]) == ("failing", "slow", "")


def test_a_hub_without_cloudflare_s_program_says_that_it_is_missing(tmp_path):
    def none(token: str):
        raise FileNotFoundError("cloudflared")

    kept = Kept(tmp_path, spawn=none)
    kept.token(TOKEN)
    said = kept.turn()
    assert (said["state"], said["reason"], said["said"]) == ("failing", "missing", "")
    assert version_of("no-such-program-on-this-machine") == ""


def test_it_says_how_it_stands_again_every_few_seconds_and_not_with_every_look(tmp_path):
    kept = Kept(tmp_path, ready=True)
    kept.token(TOKEN)
    first = kept.turn()
    assert kept.turn(2.0) == first and kept.turn(2.0) == first, "nothing changed: nothing is written"
    later = kept.turn(BEAT_SECONDS)
    assert later["beat_ms"] > first["beat_ms"] and later["since_ms"] == first["since_ms"]


def test_a_folder_that_cannot_be_written_is_said_once_and_the_tunnel_is_kept_all_the_same(tmp_path):
    (tmp_path / STATUS_FILE).mkdir()  # something is in the way
    kept = Kept(tmp_path, ready=True)
    kept.token(TOKEN)
    for _ in range(3):
        kept.clock += 2
        kept.tunnel.turn()
    assert kept.tunnel.state == "connected" and len(kept.started) == 1
    assert len([line for line in kept.out if "cannot say how it stands" in line]) == 1


def test_why_a_program_is_not_connected_is_read_from_its_last_lines():
    assert why(REFUSED)[0] == "refused"
    assert why(["Provided Tunnel token is not valid.", "See 'cloudflared tunnel run --help'."]) == (
        "refused",
        "Provided Tunnel token is not valid.",
    )
    assert why(["2026-11-24T19:13:30Z ERR dial tcp: lookup region1.v2.argotunnel.com: no such host"]) == (
        "unreachable",
        "dial tcp: lookup region1.v2.argotunnel.com: no such host",
    )
    assert why(["2026-11-24T19:13:30Z ERR something nobody has seen yet", "2026-11-24T19:13:31Z INF goodbye"]) == (
        "trouble",
        "something nobody has seen yet",
    )
    assert why(["only this"]) == ("trouble", "only this") and why([]) == ("trouble", "")
    assert len(why(["2026-11-24T19:13:30Z ERR " + "x" * 900])[1]) == 200
    old = [
        '2026-11-24T19:00:00Z ERR error="Unauthorized: Invalid tunnel secret"',
        *["2026-11-24T19:01:00Z INF fine"] * 12,
    ]
    assert why(old)[0] == "trouble", "only its last lines count"


# --- with a program that really runs --------------------------------------------------------------------------------

STAND_IN = textwrap.dedent(
    """\
    #!{python}
    import os, sys, time, signal
    token = os.environ.get("TUNNEL_TOKEN", "")
    if sys.argv[1:] == ["--version"]:
        print("cloudflared version 2026.3.0 (built 2026-03-01-1200 UTC)")
        sys.exit(0)
    print("2026-11-24T19:13:27Z INF Starting tunnel with " + " ".join(sys.argv[1:]), flush=True)
    print("2026-11-24T19:13:27Z INF Settings: token=" + token, flush=True)
    if "refuse" in token:
        print('2026-11-24T19:13:28Z ERR error="Unauthorized: Invalid tunnel secret"', file=sys.stderr, flush=True)
        sys.exit(1)
    def asked_to_end(*_):
        print("2026-11-24T19:13:40Z INF Initiating graceful shutdown", flush=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, asked_to_end)
    print("2026-11-24T19:13:29Z INF Registered tunnel connection connIndex=0 location=bos01", flush=True)
    time.sleep(60)
    """
)


def stand_in(tmp_path) -> str:
    """A program named as Cloudflare's is, which says what Cloudflare's says and reaches nobody."""
    path = tmp_path / "bin" / "cloudflared"
    path.parent.mkdir()
    path.write_text(STAND_IN.format(python=sys.executable))
    path.chmod(0o755)
    return str(path)


def until(test, seconds: float = 10.0) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if test():
            return True
        time.sleep(0.05)
    return False


def test_the_token_goes_to_the_program_in_its_environment_and_is_taken_out_of_everything_it_prints(tmp_path):
    printed: list[str] = []
    child = Child([stand_in(tmp_path), "tunnel", "--no-autoupdate", "run"], TOKEN, out=printed.append)
    try:
        assert until(lambda: child.registered), printed
        assert child.poll() is None
        text = "\n".join(printed)
        assert "Starting tunnel with tunnel --no-autoupdate run" in text, "the token is not on its command line"
        assert TOKEN not in text and "token=(the token)" in text
        assert TOKEN not in "\n".join(child.lines)
    finally:
        child.stop()
    assert child.poll() == 0 and "Initiating graceful shutdown" in "\n".join(printed), "it was asked to end, and did"


def test_what_a_program_said_last_before_it_ended_is_what_the_keeper_goes_by(tmp_path):
    child = Child([stand_in(tmp_path)], "eyJ-refuse-this-one-0123456789-0123456789-0123456789", out=lambda line: None)
    assert until(lambda: child.poll() is not None)
    assert child.poll() == 1 and why(child.lines) == ("refused", 'error="Unauthorized: Invalid tunnel secret"')
    child.stop()  # nothing to end, and no harm


@pytest.mark.skipif(os.name != "posix", reason="the keeper is the hub's, and the hub is Linux")
def test_the_keeper_as_the_hub_runs_it_from_a_token_left_to_a_line_held_to_the_token_gone(tmp_path):
    program = stand_in(tmp_path)
    folder = tmp_path / "tunnel"
    folder.mkdir()
    env = {
        **os.environ,
        "PATH": f"{os.path.dirname(program)}{os.pathsep}{os.environ.get('PATH', '')}",
        "POS_TUNNEL_DIR": str(folder),
        "PYTHONUNBUFFERED": "1",
    }
    env.pop("TUNNEL_TOKEN", None)
    keeper = subprocess.Popen(
        [sys.executable, "-m", "pos.online.tunnel"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    def said() -> dict:
        try:
            return json.loads((folder / STATUS_FILE).read_text())
        except (OSError, ValueError):
            return {}

    try:
        assert until(lambda: said().get("state") == "off"), "it waits for a token"
        assert said()["version"] == "2026.3.0"
        # the API leaves the token, as it does when a manager types it; the API reads how the tunnel stands
        wayin = WayIn(None, folder)
        wayin.hand(None, TOKEN)
        assert until(lambda: said().get("state") == "connected"), said()
        assert (wayin.tunnel()["there"], wayin.tunnel()["state"]) == (True, "connected")
        wayin.hand(None, None)
        assert until(lambda: said().get("state") == "off"), said()
    finally:
        keeper.send_signal(signal.SIGTERM)
        out, _ = keeper.communicate(timeout=20)
    assert keeper.returncode == 0, out
    assert TOKEN not in out and "tunnel: connected to Cloudflare" in out and "the tunnel is stopped" in out
    assert "Initiating graceful shutdown" in out, "Cloudflare's program was asked to end, not left behind"
