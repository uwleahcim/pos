"""Hybrid logical clocks.

A timestamp is (wall_ms, counter, node). It follows wall-clock time when clocks agree and falls back
to a counter when they do not, so an event that was *seen* before another always sorts before it,
whatever the devices' clocks say. The node id breaks the last ties, so no two devices ever produce
the same stamp.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass


def wall_clock_ms() -> int:
    return int(time.time() * 1000)


@dataclass(frozen=True, order=True)
class HLC:
    wall_ms: int
    counter: int
    node: str

    def __str__(self) -> str:
        return f"{self.wall_ms:013d}-{self.counter:04d}-{self.node}"

    @classmethod
    def parse(cls, text: str) -> HLC:
        wall, counter, node = text.split("-", 2)
        return cls(int(wall), int(counter), node)


class Clock:
    """The clock of one device. `now()` stamps a local event; `observe()` learns from a remote stamp."""

    def __init__(self, node: str, physical: Callable[[], int] = wall_clock_ms) -> None:
        if not node or "-" in node:
            raise ValueError("node id must be non-empty and contain no '-'")
        self.node = node
        self._physical = physical
        self._wall = 0
        self._counter = 0

    def now(self) -> HLC:
        physical = self._physical()
        if physical > self._wall:
            self._wall, self._counter = physical, 0
        else:
            self._counter += 1
        return HLC(self._wall, self._counter, self.node)

    def observe(self, remote: HLC) -> None:
        """Advance past a stamp received from another device, so later local stamps sort after it."""
        physical = self._physical()
        previous = self._wall
        self._wall = max(previous, remote.wall_ms, physical)
        if self._wall == previous and self._wall == remote.wall_ms:
            self._counter = max(self._counter, remote.counter) + 1
        elif self._wall == previous:
            self._counter += 1
        elif self._wall == remote.wall_ms:
            self._counter = remote.counter + 1
        else:
            self._counter = 0

    @property
    def last(self) -> HLC:
        return HLC(self._wall, self._counter, self.node)
