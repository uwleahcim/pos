# Spike: kitchen tickets from the hub and through a relay

**Question.** Does a ticket rendered to ESC/POS bytes by the backend print on an Ethernet Epson TM
printer when sent from the hub, and when handed by the cloud to a terminal on the LAN acting as relay,
with Chinese characters readable either natively or as an image?

**Setup.** One Epson TM-m30 (or TM-T88) on the test network, the backend rendering a ticket with English
and Chinese lines, a relay mode in the Flutter app that takes a job and writes it to the printer's port.

**Pass.** The same job prints correctly by both paths; a job is never printed twice when the relay
retries; a ticket in a script the printer cannot render prints as an image; the cash drawer kick works.

**Result.** Pending.
