# Spike: PIN, NFC and face on each station type

**Question.** On each station type (Mac, iPad, iPhone), can the app read an NTAG 424 DNA or DESFire tag
(built-in NFC on iPhones, a USB reader on Macs and iPads), and produce a face signature on device from the
front camera that the backend can match?

**Setup.** Ten tags, one USB NFC reader for the Mac (and a Lightning or USB-C reader for the iPad), the Flutter app from the platforms spike,
a backend endpoint that stores and matches signatures (any well-documented on-device face library; the
backend only compares vectors).

**Pass.** Tag tap signs in under one second on every device type; face match under one second with no
false accept across ten enrolled staff; the event photo path captures a 320 px frame on each action.

**Result.** Pending.
