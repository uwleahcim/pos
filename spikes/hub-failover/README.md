# Spike: standby hub takes over in about five seconds

**Question.** With PostgreSQL streaming replication between two mini PCs and a witness vote, does the
standby take over within about five seconds of the primary dying, with every acknowledged order present,
and do terminals switch without the operator noticing?

**Setup.** Two mini PCs installed with `infra/hub/bootstrap.sh` (the backend container and PostgreSQL),
one Raspberry Pi as witness, a terminal looping orders. Kill the primary's power mid-service; later, cut the network between the hubs
only.

**Pass.** Takeover under ten seconds in the power-cut case; no acknowledged operation lost; a split network
never leaves two primaries, or if both accept orders briefly the logs merge without loss.

**Result.** Pending the second mini PC and the Raspberry Pi.

Progress 2026-10-26: hub 1 (`pos-hub1`, 172.19.1.179) installed by Mike from the `infra/hub` guide on a fresh
Ubuntu 26.04.1 LTS. `hubctl status` shows `pos-api-1` and `pos-db-1` healthy, `/health` answering, chrony at
stratum 3 serving the LAN, 207 GB free, CPU at 37 °C. Three script bugs surfaced on the way and are fixed:
`hubctl` now re-runs itself under sudo, `/etc/os-release` no longer clobbers the hub name, and the image is
built with plain `docker build` because the compose builder refuses a build context behind a symlink.
