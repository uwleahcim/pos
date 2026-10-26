# Spike: PIN, NFC and face on each station type

**Question.** On each station type (Mac, iPad, iPhone), can the app read an NTAG 424 DNA or DESFire tag
(built-in NFC on iPhones, a USB reader on Macs and iPads), and produce a face signature on device from the
front camera that the backend can match?

**Setup.** Ten tags, one USB NFC reader for the Mac (and a Lightning or USB-C reader for the iPad), the Flutter app from the platforms spike,
a backend endpoint that stores and matches signatures (any well-documented on-device face library; the
backend only compares vectors).

**Pass.** Tag tap signs in under one second on every device type; face match under one second with no
false accept across ten enrolled staff; the event photo path captures a 320 px frame on each action.

**Software part, done 2026-10-26.** PIN sign-in end to end: the app's PIN pad posts to `/signin`, the backend
holds salted PIN hashes (`pos.identity.staff`, demo staff or `POS_STAFF`), five misses lock that device
for a minute, and the signed-in name travels on the `create` operation as `server`. Event photos: the app
keeps the front camera preview on screen (sign-in page, then a thumbnail in the app bar), takes a low
resolution JPEG when an order is created, fired, closed, reopened or a line voided, queues it on disk and
posts it to `/events/photos` with the operation id, device and staff id; `GET /events/photos` lists them
and `/events/photos/{id}` returns the picture. Nothing blocks on the photo: no camera, no photo.
To check on the Mac: sign in as 1111, make an order, then `curl http://172.19.1.179:8000/events/photos`.

**Result.** PIN and event photo: software passed 2026-10-26 (6 backend tests, 3 app tests). Hardware
check on the Mac passed 2026-10-26: Mike signed in as Amy (1111) on `mac1` against hub 1, created and
fired an order, and `GET /events/photos` listed one 72 KB JPEG tagged `device=mac1 event=fire staff_id=s1`
with the fire operation's id. Only the fire photo was listed because the app never snapped on order creation (the order
list screen skipped the call); fixed the same day, so the next build also photographs `create`. iPad and iPhone passed minutes later: `ipad1` (Ben, s2, 31 KB) and `iphone1` (Mike, s3, 37 KB) each posted
their fire photo to the hub. PIN sign-in and the event photo path are PASSED on all three station types.
NFC tags and face signatures wait for the tags and readers.
