"""Face sign-in: a staff member looks at the terminal's front camera and is signed in.

The terminal sends the hub small frames off its camera, as it already sends the audit photos. The hub finds
the face, turns it into a template (512 numbers, an ArcFace embedding) and compares it with the templates
enrolled for the staff. Nothing but those numbers is kept for a face: no picture, and a template cannot be
turned back into one. They stay in the hub's PostgreSQL (replicated to the standby hub like everything
else); the app never sees them, and a manager can remove a person's templates at any time.

Models, from the InsightFace "buffalo" model zoo (ONNX, run with onnxruntime on the hub's CPU; the backend
image downloads them when it is built, see backend/Dockerfile):

- `det_500m.onnx`: the SCRFD-500MF face detector with five landmarks, run at 320 px: a few ms per frame.
- `w600k_r50.onnx`: ArcFace, a ResNet-50 trained on WebFace600K; a 112x112 aligned crop in, 512 floats out.

The rules (`Matcher`, `FaceSignIn`): a face is one staff member's when its best similarity to their templates
is at least THRESHOLD and beats every other staff member's by MARGIN; a sign-in takes two frames in a row
from the same device agreeing within AGREE_SECONDS, so one odd frame never signs anyone in. Enrollment
takes SAMPLES_WANTED views of the person, each different enough from the ones kept (a slight turn of the
head), and refuses a view that already matches someone else enrolled, so a manager tapping through the
enrollment cannot enroll their own face under another name.
"""

from __future__ import annotations

import io
import logging
import os
import secrets
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

import numpy as np
from PIL import Image, ImageOps

from .staff import SignIn, Staff

if TYPE_CHECKING:
    from .photos import PhotoStore

log = logging.getLogger(__name__)

THRESHOLD = float(os.environ.get("POS_FACE_THRESHOLD", "0.45"))
"""Cosine similarity a frame needs to the templates of one staff member to be theirs."""
MARGIN = 0.08
"""How far the best staff member must stand above the runner-up: two look-alikes sign in by PIN."""
AGREE_SECONDS = 4.0
"""Two frames from one device within this window must name the same person for a sign-in."""
SAMPLES_WANTED = 5
"""Views enrolled per person before the enrollment is complete; more are kept up to SAMPLES_MAX."""
SAMPLES_MAX = 8
NEW_VIEW = 0.92
"""A view this similar to one already kept for the person is the same view: turn the head a little."""
MIN_FACE = 72
"""Smallest face (box width in the frame) worth recognising: closer to the camera below it."""
DET_SCORE = 0.60
MIN_SHARPNESS = 40.0
"""Variance of the Laplacian of the aligned crop below which an enrollment view is refused as blurry."""
MAX_SIDE = 640
"""Frames are shrunk to this many pixels on the long side before anything is done with them."""
DEFAULT_DETECTOR = "det_500m.onnx"
DEFAULT_RECOGNIZER = "w600k_r50.onnx"

ARCFACE_TEMPLATE = np.array(
    [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]],
    dtype=np.float32,
)
"""Where the eyes, nose and mouth corners sit in a 112x112 ArcFace crop."""


@dataclass(frozen=True)
class Face:
    """One face the detector found: its box and five landmarks, in the frame's pixels."""

    box: tuple[float, float, float, float]  # x1, y1, x2, y2
    score: float
    kps: np.ndarray  # 5 x 2: left eye, right eye, nose, left mouth corner, right mouth corner

    @property
    def width(self) -> float:
        return self.box[2] - self.box[0]

    @property
    def height(self) -> float:
        return self.box[3] - self.box[1]

    @property
    def area(self) -> float:
        return max(self.width, 0.0) * max(self.height, 0.0)


class Engine(Protocol):
    """What the sign-in needs from a face engine; `FaceEngine` is the real one, tests bring their own."""

    name: str

    def faces(self, rgb: np.ndarray) -> list[Face]: ...

    def embed(self, rgb: np.ndarray, face: Face) -> np.ndarray: ...

    def sharpness(self, rgb: np.ndarray, face: Face) -> float: ...


def load_rgb(jpeg: bytes, *, max_side: int = MAX_SIDE) -> np.ndarray:
    """A frame as the engine wants it: upright (EXIF honoured), RGB, at most `max_side` px on the long side."""
    image = Image.open(io.BytesIO(jpeg))
    image = ImageOps.exif_transpose(image) or image
    image = image.convert("RGB")
    long = max(image.size)
    if long > max_side:
        scale = max_side / long
        image = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))))
    return np.asarray(image, dtype=np.uint8)


def umeyama(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """The similarity transform (rotation, uniform scale, translation) taking `src` points onto `dst`, as a
    3x3 matrix: Umeyama's closed form, as scikit-image's SimilarityTransform estimates it."""
    num, dim = src.shape
    src_mean = src.mean(axis=0)
    dst_mean = dst.mean(axis=0)
    src_demean = src - src_mean
    dst_demean = dst - dst_mean
    a = dst_demean.T @ src_demean / num
    d = np.ones((dim,), dtype=np.float64)
    if np.linalg.det(a) < 0:
        d[dim - 1] = -1
    t = np.eye(dim + 1, dtype=np.float64)
    u, s, vt = np.linalg.svd(a)
    rank = np.linalg.matrix_rank(a)
    if rank == 0:
        return t * np.nan
    if rank == dim - 1:
        if np.linalg.det(u) * np.linalg.det(vt) > 0:
            t[:dim, :dim] = u @ vt
        else:
            saved = d[dim - 1]
            d[dim - 1] = -1
            t[:dim, :dim] = u @ np.diag(d) @ vt
            d[dim - 1] = saved
    else:
        t[:dim, :dim] = u @ np.diag(d) @ vt
    scale = 1.0 / src_demean.var(axis=0).sum() * (s @ d)
    t[:dim, dim] = dst_mean - scale * (t[:dim, :dim] @ src_mean.T)
    t[:dim, :dim] *= scale
    return t


def align(rgb: np.ndarray, kps: np.ndarray, size: int = 112) -> np.ndarray:
    """The 112x112 crop ArcFace was trained on: the face turned and scaled so its landmarks land on the
    template's."""
    matrix = umeyama(np.asarray(kps, dtype=np.float64), ARCFACE_TEMPLATE.astype(np.float64))
    inverse = np.linalg.inv(matrix)  # Pillow maps every output pixel back to its source
    a, b, c = inverse[0]
    d, e, f = inverse[1]
    crop = Image.fromarray(rgb).transform(
        (size, size), Image.Transform.AFFINE, (a, b, c, d, e, f), Image.Resampling.BILINEAR
    )
    return np.asarray(crop, dtype=np.uint8)


def laplacian_variance(gray: np.ndarray) -> float:
    """How sharp a crop is: the variance of its Laplacian (flat, blurry crops score low)."""
    g = gray.astype(np.float32)
    lap = 4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
    return float(lap.var())


def _nms(boxes: np.ndarray, scores: np.ndarray, threshold: float) -> list[int]:
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep: list[int] = []
    while order.size > 0:
        i = int(order[0])
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1 + 1)
        h = np.maximum(0.0, yy2 - yy1 + 1)
        overlap = (w * h) / (areas[i] + areas[order[1:]] - w * h)
        order = order[1:][overlap <= threshold]
    return keep


class FaceEngine:
    """The detector and the recognizer, as ONNX models on the CPU."""

    STRIDES = (8, 16, 32)
    ANCHORS = 2

    def __init__(
        self,
        model_dir: str | Path,
        *,
        detector: str = DEFAULT_DETECTOR,
        recognizer: str = DEFAULT_RECOGNIZER,
        det_size: int = 320,
        threads: int = 2,
    ) -> None:
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        providers = ["CPUExecutionProvider"]
        model_dir = Path(model_dir)
        self._det = ort.InferenceSession(str(model_dir / detector), options, providers=providers)
        self._rec = ort.InferenceSession(str(model_dir / recognizer), options, providers=providers)
        self._det_in = self._det.get_inputs()[0].name
        self._det_out = [o.name for o in self._det.get_outputs()]
        self._rec_in = self._rec.get_inputs()[0].name
        self.det_size = det_size
        self.name = Path(recognizer).stem
        self.detector = Path(detector).stem
        self._centers: dict[tuple[int, int], np.ndarray] = {}
        self._lock = threading.Lock()  # one frame at a time: the hub has other work, and this bounds the CPU

    @classmethod
    def from_env(cls) -> FaceEngine | None:
        """The engine from POS_FACE_MODELS (a directory with the two models), or None when there is none."""
        model_dir = os.environ.get("POS_FACE_MODELS") or "/app/models"
        detector = os.environ.get("POS_FACE_DETECTOR") or DEFAULT_DETECTOR
        recognizer = os.environ.get("POS_FACE_RECOGNIZER") or DEFAULT_RECOGNIZER
        path = Path(model_dir)
        if not (path / detector).is_file() or not (path / recognizer).is_file():
            log.info("face sign-in off: no models at %s", path)
            return None
        return cls(path, detector=detector, recognizer=recognizer, threads=int(os.environ.get("POS_FACE_THREADS", "2")))

    def _anchor_centers(self, height: int, width: int, stride: int) -> np.ndarray:
        key = (height, width)
        if key not in self._centers:
            ys, xs = np.mgrid[:height, :width]
            centers = np.stack([xs, ys], axis=-1).astype(np.float32).reshape(-1, 2) * stride
            self._centers[key] = np.repeat(centers, self.ANCHORS, axis=0)
        return self._centers[key]

    def faces(self, rgb: np.ndarray, *, threshold: float = DET_SCORE) -> list[Face]:
        """Every face in the frame scoring at least `threshold`, largest first."""
        h, w = rgb.shape[:2]
        scale = self.det_size / max(h, w)
        new_w, new_h = max(1, int(w * scale)), max(1, int(h * scale))
        resized = np.asarray(Image.fromarray(rgb).resize((new_w, new_h)), dtype=np.float32)
        canvas = np.zeros((self.det_size, self.det_size, 3), dtype=np.float32)
        canvas[:new_h, :new_w] = resized
        blob = ((canvas - 127.5) / 128.0).transpose(2, 0, 1)[None]
        with self._lock:
            outs = self._det.run(self._det_out, {self._det_in: blob})
        boxes_all, scores_all, kps_all = [], [], []
        fmc = len(self.STRIDES)
        for i, stride in enumerate(self.STRIDES):
            scores = outs[i].reshape(-1)
            boxes = outs[i + fmc] * stride
            kps = outs[i + fmc * 2] * stride
            centers = self._anchor_centers(self.det_size // stride, self.det_size // stride, stride)
            picked = np.where(scores >= threshold)[0]
            if picked.size == 0:
                continue
            c = centers[picked]
            b = boxes[picked]
            k = kps[picked]
            boxes_all.append(
                np.stack([c[:, 0] - b[:, 0], c[:, 1] - b[:, 1], c[:, 0] + b[:, 2], c[:, 1] + b[:, 3]], axis=1)
            )
            scores_all.append(scores[picked])
            kps_all.append(np.stack([c[:, 0:1] + k[:, 0::2], c[:, 1:2] + k[:, 1::2]], axis=2))
        if not boxes_all:
            return []
        boxes = np.vstack(boxes_all) / scale
        scores = np.concatenate(scores_all)
        kps = np.vstack(kps_all) / scale
        keep = _nms(boxes, scores, 0.4)
        found = [Face(tuple(float(v) for v in boxes[i]), float(scores[i]), kps[i].astype(np.float32)) for i in keep]
        found.sort(key=lambda f: f.area, reverse=True)
        return found

    def embed(self, rgb: np.ndarray, face: Face) -> np.ndarray:
        """The face's template: 512 floats of unit length."""
        crop = align(rgb, face.kps).astype(np.float32)
        blob = ((crop - 127.5) / 127.5).transpose(2, 0, 1)[None]
        with self._lock:
            out = self._rec.run(None, {self._rec_in: blob})[0][0]
        return normalize(out)

    def sharpness(self, rgb: np.ndarray, face: Face) -> float:
        crop = align(rgb, face.kps)
        gray = crop @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        return laplacian_variance(gray)


def normalize(vector: np.ndarray) -> np.ndarray:
    v = np.asarray(vector, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(v))
    return v / norm if norm > 0 else v


# Templates -------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Template:
    """One enrolled view of one staff member."""

    sample_id: str
    staff_id: str
    model: str  # the recognizer that made the vector; another model's templates do not compare
    vector: np.ndarray
    device: str | None = None
    created_at: float = 0.0


class FaceStore:
    """In memory: tests and a laptop. Every hub and the cloud use `PgFaceStore`."""

    def __init__(self) -> None:
        self._templates: dict[str, Template] = {}

    def add(self, template: Template) -> None:
        self._templates[template.sample_id] = template

    def remove(self, staff_id: str) -> int:
        gone = [k for k, t in self._templates.items() if t.staff_id == staff_id]
        for k in gone:
            del self._templates[k]
        return len(gone)

    def all(self) -> list[Template]:
        return list(self._templates.values())

    def for_staff(self, staff_id: str) -> list[Template]:
        return [t for t in self._templates.values() if t.staff_id == staff_id]


SCHEMA = """
CREATE TABLE IF NOT EXISTS staff_face (
    sample_id  TEXT PRIMARY KEY,
    staff_id   TEXT NOT NULL,
    model      TEXT NOT NULL,
    vector     BYTEA NOT NULL,
    device     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS staff_face_staff ON staff_face (staff_id);
"""


class PgFaceStore(FaceStore):
    """The templates in PostgreSQL, read in bulk and kept for a few seconds between frames."""

    CACHE_SECONDS = 5.0

    def __init__(self, dsn: str, *, pool_size: int = 2, clock: Callable[[], float] = time.monotonic) -> None:
        from psycopg.rows import tuple_row
        from psycopg_pool import ConnectionPool

        super().__init__()
        self._pool = ConnectionPool(dsn, min_size=1, max_size=pool_size, open=True, kwargs={"row_factory": tuple_row})
        self._clock = clock
        self._read_at: float | None = None
        with self._pool.connection() as conn:
            row = conn.execute("SELECT pg_is_in_recovery()").fetchone()
            if row is not None and not row[0]:
                conn.execute(SCHEMA)

    def close(self) -> None:
        self._pool.close()

    def _refresh(self, *, force: bool = False) -> None:
        now = self._clock()
        if not force and self._read_at is not None and now - self._read_at < self.CACHE_SECONDS:
            return
        with self._pool.connection() as conn:
            rows = conn.execute(
                "SELECT sample_id, staff_id, model, vector, device, EXTRACT(EPOCH FROM created_at) FROM staff_face"
            ).fetchall()
        self._templates = {
            r[0]: Template(r[0], r[1], r[2], np.frombuffer(bytes(r[3]), dtype=np.float32).copy(), r[4], float(r[5]))
            for r in rows
        }
        self._read_at = now

    def add(self, template: Template) -> None:
        from psycopg import errors

        from ..sync.pgstore import ReadOnlyError

        try:
            with self._pool.connection() as conn:
                conn.execute(
                    "INSERT INTO staff_face (sample_id, staff_id, model, vector, device, created_at) "
                    "VALUES (%s, %s, %s, %s, %s, to_timestamp(%s)) ON CONFLICT (sample_id) DO NOTHING",
                    (
                        template.sample_id,
                        template.staff_id,
                        template.model,
                        template.vector.astype(np.float32).tobytes(),
                        template.device,
                        template.created_at or time.time(),
                    ),
                )
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        self._refresh(force=True)

    def remove(self, staff_id: str) -> int:
        from psycopg import errors

        from ..sync.pgstore import ReadOnlyError

        try:
            with self._pool.connection() as conn:
                cur = conn.execute("DELETE FROM staff_face WHERE staff_id = %s", (staff_id,))
                gone = cur.rowcount
        except errors.ReadOnlySqlTransaction as err:
            raise ReadOnlyError("this database is a standby") from err
        self._refresh(force=True)
        return gone

    def all(self) -> list[Template]:
        self._refresh()
        return list(self._templates.values())

    def for_staff(self, staff_id: str) -> list[Template]:
        self._refresh()
        return [t for t in self._templates.values() if t.staff_id == staff_id]


def default_face_store() -> FaceStore:
    """PostgreSQL when DATABASE_URL is set (every hub and the cloud), memory otherwise."""
    dsn = os.environ.get("DATABASE_URL")
    return PgFaceStore(dsn) if dsn else FaceStore()


# Matching ----------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Match:
    staff_id: str
    score: float
    runner_up: float  # the best score of anyone else, or 0


class Matcher:
    def __init__(self, *, threshold: float = THRESHOLD, margin: float = MARGIN) -> None:
        self.threshold = threshold
        self.margin = margin

    @staticmethod
    def scores(vector: np.ndarray, templates: Iterable[Template]) -> dict[str, float]:
        """Each staff member's best similarity to `vector` over their templates."""
        best: dict[str, float] = {}
        for t in templates:
            score = float(np.dot(vector, t.vector))
            if score > best.get(t.staff_id, -2.0):
                best[t.staff_id] = score
        return best

    def decide(self, scores: Mapping[str, float]) -> Match | None:
        """Whose face this is, by the rules at the top of the module, or None."""
        if not scores:
            return None
        ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
        staff_id, score = ranked[0]
        runner_up = ranked[1][1] if len(ranked) > 1 else 0.0
        if score < self.threshold or score - runner_up < self.margin:
            return None
        return Match(staff_id, score, runner_up)

    def match(self, vector: np.ndarray, templates: Iterable[Template]) -> Match | None:
        return self.decide(self.scores(vector, templates))


# The sign-in itself ----------------------------------------------------------------------------------------------


@dataclass
class FrameResult:
    """What the hub says about one frame from the sign-in screen."""

    face: bool
    reason: str | None = None  # off | not_ready | no_face | too_small | unknown | again
    candidate: str | None = None  # the staff member this frame looks like, before the second frame agrees
    score: float | None = None
    signed_in: SignIn | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "face": self.face,
            "reason": self.reason,
            "candidate": self.candidate,
            "score": None if self.score is None else round(self.score, 3),
            "signed_in": None
            if self.signed_in is None
            else {
                "staff_id": self.signed_in.staff_id,
                "name": self.signed_in.name,
                "role": self.signed_in.role,
                "method": self.signed_in.method,
            },
        }


@dataclass
class EnrollResult:
    accepted: bool
    reason: str | None  # not_ready | no_face | several_faces | too_small | blurry | same_view | looks_like | full
    samples: int
    wanted: int = SAMPLES_WANTED
    looks_like: str | None = None  # the name of the staff member this view already matches

    @property
    def done(self) -> bool:
        return self.samples >= self.wanted

    def as_json(self) -> dict[str, Any]:
        return {
            "accepted": self.accepted,
            "reason": self.reason,
            "samples": self.samples,
            "wanted": self.wanted,
            "done": self.done,
            "looks_like": self.looks_like,
        }


@dataclass
class _Sighting:
    staff_id: str
    at: float
    frames: int = 1


@dataclass
class FaceSignIn:
    """Frames in, sign-ins out; and the enrollment that makes them possible.

    `engine` may start as None and arrive later (`start` loads it in a thread, so the API is up at once).
    `staff` finds a person by id; `enabled` says whether the location has face sign-in switched on.
    """

    store: FaceStore
    staff: Callable[[str], Staff | None]
    enabled: Callable[[], bool] = lambda: True
    engine: Engine | None = None
    matcher: Matcher = field(default_factory=Matcher)
    clock: Callable[[], float] = time.monotonic
    _sightings: dict[str, _Sighting] = field(default_factory=dict)
    _loading: threading.Thread | None = None
    load_error: str | None = None

    @property
    def ready(self) -> bool:
        return self.engine is not None

    def start(self, load: Callable[[], Engine | None]) -> None:
        """Loads the engine on a thread: reading the recognizer takes a second or two."""

        def run() -> None:
            try:
                self.engine = load()
            except Exception as err:  # noqa: BLE001 - whatever onnxruntime raises, the API runs on without faces
                self.load_error = str(err)
                log.exception("face engine failed to load")

        self._loading = threading.Thread(target=run, name="face-engine", daemon=True)
        self._loading.start()

    def wait(self, timeout: float = 30.0) -> None:
        if self._loading is not None:
            self._loading.join(timeout)

    def enrolled(self) -> dict[str, dict[str, Any]]:
        """Per staff id: how many views are enrolled and when the last was, for the current model."""
        out: dict[str, dict[str, Any]] = {}
        model = self.engine.name if self.engine else None
        for t in self.store.all():
            info = out.setdefault(t.staff_id, {"samples": 0, "updated_at": 0.0, "stale": 0})
            if model is None or t.model == model:
                info["samples"] += 1
                info["updated_at"] = max(info["updated_at"], t.created_at)
            else:
                info["stale"] += 1  # enrolled with another model: enroll again
        return out

    def status(self) -> dict[str, Any]:
        enrolled = self.enrolled()
        return {
            "enabled": bool(self.enabled()),
            "ready": self.ready,
            "active": bool(self.enabled()) and self.ready and any(i["samples"] for i in enrolled.values()),
            "enrolled": sum(1 for i in enrolled.values() if i["samples"]),
            "model": self.engine.name if self.engine else None,
            "error": self.load_error,
        }

    def _templates(self) -> list[Template]:
        model = self.engine.name if self.engine else None
        return [t for t in self.store.all() if t.model == model and self.staff(t.staff_id) is not None]

    def identify(self, jpeg: bytes, *, device: str) -> FrameResult:
        """One frame from a sign-in screen: whose face it is, and the sign-in once two frames agree."""
        if not self.enabled():
            return FrameResult(False, "off")
        engine = self.engine
        if engine is None:
            return FrameResult(False, "not_ready")
        rgb = load_rgb(jpeg)
        faces = engine.faces(rgb)
        if not faces:
            self._sightings.pop(device, None)
            return FrameResult(False, "no_face")
        face = faces[0]  # the largest: the person at the screen, not someone passing behind
        if face.width < MIN_FACE:
            return FrameResult(True, "too_small")
        match = self.matcher.match(engine.embed(rgb, face), self._templates())
        if match is None:
            self._sightings.pop(device, None)
            return FrameResult(True, "unknown")
        now = self.clock()
        seen = self._sightings.get(device)
        if seen is None or seen.staff_id != match.staff_id or now - seen.at > AGREE_SECONDS:
            self._sightings[device] = _Sighting(match.staff_id, now)
            return FrameResult(True, "again", candidate=match.staff_id, score=match.score)
        seen.frames += 1
        seen.at = now
        person = self.staff(match.staff_id)
        if person is None:
            return FrameResult(True, "unknown")
        self._sightings.pop(device, None)
        signed = SignIn(person.staff_id, person.name, person.role, "face", device, now)
        return FrameResult(True, None, candidate=match.staff_id, score=match.score, signed_in=signed)

    def enroll(self, staff_id: str, jpeg: bytes, *, device: str, replace: bool = False) -> EnrollResult:
        """One view of `staff_id` from the enrollment screen, kept when it is good and new."""
        engine = self.engine
        if engine is None:
            return EnrollResult(False, "not_ready", 0)
        if replace:
            self.store.remove(staff_id)
        mine = [t for t in self.store.for_staff(staff_id) if t.model == engine.name]
        count = len(mine)
        rgb = load_rgb(jpeg)
        faces = engine.faces(rgb, threshold=0.7)
        if not faces:
            return EnrollResult(False, "no_face", count)
        if len(faces) > 1 and faces[1].width >= MIN_FACE:
            return EnrollResult(False, "several_faces", count)
        face = faces[0]
        if face.width < MIN_FACE:
            return EnrollResult(False, "too_small", count)
        if count >= SAMPLES_MAX:
            return EnrollResult(False, "full", count)
        if engine.sharpness(rgb, face) < MIN_SHARPNESS:
            return EnrollResult(False, "blurry", count)
        vector = engine.embed(rgb, face)
        others = [t for t in self._templates() if t.staff_id != staff_id]
        scores = self.matcher.scores(vector, others)
        if scores:
            other_id, score = max(scores.items(), key=lambda kv: kv[1])
            if score >= self.matcher.threshold:
                other = self.staff(other_id)
                return EnrollResult(False, "looks_like", count, looks_like=other.name if other else other_id)
        if any(float(np.dot(vector, t.vector)) >= NEW_VIEW for t in mine):
            return EnrollResult(False, "same_view", count)
        self.store.add(Template(secrets.token_hex(8), staff_id, engine.name, vector, device, time.time()))
        return EnrollResult(True, None, count + 1)

    def forget(self, staff_id: str) -> int:
        return self.store.remove(staff_id)


def photo_for(frame: FrameResult, jpeg: bytes, *, device: str, photo_store: PhotoStore, taken_at: float) -> None:
    """The frame that signed someone in goes into the event photos, like any other major action's photo: the
    audit trail shows who the camera saw, which is also what a held-up photograph would look like."""
    from .photos import EventPhoto

    signed = frame.signed_in
    if signed is None:
        return
    photo = EventPhoto(
        photo_id=f"face-{device}-{int(taken_at * 1000)}",
        device=device,
        op_id=None,
        event="sign_in",
        staff_id=signed.staff_id,
        taken_at=taken_at,
        jpeg=jpeg,
    )
    try:
        photo_store.put(photo)
    except ValueError:
        pass


def is_jpeg(data: bytes) -> bool:
    return data.startswith(b"\xff\xd8")


def clean_faces(data: Mapping[str, Any]) -> dict[str, Any]:
    """The face sign-in setting as the app may set it: `enabled`. Raises ValueError on a bad value."""
    enabled = data.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be true or false")
    return {"enabled": enabled}
