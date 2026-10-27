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

**StarPRNT, added 2026-10-26.** Mike's bench has an Epson TM-T88VII (172.19.1.162) and a Star mC-Print3
(172.19.1.14). The Star speaks StarPRNT by default, so `star.py` renders the same ticket in Star Line Mode
(Star alignment and size commands, raster graphics row by row in raster mode, `ESC d` cut, `BEL` drawer);
`render(..., dialect="star")`, `--dialect star` on the CLI, `hubctl print <ip> demo star` on a hub. Each
printer record will carry its dialect.

**Star on the bench, 2026-10-27.** Mike's mC-Print3 first stopped mid-ticket and needed a power cycle.
Cause: `send_raw` closed the socket with the printer's unread status bytes, so Linux sent a TCP reset and
the printer dropped the rest of the job. It now half-closes and drains until the printer hangs up or goes
quiet; the whole ticket printed after that. Second finding: the printer cut the paper after every Chinese
line, because leaving raster mode runs the end-of-page action; the raster block now sets `ESC * r E 0` and
`ESC * r F 0` (no cut, no feed) first. A line-mode `ESC k` variant printed junk on the mC-Print3 and was
removed. `ascii` prints the demo with no graphics at all, for isolating printer trouble.

**Result.** Software part passed 2026-10-26 (15 tests). Hardware part in progress on the Epson and the Star.
