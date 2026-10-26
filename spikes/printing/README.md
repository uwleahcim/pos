# Spike: kitchen tickets from the hub and through a relay

**Question.** Does a ticket rendered to ESC/POS bytes by the backend print on an Ethernet Epson TM
printer when sent from the hub, and when handed by the cloud to a terminal on the LAN acting as relay,
with Chinese characters readable either natively or as an image?

**Setup.** One Epson TM-m30 (or TM-T88) on the test network, the backend rendering a ticket with English
and Chinese lines, a relay mode in the Flutter app that takes a job and writes it to the printer's port.

**Pass.** The same job prints correctly by both paths; a job is never printed twice when the relay
retries; a ticket in a script the printer cannot render prints as an image; the cash drawer kick works.

**Software part, done 2026-10-26.** `backend/src/pos/printing`: `escpos.py` builds the bytes (plain ASCII as
text, any other script drawn with a font and sent as a raster image, so Chinese prints the same on every
Epson model; wrap, cut, beep, drawer kick), `ticket.py` is the ticket model and renderer (new, modify, void,
reprint headers; seats, modifiers, allergy notes), `jobs.py` keeps every job until a printer accepts it:
the hub writes to port 9100 directly, a relay terminal claims jobs for printers it can reach on a short
lease, and `done` is idempotent, so a job prints once by whichever path works. Tests run against a fake
printer (`backend/tests/printing`) and decode the bytes back. Preview of the demo ticket: run
`python -m pos.printing --out ticket.bin demo` and feed the file to any ESC/POS viewer, or print it:

```
cd backend && .venv/bin/python -m pos.printing --printer 172.19.1.50 demo     # 80 mm paper
cd backend && .venv/bin/python -m pos.printing --printer 172.19.1.50 --dots 384 demo   # 58 mm
cd backend && .venv/bin/python -m pos.printing --printer 172.19.1.50 drawer
```

Still to do when the printer arrives: run the three commands above, check the Chinese lines and the drawer,
then the relay path (the app's relay mode, phase 0 stretch: a `print relay` switch in settings that polls
the backend for jobs and writes them to the printer).

**Result.** Software part passed 2026-10-26 (11 tests). Hardware part pending the Epson printer and drawer.
