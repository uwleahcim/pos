"""What a staff member sets for themselves and keeps on every device they sign in on: text size, a
high-contrast setting, their screen language, and whether the floor map picks out their own tables.

The backend stores them, so a server who likes big text on the Mac at the host stand gets it on the
handheld too. The app applies them the moment the sign-in answer arrives and sends a change back here.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from psycopg import errors
from psycopg.rows import tuple_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from ..sync.pgstore import ReadOnlyError

DEFAULTS: dict[str, Any] = {"text_scale": 1.0, "high_contrast": False, "locale": "en", "my_tables": False}
TEXT_SCALE_RANGE = (0.8, 1.6)


def clean(data: Mapping[str, Any]) -> dict[str, Any]:
    """The keys the app may set, checked; anything else is dropped. Raises ValueError on a bad value."""
    out: dict[str, Any] = {}
    if data.get("text_scale") is not None:
        scale = float(data["text_scale"])
        low, high = TEXT_SCALE_RANGE
        if not low <= scale <= high:
            raise ValueError(f"text_scale must be between {low} and {high}")
        out["text_scale"] = scale
    if data.get("high_contrast") is not None:
        out["high_contrast"] = bool(data["high_contrast"])
    if data.get("locale") is not None:
        locale = str(data["locale"]).strip()
        if not locale or len(locale) > 16:
            raise ValueError("locale must be a language tag such as en or zh-Hans")
        out["locale"] = locale
    if data.get("my_tables") is not None:
        if not isinstance(data["my_tables"], bool):
            raise ValueError("my_tables must be true or false")
        out["my_tables"] = data["my_tables"]
    return out


class PreferenceStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgPreferenceStore`."""

    def __init__(self) -> None:
        self._data: dict[str, dict[str, Any]] = {}

    def get(self, staff_id: str) -> dict[str, Any]:
        return {**DEFAULTS, **self._data.get(staff_id, {})}

    def put(self, staff_id: str, data: Mapping[str, Any]) -> dict[str, Any]:
        """Merges the given keys over what is stored; returns the whole set with defaults filled in."""
        self._data[staff_id] = {**self._data.get(staff_id, {}), **clean(data)}
        return self.get(staff_id)


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_preference (
    staff_id   TEXT PRIMARY KEY,
    data       JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


class PgPreferenceStore(PreferenceStore):
    """The same calls, in PostgreSQL, so preferences follow staff across devices and survive restarts."""

    def __init__(self, dsn: str, *, pool_size: int = 2) -> None:
        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def get(self, staff_id: str) -> dict[str, Any]:
        with self._pool.connection() as conn:
            row = conn.execute("SELECT data FROM staff_preference WHERE staff_id = %s", (staff_id,)).fetchone()
        return {**DEFAULTS, **(row[0] if row else {})}

    def put(self, staff_id: str, data: Mapping[str, Any]) -> dict[str, Any]:
        cleaned = clean(data)
        try:
            with self._pool.connection() as conn:
                row = conn.execute(
                    """
                    INSERT INTO staff_preference (staff_id, data) VALUES (%s, %s)
                    ON CONFLICT (staff_id) DO UPDATE
                        SET data = staff_preference.data || EXCLUDED.data, updated_at = now()
                    RETURNING data
                    """,
                    (staff_id, Jsonb(cleaned)),
                ).fetchone()
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        return {**DEFAULTS, **(row[0] if row else cleaned)}
