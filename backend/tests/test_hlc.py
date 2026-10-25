from __future__ import annotations

from pos.sync.hlc import HLC, Clock


def test_stamps_increase_even_when_the_wall_clock_stands_still():
    clock = Clock("t1", physical=lambda: 1_000)
    stamps = [clock.now() for _ in range(5)]
    assert stamps == sorted(stamps)
    assert len(set(stamps)) == 5
    assert all(s.wall_ms == 1_000 for s in stamps)


def test_observing_a_remote_stamp_moves_local_stamps_past_it():
    clock = Clock("t1", physical=lambda: 1_000)
    remote = HLC(5_000, 3, "hub")
    clock.observe(remote)
    assert clock.now() > remote


def test_wall_clock_progress_resets_the_counter():
    ticks = iter([1_000, 1_000, 2_000])
    clock = Clock("t1", physical=lambda: next(ticks))
    a, b, c = clock.now(), clock.now(), clock.now()
    assert (a.counter, b.counter, c.counter) == (0, 1, 0)
    assert a < b < c


def test_text_form_round_trips_and_sorts_like_the_stamp():
    stamps = [HLC(1_700_000_000_000, 2, "t1"), HLC(1_700_000_000_001, 0, "hub"), HLC(1_700_000_000_000, 10, "t2")]
    for stamp in stamps:
        assert HLC.parse(str(stamp)) == stamp
    assert sorted(str(s) for s in stamps) == [str(s) for s in sorted(stamps)]
