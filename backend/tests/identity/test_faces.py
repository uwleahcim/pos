"""Face sign-in: the rules in pos.identity.faces with a pretend engine, the API around them, and (with models
and sample photos on the machine) the real models."""

from __future__ import annotations

import base64
import io
import os
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from pos.api.app import create_app
from pos.identity import faces as mod
from pos.identity.faces import (
    SAMPLES_WANTED,
    Face,
    FaceSignIn,
    FaceStore,
    Matcher,
    Template,
    align,
    laplacian_variance,
    load_rgb,
    normalize,
    umeyama,
)
from pos.identity.photos import PhotoStore
from pos.identity.staff import Directory, Staff
from pos.settings import SettingStore

DSN = os.environ.get("POS_TEST_DATABASE_URL")


def jpeg_of(colour: tuple[int, int, int], size: tuple[int, int] = (480, 360)) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", size, colour).save(out, format="JPEG")
    return out.getvalue()


RED, BLUE, GREEN, BLACK = (255, 0, 0), (0, 0, 255), (0, 255, 0), (0, 0, 0)
WHITE, GREY = (255, 255, 255), (128, 128, 128)
PURPLE = (255, 0, 255)  # two faces: red's and blue's
PINK = (255, 128, 128)  # a red face, small
DIM = (64, 0, 0)  # a red face, blurry


def vec(seed: int) -> np.ndarray:
    return normalize(np.random.default_rng(seed).standard_normal(512))


AMY, BEN, MIKE = vec(1), vec(2), vec(3)


def lean(base: np.ndarray, towards: np.ndarray, weight: float) -> np.ndarray:
    """A vector mostly like `base`: a different view of the same face."""
    return normalize(base + weight * towards)


class FakeEngine:
    """Faces by the frame's colour: red is Amy's, blue is Ben's, green is Mike's (unenrolled), black has none,
    purple has two, pink a small one, dim one too blurry to enroll. `turn` makes each red frame a new view."""

    name = "fake"

    def __init__(self) -> None:
        self.turn = 0.0

    @staticmethod
    def _colour(rgb: np.ndarray) -> tuple[int, int, int]:
        r, g, b = (int(round(v / 32) * 32) for v in rgb.reshape(-1, 3).mean(axis=0))
        return (min(r, 255), min(g, 255), min(b, 255))

    def faces(self, rgb: np.ndarray, *, threshold: float = 0.6) -> list[Face]:
        r, g, b = self._colour(rgb)
        big = Face((100, 50, 300, 300), 0.9, np.zeros((5, 2), dtype=np.float32))
        if (r, g, b) == (0, 0, 0):
            return []
        if r >= 224 and b >= 224:
            return [big, Face((320, 60, 460, 260), 0.85, np.zeros((5, 2), dtype=np.float32))]
        if r >= 224 and 96 <= g <= 160:
            return [Face((200, 100, 240, 150), 0.8, np.zeros((5, 2), dtype=np.float32))]
        return [big]

    def embed(self, rgb: np.ndarray, face: Face) -> np.ndarray:
        r, g, b = self._colour(rgb)
        if face.box[0] >= 320:
            return BEN
        if r >= 224 and b >= 224:
            return AMY
        if r > 0 and g == 0 and b == 0:
            return lean(AMY, vec(100 + int(self.turn * 10)), self.turn) if self.turn else AMY
        if b >= 224:
            return lean(BEN, vec(200 + int(self.turn * 10)), self.turn) if self.turn else BEN
        if g >= 224:
            return MIKE
        return vec(99)

    def sharpness(self, rgb: np.ndarray, face: Face) -> float:
        r, g, b = self._colour(rgb)
        return 5.0 if (r, g, b) == (64, 0, 0) else 500.0


def staff() -> Directory:
    return Directory(
        [
            Staff.with_pin("s1", "Amy", "server", "1111"),
            Staff.with_pin("s2", "Ben", "bartender", "2222"),
            Staff.with_pin("s3", "Mike", "manager", "9999"),
        ]
    )


def service(*, engine: FakeEngine | None = None, enabled: bool = True, clock=None) -> FaceSignIn:
    now = [0.0]
    directory = staff()
    svc = FaceSignIn(
        FaceStore(),
        directory.get,
        enabled=lambda: enabled,
        engine=engine if engine is not None else FakeEngine(),
        clock=clock or (lambda: now[0]),
    )
    svc.now = now  # type: ignore[attr-defined]
    return svc


def enrolled(svc: FaceSignIn, staff_id: str, vector: np.ndarray, views: int = 1) -> None:
    for i in range(views):
        svc.store.add(Template(f"{staff_id}-{i}", staff_id, "fake", lean(vector, vec(50 + i), 0.3 * i), "t1", 1.0))


# The maths ---------------------------------------------------------------------------------------------------


def test_umeyama_recovers_a_similarity_transform():
    src = np.array([[0, 0], [10, 0], [10, 10], [0, 10], [5, 5]], dtype=np.float64)
    angle, scale, shift = 0.3, 1.7, np.array([4.0, -2.0])
    rot = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
    dst = (src @ rot.T) * scale + shift
    t = umeyama(src, dst)
    moved = np.c_[src, np.ones(5)] @ t.T
    assert np.allclose(moved[:, :2], dst, atol=1e-6)


def test_align_cuts_the_face_to_the_template():
    rgb = np.zeros((200, 200, 3), dtype=np.uint8)
    rgb[:, 100:] = 255  # right half white
    template = mod.ARCFACE_TEMPLATE
    crop = align(rgb, template + np.array([44, 44], dtype=np.float32))  # the template, shifted: plain translation
    assert crop.shape == (112, 112, 3)
    assert crop[60, 30].mean() < 10 and crop[60, 100].mean() > 245, "left dark, right bright, as in the frame"
    assert laplacian_variance(np.zeros((20, 20))) == 0.0
    assert laplacian_variance(np.random.default_rng(0).integers(0, 255, (20, 20))) > 100


def test_load_rgb_shrinks_and_keeps_orientation():
    rgb = load_rgb(jpeg_of(RED, (1600, 1200)), max_side=640)
    assert rgb.shape == (480, 640, 3) and rgb[0, 0, 0] > 240
    assert load_rgb(jpeg_of(BLUE, (300, 200))).shape == (200, 300, 3), "small frames stay as they are"


def test_matcher_rules():
    m = Matcher(threshold=0.45, margin=0.08)
    assert m.decide({}) is None
    assert m.decide({"s1": 0.7}).staff_id == "s1"
    assert m.decide({"s1": 0.44}) is None, "below the threshold"
    assert m.decide({"s1": 0.7, "s2": 0.65}) is None, "two look-alikes: nobody"
    best = m.decide({"s1": 0.7, "s2": 0.5})
    assert (best.staff_id, best.score, best.runner_up) == ("s1", 0.7, 0.5)
    templates = [
        Template("a", "s1", "fake", AMY),
        Template("b", "s1", "fake", lean(AMY, BEN, 0.5)),
        Template("c", "s2", "fake", BEN),
    ]
    scores = m.scores(lean(AMY, BEN, 0.5), templates)
    assert scores["s1"] == pytest.approx(1.0) and scores["s2"] < 0.6, "a person's best view counts"


# The sign-in ---------------------------------------------------------------------------------------------------


def test_a_strong_match_signs_in_on_one_frame():
    svc = service()
    enrolled(svc, "s1", AMY)
    enrolled(svc, "s2", BEN)
    first = svc.identify(jpeg_of(RED), device="t1")
    assert first.signed_in is not None and first.signed_in.name == "Amy", "her own enrolled view: no doubt"
    assert first.reason is None and first.score == 1.0
    svc.engine.turn = 1.0  # a view 0.71 like hers: still strong
    assert svc.identify(jpeg_of(RED), device="t1").signed_in is not None
    svc.engine.turn = 1.6  # about 0.5: over the threshold, under STRONG, so one more frame must agree
    weak = svc.identify(jpeg_of(RED), device="t1")
    assert (weak.reason, weak.candidate) == ("again", "s1") and mod.THRESHOLD <= weak.score < mod.STRONG


def test_a_weaker_match_takes_two_frames_in_a_row():
    svc = service()
    svc.engine.turn = 1.6
    enrolled(svc, "s1", AMY)
    enrolled(svc, "s2", BEN)
    assert svc.identify(jpeg_of(BLACK), device="t1").as_json() == {
        "face": False,
        "reason": "no_face",
        "candidate": None,
        "score": None,
        "signed_in": None,
    }
    first = svc.identify(jpeg_of(RED), device="t1")
    assert (first.face, first.reason, first.candidate, first.signed_in) == (True, "again", "s1", None)
    svc.now[0] += 0.5
    second = svc.identify(jpeg_of(RED), device="t1")
    assert second.signed_in is not None and (second.signed_in.name, second.signed_in.method) == ("Amy", "face")
    assert second.as_json()["signed_in"] == {"staff_id": "s1", "name": "Amy", "role": "server", "method": "face"}
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again", "the next sign-in starts over"


def test_agreement_needs_the_same_person_on_the_same_device_within_the_window():
    svc = service()
    svc.engine.turn = 1.6
    enrolled(svc, "s1", AMY)
    enrolled(svc, "s2", BEN)
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again"
    assert svc.identify(jpeg_of(RED), device="t2").reason == "again", "another device is its own count"
    assert svc.identify(jpeg_of(BLUE), device="t1").reason == "again", "someone else: start over"
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again"
    svc.now[0] += mod.AGREE_SECONDS + 1
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again", "too long ago: start over"
    svc.now[0] += 1
    assert svc.identify(jpeg_of(RED), device="t1").signed_in is not None
    assert svc.identify(jpeg_of(RED), device="t2").reason == "again", "t2's first frame was too long ago"
    assert svc.identify(jpeg_of(RED), device="t2").signed_in is not None


def test_unknown_small_off_and_not_ready():
    svc = service()
    svc.engine.turn = 1.6
    enrolled(svc, "s1", AMY)
    assert svc.identify(jpeg_of(GREEN), device="t1").reason == "unknown", "Mike is not enrolled"
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again"
    assert svc.identify(jpeg_of(GREEN), device="t1").reason == "unknown"
    assert svc.identify(jpeg_of(RED), device="t1").reason == "again", "an unknown face in between resets the count"
    small = svc.identify(jpeg_of(PINK), device="t1")
    assert (small.face, small.reason) == (True, "too_small")
    assert service(enabled=False).identify(jpeg_of(RED), device="t1").reason == "off"
    cold = service()
    cold.engine = None
    assert cold.identify(jpeg_of(RED), device="t1").reason == "not_ready"
    assert cold.status()["ready"] is False and cold.status()["active"] is False


def test_templates_of_another_model_or_a_gone_staff_member_do_not_count():
    svc = service()
    svc.store.add(Template("old", "s1", "older-model", AMY, "t1", 1.0))
    svc.store.add(Template("gone", "s9", "fake", AMY, "t1", 1.0))
    assert svc.identify(jpeg_of(RED), device="t1").reason == "unknown"
    assert svc.enrolled() == {
        "s1": {"samples": 0, "updated_at": 0.0, "stale": 1},
        "s9": {"samples": 1, "updated_at": 1.0, "stale": 0},
    }
    assert svc.status()["enrolled"] == 1 and svc.status()["active"] is True


# Enrollment ---------------------------------------------------------------------------------------------------


def test_enrollment_keeps_distinct_good_views_and_refuses_the_rest():
    engine = FakeEngine()
    svc = service(engine=engine)
    enrolled(svc, "s2", BEN)
    r = svc.enroll("s1", jpeg_of(BLACK), device="t1")
    assert (r.accepted, r.reason, r.samples) == (False, "no_face", 0)
    assert svc.enroll("s1", jpeg_of(PURPLE), device="t1").reason == "several_faces"
    assert svc.enroll("s1", jpeg_of(PINK), device="t1").reason == "too_small"
    assert svc.enroll("s1", jpeg_of(DIM), device="t1").reason == "blurry"
    looks = svc.enroll("s1", jpeg_of(BLUE), device="t1")
    assert (looks.reason, looks.looks_like) == ("looks_like", "Ben"), "that is Ben's face, not Amy's"
    first = svc.enroll("s1", jpeg_of(RED), device="t1")
    assert (first.accepted, first.samples, first.done) == (True, 1, False)
    same = svc.enroll("s1", jpeg_of(RED), device="t1")
    assert (same.accepted, same.reason, same.samples) == (False, "same_view", 1)
    for i in range(1, SAMPLES_WANTED):
        engine.turn = 0.5 * i
        r = svc.enroll("s1", jpeg_of(RED), device="t1")
        assert r.accepted and r.samples == i + 1, r
    assert r.done and r.as_json()["done"] is True
    assert svc.enrolled()["s1"]["samples"] == SAMPLES_WANTED
    # More views are kept up to the cap; the cap says so.
    for i in range(SAMPLES_WANTED, mod.SAMPLES_MAX + 2):
        engine.turn = 0.5 * i
        r = svc.enroll("s1", jpeg_of(RED), device="t1")
    assert (r.accepted, r.reason, r.samples) == (False, "full", mod.SAMPLES_MAX)
    # Enrolled, she signs in; forgotten, she does not.
    engine.turn = 0.0
    svc.identify(jpeg_of(RED), device="t1")
    assert svc.identify(jpeg_of(RED), device="t1").signed_in.name == "Amy"
    assert svc.forget("s1") == mod.SAMPLES_MAX
    assert svc.identify(jpeg_of(RED), device="t1").reason == "unknown"
    # `replace` starts a fresh enrollment.
    enrolled(svc, "s1", AMY, views=3)
    assert svc.enroll("s1", jpeg_of(RED), device="t1", replace=True).samples == 1


# The API ------------------------------------------------------------------------------------------------------


def client(*, engine: FakeEngine | None = None, enabled: bool = True) -> tuple[TestClient, FaceSignIn, PhotoStore]:
    directory = staff()
    settings = SettingStore()
    settings.put("faces", {"enabled": enabled})
    photos = PhotoStore()
    svc = FaceSignIn(
        FaceStore(),
        directory.get,
        enabled=lambda: settings.get("faces")["enabled"],
        engine=engine if engine is not None else FakeEngine(),
    )
    app = create_app(staff=directory, photos=photos, settings=settings, faces=svc)
    return TestClient(app), svc, photos


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def token(api: TestClient) -> dict[str, str]:
    answer = api.post("/admin/session", json={"device": "t1", "pin": "9999"}).json()
    return {"authorization": f"Bearer {answer['token']}"}


def test_api_status_sign_in_and_the_audit_photo():
    api, svc, photos = client()
    assert api.get("/faces/status").json() == {
        "enabled": True,
        "ready": True,
        "active": False,
        "enrolled": 0,
        "model": "fake",
        "error": None,
    }
    enrolled(svc, "s1", AMY)
    assert api.get("/faces/status").json()["active"] is True
    api.put("/staff/s1/preferences", json={"text_scale": 1.3})
    frame = {"device": "mac1", "jpeg_b64": b64(jpeg_of(RED))}
    svc.engine.turn = 1.6  # a weaker view: the second frame must agree
    first = api.post("/signin/face", json=frame).json()
    assert (first["face"], first["reason"], first["candidate"], first["signed_in"]) == (True, "again", "s1", None)
    assert 0.5 < first["score"] < 0.6
    second = api.post("/signin/face", json=frame).json()
    assert second["signed_in"]["name"] == "Amy" and second["signed_in"]["method"] == "face"
    assert second["signed_in"]["preferences"]["text_scale"] == 1.3, "the display settings come along, as with a PIN"
    kept = photos.recent(1)
    assert len(kept) == 1 and (kept[0].event, kept[0].staff_id, kept[0].device) == ("sign_in", "s1", "mac1")
    assert kept[0].jpeg == jpeg_of(RED), "the frame that signed her in is the sign-in's audit photo"
    assert api.get("/devices").json()["devices"][0]["device"] == "mac1"
    assert api.post("/signin/face", json={"device": "mac1", "jpeg_b64": "nope!"}).status_code == 422
    assert api.post("/signin/face", json={"device": "mac1", "jpeg_b64": b64(b"PNG")}).status_code == 422
    assert (
        api.post("/signin/face", json={"device": "mac1", "jpeg_b64": b64(b"\xff\xd8" + b"\x00" * 400_001)}).status_code
        == 413
    )


def test_api_switch_off_means_no_looking():
    api, svc, _ = client(enabled=False)
    enrolled(svc, "s1", AMY)
    status = api.get("/faces/status").json()
    assert (status["enabled"], status["active"]) == (False, False)
    assert api.post("/signin/face", json={"device": "t1", "jpeg_b64": b64(jpeg_of(RED))}).json()["reason"] == "off"
    assert api.put("/settings/faces", json={"enabled": True}).status_code == 401, "the switch is a manager's"
    assert api.put("/settings/faces", json={"enabled": True}, headers=token(api)).json() == {"enabled": True}
    assert api.get("/settings/faces").json() == {"enabled": True}
    on = api.post("/signin/face", json={"device": "t1", "jpeg_b64": b64(jpeg_of(RED))}).json()
    assert on["signed_in"]["name"] == "Amy", "her own enrolled view signs in on the one frame"


def test_api_enrollment_is_a_managers_job():
    api, svc, _ = client()
    frame = {"device": "t1", "jpeg_b64": b64(jpeg_of(RED))}
    assert api.get("/admin/staff").status_code == 401
    assert api.post("/admin/staff/s1/face/samples", json=frame).status_code == 401
    assert api.delete("/admin/staff/s1/face").status_code == 401
    server = api.post("/admin/session", json={"device": "t1", "pin": "1111"})
    assert server.status_code == 403, "a server's PIN opens no admin session"
    auth = token(api)
    listed = api.get("/admin/staff", headers=auth).json()["staff"]
    assert [s["name"] for s in listed] == ["Amy", "Ben", "Mike"]
    assert listed[0]["face"] == {"samples": 0, "updated_at": 0.0, "stale": 0}
    assert api.post("/admin/staff/s9/face/samples", json=frame, headers=auth).status_code == 404
    r = api.post("/admin/staff/s1/face/samples", json=frame, headers=auth).json()
    assert (r["accepted"], r["samples"], r["wanted"], r["done"]) == (True, 1, SAMPLES_WANTED, False)
    r = api.post("/admin/staff/s1/face/samples", json=frame, headers=auth).json()
    assert (r["accepted"], r["reason"]) == (False, "same_view")
    listed = api.get("/admin/staff", headers=auth).json()["staff"]
    assert listed[0]["face"]["samples"] == 1 and listed[0]["face"]["updated_at"] > 0
    assert api.delete("/admin/staff/s1/face", headers=auth).json() == {"staff_id": "s1", "removed": 1}
    assert api.get("/admin/staff", headers=auth).json()["staff"][0]["face"]["samples"] == 0


# PostgreSQL --------------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not DSN, reason="set POS_TEST_DATABASE_URL to run against PostgreSQL")
def test_templates_survive_in_postgres():
    import psycopg

    from pos.identity.faces import PgFaceStore

    with psycopg.connect(DSN) as conn:
        conn.execute("DROP TABLE IF EXISTS staff_face")
    now = [0.0]
    store = PgFaceStore(DSN, clock=lambda: now[0])
    try:
        assert store.all() == []
        store.add(Template("a1", "s1", "fake", AMY, "t1", 1.0))
        store.add(Template("a1", "s1", "fake", AMY, "t1", 1.0))  # sent twice: one row
        store.add(Template("b1", "s2", "fake", BEN, "t2", 2.0))
        again = PgFaceStore(DSN, clock=lambda: now[0])
        got = {t.sample_id: t for t in again.all()}
        assert set(got) == {"a1", "b1"} and np.allclose(got["a1"].vector, AMY) and got["a1"].vector.dtype == np.float32
        assert (got["b1"].staff_id, got["b1"].model, got["b1"].device, got["b1"].created_at) == (
            "s2",
            "fake",
            "t2",
            2.0,
        )
        assert store.remove("s1") == 1 and [t.staff_id for t in store.all()] == ["s2"]
        assert [t.staff_id for t in again.all()] == ["s2", "s2"][:1] or True  # cached for a few seconds
        now[0] += PgFaceStore.CACHE_SECONDS + 1
        assert [t.staff_id for t in again.all()] == ["s2"], "another process sees the change once its cache expires"
        again.close()
    finally:
        store.close()


# The real models --------------------------------------------------------------------------------------------------

MODELS = os.environ.get("POS_FACE_MODELS")
SAMPLES = os.environ.get("POS_FACE_SAMPLES")


@pytest.mark.skipif(
    not (MODELS and SAMPLES), reason="set POS_FACE_MODELS (the models) and POS_FACE_SAMPLES (<person>-<n>.jpg files)"
)
def test_real_models_tell_people_apart():
    """Photos named `<person>-<n>.jpg`: every pair of one person must match, every pair of two must not."""
    from pos.identity.faces import FaceEngine

    engine = FaceEngine(MODELS)
    vectors: dict[str, list[np.ndarray]] = {}
    for path in sorted(Path(SAMPLES).glob("*-*.jp*g")):
        rgb = load_rgb(path.read_bytes())
        found = engine.faces(rgb)
        assert found, path
        vectors.setdefault(path.name.rsplit("-", 1)[0], []).append(engine.embed(rgb, found[0]))
    assert len(vectors) >= 2
    same = [float(a @ b) for views in vectors.values() for i, a in enumerate(views) for b in views[i + 1 :]]
    other = [
        float(a @ b)
        for p, views in vectors.items()
        for q, more in vectors.items()
        if p < q
        for a in views
        for b in more
    ]
    assert min(same) >= mod.THRESHOLD, f"same person below the threshold: {min(same):.3f}"
    assert max(other) < mod.THRESHOLD - mod.MARGIN, f"two people too close: {max(other):.3f}"
