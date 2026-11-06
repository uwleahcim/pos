# Face sign-in

A staff member looks at the terminal's front camera and is signed in, with the PIN pad still there for
everyone and every time the camera does not know a face. The hub does the recognising; the app only sends
frames and shows what the hub says. Off per location until a manager turns it on. Once it is on, the
camera also does the switching: whoever steps up to a terminal is its signed-in user, and a tag held to a
reader does the same where faces are not wanted (**Hands-free** and **Tags** below).

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

## Hands-free: whoever is at the screen

Servers walk up to a station and order; nobody signs out and nobody taps a PIN. The camera keeps looking
after the sign-in, on every screen of the app and not only the sign-in screen:

- **Following.** Each frame tells the hub who is signed in on this screen (`current`). The hub follows that
  person's face by its box from one frame to the next and runs the recogniser on it again only every three
  seconds (`POS_FACE_VERIFY`), so a screen with its server at it costs the hub a detector pass per frame, a
  few milliseconds, and the answer is `same`: nothing changes.
- **Switching.** Another face takes the screen over once it is clearly the one at the screen: the signed-in
  person is out of the view, or the newcomer's face is at least one and a half times the area of theirs
  (whoever stepped up fills more of the camera than whoever stands beside). The newcomer is recognised
  under the sign-in rules (a strong match on one frame, else two frames agreeing), the hub records a
  sign-in event with that frame as its photo, and the screen is theirs: whatever the last person had open
  closes, the orders open under the new name, and "Hi Ben" shows for a moment. A face the hub does not know
  never unseats someone still in view, and two enrolled people side by side do not flip the screen back and
  forth.
- **Away.** A person the camera has not seen for a minute is signed out and the screen goes back to looking
  (**Sign out when the camera has not seen the person for**, in Location settings: never, 30 seconds, 1, 2,
  5 or 10 minutes). Only someone the camera has recognised is signed out this way: a person who signed in by
  PIN or tag stays until the camera recognises them or they sign out, so someone not enrolled is never
  signed out from behind.
- **Holds.** While a manager approves something with their PIN (a comp) or enrolls a face, the camera does
  not switch the screen: the manager's face at the screen during an approval must not make the order
  theirs. The frames resume as the dialog closes.
- **The switch.** **Switch to whoever steps up**, in Location settings (on to start), turns the switching
  off for every terminal: then only the sign-in screen signs people in, a face seen while someone is signed
  in changes nothing, and with the away time at never no frame goes at all while someone is signed in.
- **The pace** is the sign-in screen's: with a face in view the frames go as fast as the hub answers for the
  first three, then two a second, then one every two seconds, so a server at a station costs the hub a
  detector pass every two seconds and a recognition every three; with nobody in view, two a second for a
  dozen frames and then one every two seconds, and a change in the view sends one at once.

## Tags

For a location that does not allow faces, or a person who would rather not enroll one, a tag does the
same: an NFC badge, card or fob held to a reader at the terminal. The reader is one that works in keyboard
mode (a USB or Bluetooth "wedge" reader: it types the tag's id and Enter), so it works on a Mac, an iPad, an
iPhone and the Galaxy tablet alike with nothing to install. The app tells a reader's burst from someone
typing: characters at most 60 ms apart, 4 to 64 of them, ending in Enter; a key the app would otherwise act
on still acts.

- **Enrollment.** Orders screen › Location › **Sign in by face**: the tag button by a name opens "A tag for
  Amy"; hold the tag to this screen's reader and it is hers (a screen without a reader takes the id typed as
  printed on the tag). A tag that is already someone else's is refused with their name, a new tag replaces
  the person's old one, and the crossed-out tag button forgets it. The person's line shows the last four
  characters of the id.
- **Sign-in and switching.** A tag held to any screen's reader signs its owner in: on the sign-in screen, or
  over whoever is signed in when the switch is on (with it off the screen says "Switching is off here: sign
  out first"); an unknown tag says so for a moment. A sign-in by tag is a sign-in event like a PIN's
  (`method: "tag"`), with no photo of its own; the photos an order's events take record who was at the
  screen. The away sign-out applies to it only once the camera has recognised the person.
- **What is kept.** Only the tag's id as the reader types it (upper-cased, separators dropped), in the hub's
  PostgreSQL (`staff_tag`: one tag per person, each tag one person's), never what is printed on the badge.
  The static staff list's `tag_uid` (`POS_STAFF`) still signs in on a laptop without a database.

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

While someone is signed in, a face in the next frame is theirs when its box overlaps the last by half
(`TRACK_IOU`), it is recognised again every `VERIFY_SECONDS` (3, `POS_FACE_VERIFY`), and another face is
the one at the screen when it is the only face or `STAY_RATIO` (1.5) times the area of theirs. A hub that
follows nobody (the person stepped out of the view) recognises every frame's largest face as on the sign-in
screen.

The models load on a thread when the API starts, so the API is up at once; `GET /faces/status` says when
they are ready. A hub without the models (`POS_FACE_MODELS` unset, or the files missing) answers
`ready: false` and every sign-in screen stays a PIN pad. `POS_FACE_RECOGNIZER=w600k_mbf.onnx` with that
file in the models directory swaps in the small MobileFaceNet recognizer (10 ms, somewhat less accurate)
for a weak hub; `POS_FACE_THREADS` sets the CPU threads (up to four, as many as the hub has).

## On the wire

- `GET /faces/status`: `{"enabled", "ready", "active", "enrolled", "model", "error"}`. `active` is the one
  the sign-in screen acts on: on, ready and someone enrolled.
- `POST /signin/face` `{"device", "jpeg_b64", "current"}`: one frame, a JPEG of at most 400 KB, and the
  staff id signed in on the screen (or null). The answer:
  `{"face": true, "reason": "again", "candidate": "s1", "score": 0.51, "signed_in": null, "present": false}`
  for a first frame of someone known but not strongly; `"reason"` is `no_face`, `too_small`, `unknown`,
  `again`, `same` (the person signed in is the one at the screen), `off` (the switch) or `not_ready` (no
  models yet); `"present"` says the signed-in person is in view, at the screen or beside it; once the match
  is strong on its own or two frames agree, `"signed_in": {"staff_id", "name", "role", "method": "face",
  "preferences"}`, the shape `POST /signin` answers for a PIN (and, while someone else is signed in, the
  person who took the screen over).
- `POST /signin` `{"device", "tag_uid"}`: a tag as the reader typed it; the PIN sign-in's answer with
  `"method": "tag"`, or 401 `unknown_credential`.
- `GET /settings/presence` and `PUT /settings/presence` `{"switch": true, "away_seconds": 60}` (manager
  token): hands-free switching for the location; `away_seconds` is 0 (never) to 3600, else 422 `bad_value`.
- `GET /admin/staff` (manager Bearer token): `{"staff": [{"staff_id", "name", "role", "face": {"samples",
  "updated_at", "stale"}, "tag": {"enrolled", "ends", "updated_at"}}]}`, `ends` the id's last four
  characters.
- `PUT /admin/staff/{id}/tag` `{"tag_uid", "device"}` (manager token): the person's tag, replacing the one
  they had; `{"staff_id", "tag": {"enrolled": true, "ends", "updated_at"}}`, or 409 `tag_taken` with the
  owner's `name` ("That tag is Amy's"), 422 `bad_tag`, 404 `unknown_staff`.
- `DELETE /admin/staff/{id}/tag` (manager token): `{"staff_id", "removed"}`.
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
- The phones' and tablets' own NFC is not used: the iPad and the Mac have none, the iPhone shows a system
  sheet for each read, and the Galaxy tablets mostly lack it, while a keyboard-mode reader covers every
  screen the same way. Tapping a phone's own NFC would be a follow-up for the terminals that have it.
