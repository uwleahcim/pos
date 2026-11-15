"""Text size, contrast, language and "my tables" per staff member, kept by the backend so they follow the person."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.identity.preferences import DEFAULTS, PreferenceStore, clean
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.sync.oplog import OpStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def test_defaults_merge_and_checks():
    store = PreferenceStore()
    usual = {"text_scale": 1.0, "high_contrast": False, "locale": "en", "my_tables": False}
    assert store.get("s1") == DEFAULTS == usual
    assert store.put("s1", {"text_scale": 1.3})["text_scale"] == 1.3
    assert store.put("s1", {"high_contrast": True}) == {**usual, "text_scale": 1.3, "high_contrast": True}
    # the floor map picks out this person's own tables: kept like the rest, and a save of something else keeps it
    assert store.put("s1", {"my_tables": True})["my_tables"] is True
    assert store.put("s1", {"locale": "zh-Hans"})["my_tables"] is True
    assert store.put("s1", {"my_tables": False})["my_tables"] is False
    assert store.get("s2") == DEFAULTS, "someone else is untouched"
    with pytest.raises(ValueError):
        clean({"my_tables": "sometimes"})
    with pytest.raises(ValueError):
        clean({"text_scale": 3})
    with pytest.raises(ValueError):
        clean({"locale": "   "})
    assert clean({"text_scale": None, "favourite_colour": "red"}) == {}, "unknown keys are dropped, None keeps"


def test_sign_in_brings_the_preferences_along():
    api = TestClient(create_app(OpStore(), menu=MenuService(build_example()), printing=PrintService([])))
    r = api.put("/staff/s1/preferences", json={"text_scale": 1.15, "high_contrast": True})
    assert r.status_code == 200 and r.json()["preferences"]["text_scale"] == 1.15
    assert api.put("/staff/s1/preferences", json={"my_tables": True}).json()["preferences"]["my_tables"] is True
    r = api.post("/signin", json={"device": "t1", "pin": "1111"})
    assert r.status_code == 200
    assert r.json()["preferences"] == {"text_scale": 1.15, "high_contrast": True, "locale": "en", "my_tables": True}
    assert api.get("/staff/s2/preferences").json()["preferences"] == DEFAULTS
    r = api.put("/staff/s1/preferences", json={"text_scale": 9})
    assert r.status_code == 422 and r.json()["detail"]["error"] == "bad_preference"
    kept = api.get("/staff/s1/preferences").json()["preferences"]
    assert kept["text_scale"] == 1.15, "a refused save changes nothing"


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_preferences_survive_in_postgres():
    import psycopg

    from pos.identity.preferences import PgPreferenceStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS staff_preference")
    store = PgPreferenceStore(DSN)
    try:
        assert store.get("s9") == DEFAULTS
        store.put("s9", {"text_scale": 1.3})
        merged = store.put("s9", {"locale": "zh-Hans"})
        assert merged == {"text_scale": 1.3, "high_contrast": False, "locale": "zh-Hans", "my_tables": False}
        assert store.put("s9", {"my_tables": True})["my_tables"] is True
        again = PgPreferenceStore(DSN)
        try:
            assert again.get("s9")["locale"] == "zh-Hans"
        finally:
            again.close()
    finally:
        store.close()
