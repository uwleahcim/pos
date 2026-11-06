# Face sign-in

A staff member looks at the terminal's front camera and is signed in, with the PIN pad still there for
everyone and every time the camera does not know a face. The hub does the recognising; the app only sends
frames and shows what the hub says. Off per location until a manager turns it on.

## How it works

- **Enrollment.** Orders screen › Location (the manager PIN) › **Sign in by face**. The card lists the
  staff; **Enroll** by a name opens the camera: the person looks at it and turns their head a little, and
  the hub keeps five views, each different enough from the ones it has (a view too like one kept is
  refused with "turn the head a little"). A view that already matches someone else enrolled is refused
  with that person's name, so the manager's own face cannot slip in under another name. **Enroll again**
  starts fresh; the bin forgets the person's face (they sign in by PIN until enrolled again). Enrolling
  takes a screen with a camera: a Mac, an iPad, an iPhone or the Galaxy tablet.
- **The switch.** The same card turns face sign-in on or off for every terminal of the location. It starts
  off: the location decides after its own legal review and with each person's signed consent
  (Massachusetts has no biometric law; Illinois, Texas and Washington do, among others, which matters for a
  location there).
- **Sign-in.** With the switch on, the hub's models loaded and someone enrolled, the sign-in screen looks
  for a face as soon as it shows: an oval over the preview, "Look at the camera, or tap your PIN" under it.
  On a phone or tablet the camera's frame stream stays open while the screen looks, so the newest frame is
  always at hand, and a change in the view (someone stepping up to the screen) sends a frame at once. While
  a face is in view the next frame leaves as soon as the hub answers the last one: a strong match signs in
  on that one frame, a weaker one on the next frame that agrees ("Hold still…"), then the screen says
  "Hi Amy" and the orders open, with her own text size and contrast as after a PIN. A face the hub does not
  know shows "Not recognised: tap your PIN" after three frames; a bystander facing the camera slows the
  frames to two a second, then one every two seconds. With nobody in view a frame goes twice a second, then
  every two seconds once a dozen in a row were empty (every second on a Mac, whose camera cannot report a
  change), so twenty idle terminals do not keep the hub busy. The pad works the whole time.
- **A screen that is not looking** shows the PIN pad alone, and says why in two places: the card's status
  line in Location settings ("switched off: no screen looks until the switch is on", "nobody enrolled yet",
  "no face models yet"), and the terminal's own Settings (the gear on the sign-in screen), whose Face sign-in
  line gives the same answer plus the state of this terminal's camera.
- **The audit trail.** The frame that signed someone in is kept as the sign-in's event photo, like the
  photo an order's creation or firing takes, so what the camera saw is on record: a photograph held up to
  the camera would be in it.

## What is kept, and where

A face becomes a template: 512 numbers (an ArcFace embedding), not a picture, and a template cannot be
turned back into one. Templates live in the hub's PostgreSQL (`staff_face`, replicated to the standby hub
like the orders), a few per person; the app never sees them and no picture of an enrollment is stored.
A template records which model made it: a hub with a newer model lists those people as "enrolled with an
older model: enroll again".

## On the hub

`pos/identity/faces.py`, with two ONNX models from the InsightFace model zoo run by onnxruntime on the
hub's CPU, baked into the backend image when it is built (`backend/Dockerfile` downloads them once, about
290 MB, and checks them; `hubctl update` builds the image, so the first update after this change takes the
download):

- `det_500m.onnx`, the SCRFD-500MF face detector with five landmarks, run at 320 px: a few milliseconds
  per frame, so an idle terminal's frames cost the hub next to nothing.
- `w600k_r50.onnx`, ArcFace on a ResNet-50 trained on WebFace600K: the 112 px aligned crop in, 512 floats
  out, about 70 ms on four CPU threads (120 on two).

The rules: a face is one person's when its best cosine similarity to their templates is at least 0.45
(`POS_FACE_THRESHOLD`) and beats every other person's by 0.08; a match at 0.60 or above
(`POS_FACE_STRONG`) signs in on that one frame, a weaker one takes two frames in a row from the same
device within four seconds naming the same person. On sample photos, different pictures of one person score 0.6 to 0.8
and two people stay under 0.25. A frame is at most 640 px on the long side; a face narrower than 72 px is
"come closer". Enrollment wants a sharp view (the variance of the Laplacian of the crop) with one face in
it, and keeps a view only when it is under 0.92 similar to every view already kept.

The models load on a thread when the API starts, so the API is up at once; `GET /faces/status` says when
they are ready. A hub without the models (`POS_FACE_MODELS` unset, or the files missing) answers
`ready: false` and every sign-in screen stays a PIN pad. `POS_FACE_RECOGNIZER=w600k_mbf.onnx` with that
file in the models directory swaps in the small MobileFaceNet recognizer (10 ms, somewhat less accurate)
for a weak hub; `POS_FACE_THREADS` sets the CPU threads (up to four, as many as the hub has).

## On the wire

- `GET /faces/status`: `{"enabled", "ready", "active", "enrolled", "model", "error"}`. `active` is the one
  the sign-in screen acts on: on, ready and someone enrolled.
- `POST /signin/face` `{"device", "jpeg_b64"}`: one frame, a JPEG of at most 400 KB. The answer:
  `{"face": true, "reason": "again", "candidate": "s1", "score": 0.51, "signed_in": null}` for a first
  frame of someone known but not strongly; `"reason"` is `no_face`, `too_small`, `unknown`, `again`, `off`
  (the switch) or `not_ready` (no models yet); once the match is strong on its own or two frames agree,
  `"signed_in": {"staff_id", "name", "role", "method": "face", "preferences"}`, the shape `POST /signin`
  answers for a PIN.
- `GET /admin/staff` (manager Bearer token): `{"staff": [{"staff_id", "name", "role", "face": {"samples",
  "updated_at", "stale"}}]}`.
- `POST /admin/staff/{id}/face/samples` `{"device", "jpeg_b64", "replace"}` (manager token): one view;
  `{"accepted", "reason", "samples", "wanted", "done", "looks_like"}`, `reason` one of `no_face`,
  `several_faces`, `too_small`, `blurry`, `same_view`, `looks_like` (with the name), `full`, `not_ready`.
  `replace` on the first view of a fresh enrollment drops the views kept before.
- `DELETE /admin/staff/{id}/face` (manager token): `{"staff_id", "removed"}`.
- `GET /settings/faces` and `PUT /settings/faces` `{"enabled": true}` (manager token): the switch.

## Not yet

- Liveness: nothing stops a photograph or a phone screen held to the camera beyond the audit photo that
  records it. A passive liveness model on the hub (a second small ONNX model scoring each frame) is the
  next step if that matters; an active check (blink, turn) would slow every sign-in.
- NFC tags, the other hands-free sign-in, wait for the readers.
