"""Makes assets/sounds/ring.wav, the ring the app loops while a call rings on every platform.

An electronic warble, the sound of an office phone: 620 and 780 Hz alternating twenty times a second, in two
short bursts, then quiet until the three-second cycle repeats. 16 kHz, mono, 16-bit, about 96 KB; WAV because
every platform's player decodes it without a codec question. Standard library only:

    python3 tool/make_ring.py
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 16000
CYCLE = 3.0  # seconds; the asset loops
BURSTS = ((0.0, 0.45), (0.55, 1.0))  # ring-ring, then silence to the end of the cycle
TONES = (620.0, 780.0)  # Hz, alternating
WARBLE = 20.0  # changes per second
RAMP = 0.008  # seconds of fade at each burst edge, so nothing clicks
LEVEL = 0.45  # of full scale


def envelope(t: float) -> float:
    """0 outside a burst, 1 inside, with a short linear fade at both edges."""
    for start, end in BURSTS:
        if start <= t < end:
            return min(1.0, (t - start) / RAMP, (end - t) / RAMP)
    return 0.0


def samples() -> list[int]:
    out: list[int] = []
    phase = 0.0  # kept continuous across the tone changes, which is what keeps them click-free
    for i in range(int(RATE * CYCLE)):
        t = i / RATE
        tone = TONES[int(t * WARBLE) % len(TONES)]
        phase += 2 * math.pi * tone / RATE
        value = math.sin(phase) * envelope(t) * LEVEL
        out.append(int(max(-1.0, min(1.0, value)) * 32767))
    return out


def main() -> None:
    target = Path(__file__).resolve().parent.parent / "assets" / "sounds" / "ring.wav"
    target.parent.mkdir(parents=True, exist_ok=True)
    data = samples()
    with wave.open(str(target), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(struct.pack(f"<{len(data)}h", *data))
    print(f"wrote {target} ({target.stat().st_size} bytes, {CYCLE:g} s)")


if __name__ == "__main__":
    main()
