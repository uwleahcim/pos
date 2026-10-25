# Spike: standby hub takes over in about five seconds

**Question.** With PostgreSQL streaming replication between two mini PCs and a witness vote, does the
standby take over within about five seconds of the primary dying, with every acknowledged order present,
and do terminals switch without the operator noticing?

**Setup.** Two mini PCs installed with `infra/hub/bootstrap.sh` (the backend container and PostgreSQL),
one Raspberry Pi as witness, a terminal looping orders. Kill the primary's power mid-service; later, cut the network between the hubs
only.

**Pass.** Takeover under ten seconds in the power-cut case; no acknowledged operation lost; a split network
never leaves two primaries, or if both accept orders briefly the logs merge without loss.

**Result.** Pending.
