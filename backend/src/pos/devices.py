"""The screens the hub hears from.

Every request the app makes with its device name tells the hub that screen is up: the desk-phone watcher's,
which every running app sends at least every fifteen seconds, and a sign-in. A manager linking a desk phone
to a screen then picks the screen from this list instead of typing its name. Kept in memory: after a restart
the hub hears from every running screen again within seconds.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Any


class DevicesSeen:
    """Device names as the app sends them, each once (regardless of case, spelled as last heard), with when
    the hub last heard from it."""

    def __init__(self, *, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock
        self._seen: dict[str, tuple[str, int]] = {}
        self._lock = threading.Lock()

    def heard(self, device: str) -> None:
        name = device.strip()
        if not name:
            return
        with self._lock:
            self._seen[name.casefold()] = (name, int(self._clock() * 1000))

    def last_heard(self, device: str) -> int | None:
        """When the hub last heard from this screen (ms), or None for one it never heard from."""
        with self._lock:
            found = self._seen.get(device.strip().casefold())
        return None if found is None else found[1]

    def listed(self) -> list[dict[str, Any]]:
        """Every screen heard from, by name."""
        with self._lock:
            found = sorted(self._seen.values(), key=lambda item: item[0].casefold())
        return [{"device": name, "seen_ms": seen_ms} for name, seen_ms in found]
