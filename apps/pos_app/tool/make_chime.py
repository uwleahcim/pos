"""Makes assets/sounds/ticket.wav, the chime a kitchen screen plays when a ticket comes in.

Two struck notes, a high one and then a lower one (ding-dong), each ringing out like a small bell: nothing
like the phone's warble (tool/make_ring.py), so nobody in the kitchen looks for a call. Bright on purpose (the
notes and their overtones sit between one and four kHz, where a tablet's speaker is loudest and a hood fan is
not) and under a second, so two tickets a moment apart are two chimes. 22.05 kHz, mono, 16-bit, about 40 KB;
WAV because every platform's player decodes it without a codec question. Standard library only:

    python3 tool/make_chime.py
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 22050
LENGTH = 0.9  # seconds
NOTES = ((0.0, 1318.5), (0.22, 1046.5))  # when each is struck, and its pitch in Hz: E6, then C6
OVERTONES = ((1.0, 1.0), (2.0, 0.35), (3.0, 0.12))  # of each note: how many times its pitch, and how loud
DECAY = 7.0  # how fast a note dies away, per second
ATTACK = 0.004  # seconds for a note to come up, so the strike does not click
FADE = 0.03  # seconds of fade at the very end
LEVEL = 0.9  # of full scale, at the loudest sample


def note(t: float, struck: float, pitch: float) -> float:
    """One note at time [t]: silent before it is struck, then ringing out."""
    since = t - struck
    if since < 0:
        return 0.0
    loud = min(1.0, since / ATTACK) * math.exp(-DECAY * since)
    return loud * sum(part * math.sin(2 * math.pi * pitch * times * since) for times, part in OVERTONES)


def samples() -> list[int]:
    count = int(RATE * LENGTH)
    raw = []
    for i in range(count):
        t = i / RATE
        value = sum(note(t, struck, pitch) for struck, pitch in NOTES)
        raw.append(value * min(1.0, (LENGTH - t) / FADE))
    peak = max(abs(value) for value in raw)
    return [int(value / peak * LEVEL * 32767) for value in raw]


def main() -> None:
    target = Path(__file__).resolve().parent.parent / "assets" / "sounds" / "ticket.wav"
    target.parent.mkdir(parents=True, exist_ok=True)
    data = samples()
    with wave.open(str(target), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(struct.pack(f"<{len(data)}h", *data))
    print(f"wrote {target} ({target.stat().st_size} bytes, {LENGTH:g} s)")


if __name__ == "__main__":
    main()
