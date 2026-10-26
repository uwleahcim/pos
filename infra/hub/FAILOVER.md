# Two hubs: replication and takeover

How the second hub joins and how takeover works. This is the plan for the hub failover spike; the pieces
that run today are marked. Everything here is per location.

## Shape

```
hub 1 (primary)     hub 2 (standby)      Raspberry Pi (witness)
PostgreSQL ──WAL──▶ PostgreSQL
Patroni             Patroni              (no Postgres)
etcd  ◀───────────▶ etcd ◀─────────────▶ etcd            three votes, one leader
API (role=primary)  API (role=replica)
```

- **PostgreSQL streaming replication** copies every committed operation from the primary to the standby
  within milliseconds. Synchronous commit is off: an order is acknowledged by the primary alone, which is
  what "no acknowledged order lost" is tested against (the standby is normally under a second behind, and
  the order log merges any gap when the old primary returns).
- **Patroni** on each hub watches its PostgreSQL and holds a leader lease in etcd. When the primary stops
  renewing the lease, the standby promotes itself. Lease and loop are tuned to about 5 to 10 seconds.
- **etcd** runs on hub 1, hub 2 and the Pi. A leader needs two of three votes, so two hubs that lose sight
  of each other cannot both be primary: the one the Pi can still see keeps the lease. With the internet
  down nothing changes; the cloud is not in the vote.
- **The API** on each hub talks to its own PostgreSQL. `/health` reports `role`: `primary` takes orders,
  `replica` serves reads and answers `503 read_only` to writes. Terminals treat 503 like no answer: they
  move to the next address (hub 2, then the cloud) and come back when the role flips. *Running today.*
- **Printers** are reached by whichever hub is primary; print jobs live in the database so a promotion
  keeps the queue.

## Hub 2 install (when the second mini PC arrives)

1. Same OS install as hub 1, then `sudo ./infra/hub/bootstrap.sh --name pos-hub2` so it has Docker, the
   image, the firewall and chrony. Give it a reserved address (plan: 172.19.1.180).
2. Raspberry Pi: Raspberry Pi OS Lite 64-bit, reserved address 172.19.1.181, Docker, and the etcd member
   only (`infra/hub/witness/`, to be added with the spike).
3. Replace the plain `db` service on both hubs with the Patroni-managed one (`docker-compose.failover.yml`,
   to be added with the spike): image `ghcr.io/zalando/spilo-16`, `PATRONI_SCOPE=pos-<location>`,
   `PATRONI_NAME=pos-hub1|pos-hub2`, `ETCD3_HOSTS=172.19.1.179:2379,172.19.1.180:2379,172.19.1.181:2379`,
   `ttl: 10`, `loop_wait: 2`, `retry_timeout: 5`, the existing `pos-db` volume on hub 1 (Patroni adopts it)
   and an empty one on hub 2 (Patroni runs `pg_basebackup` itself).
4. Firewall: ufw on each hub allows 5432 and 8008 (Patroni API) from the other hub, and 2379/2380 (etcd)
   between all three.
5. `hubctl status` gains the role and the replication lag from `http://127.0.0.1:8008/patroni`.

## The test script (pass criteria in `spikes/hub-failover/README.md`)

1. A terminal loops orders against the address list hub 1, hub 2, cloud. Note the cursor on both hubs.
2. Pull hub 1's power. Expected: within 10 s hub 2's `/health` says `primary`; the terminal's status bar
   shows hub 2; no acknowledged operation missing (compare the terminal's sent ids with `GET /ops`).
3. Power hub 1 back up. Expected: it rejoins as a replica (Patroni uses `pg_rewind` if it diverged) and
   `/health` says `replica`.
4. Cut the network between the hubs only (unplug hub 2's cable while the Pi stays up). Expected: hub 2 steps
   down since it cannot reach a majority; hub 1 stays primary; the terminal never sees two primaries.
5. Pull the Pi. Expected: nothing changes while both hubs are healthy; a hub failure now needs a person.

## Verified without the hardware (2026-10-26)

With one PostgreSQL primary and a streaming standby on a laptop: an operation written to the primary is
readable on the standby in under 100 ms; the standby's API answers `role: replica` and `503 read_only` on a
write; after `pg_ctl promote` the same API answers `role: primary` and accepts writes (test
`test_standby_serves_reads_and_refuses_writes` in `backend/tests/test_pgstore.py`, run with
`POS_TEST_STANDBY_URL`). What remains is Patroni, etcd and the physical pulls.
