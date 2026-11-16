"""Event photos: the small picture a terminal takes of its operator when a major action is committed.

Stored apart from menu media and apart from the order log. Phase 0 keeps them in memory with a cap;
phase 1 writes them to the hub's disk and object storage with the retention rules from the design.
"""

from __future__ import annotations

import time
from collections import OrderedDict
from dataclasses import dataclass

MAX_BYTES = 200_000  # a 320 px JPEG is 20 to 30 KB; refuse anything that is clearly not that
KEEP = 2_000  # phase 0: the newest two thousand, then the oldest go


@dataclass(frozen=True)
class EventPhoto:
    photo_id: str
    device: str
    op_id: str | None  # the order operation it belongs to, when there is one
    event: str  # create_order | fire | close | void_line | sign_in | ...
    staff_id: str | None
    taken_at: float
    jpeg: bytes


class PhotoStore:
    def __init__(self, *, keep: int = KEEP) -> None:
        self._photos: OrderedDict[str, EventPhoto] = OrderedDict()
        self._by_op: dict[str, str] = {}  # the operation a photo belongs to -> the photo's id
        self._keep = keep

    def put(self, photo: EventPhoto) -> EventPhoto:
        if len(photo.jpeg) > MAX_BYTES:
            raise ValueError("photo too large")
        if photo.photo_id in self._photos:
            return self._photos[photo.photo_id]  # the same photo sent twice is one photo
        self._photos[photo.photo_id] = photo
        if photo.op_id:
            self._by_op.setdefault(photo.op_id, photo.photo_id)
        while len(self._photos) > self._keep:
            _, gone = self._photos.popitem(last=False)
            if gone.op_id and self._by_op.get(gone.op_id) == gone.photo_id:
                del self._by_op[gone.op_id]
        return photo

    def get(self, photo_id: str) -> EventPhoto | None:
        return self._photos.get(photo_id)

    def for_op(self, op_id: str) -> EventPhoto | None:
        """The photo taken with this order operation, while the store still has it: what a check's history
        shows beside the step."""
        photo_id = self._by_op.get(op_id)
        return self._photos.get(photo_id) if photo_id is not None else None

    def recent(self, limit: int = 50) -> list[EventPhoto]:
        return list(self._photos.values())[-limit:][::-1]

    def __len__(self) -> int:
        return len(self._photos)


def now() -> float:
    return time.time()
