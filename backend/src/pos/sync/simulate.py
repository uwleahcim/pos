"""Terminals and a hub syncing over a lossy network.

Each replica (a terminal, the hub, the cloud) has its own clock with its own skew, its own store, an
outbox of operations not yet acknowledged, and a pull cursor per peer. The channel drops, duplicates
and reorders messages and loses acknowledgements. When the cables are back, a few clean rounds must
leave every replica with the same operations and the same order states.

    python -m pos.sync.simulate --replicas 4 --rounds 300 --drop 0.3 --dup 0.1 --seed 1
"""

from __future__ import annotations

import argparse
import random
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

from .hlc import Clock
from .oplog import Op, OpStore

ITEMS = ["General Tso's Chicken", "Spicy Tuna Roll", "Tsingtao", "Hot and Sour Soup", "Sake carafe"]
COURSES = ["drinks", "apps", "entrees", "dessert"]
ALLERGENS = ["peanut", "crustacean", "sesame", "wheat"]


class SimTime:
    """A shared physical clock that advances one millisecond per reading."""

    def __init__(self, start_ms: int = 1_800_000_000_000) -> None:
        self.t = start_ms

    def tick(self) -> int:
        self.t += 1
        return self.t

    def skewed(self, skew_ms: int) -> Callable[[], int]:
        return lambda: self.tick() + skew_ms


class Channel:
    """A network path that may drop, duplicate and reorder operations and lose acknowledgements."""

    def __init__(
        self,
        rng: random.Random,
        drop: float = 0.0,
        dup: float = 0.0,
        shuffle: bool = False,
        lose_ack: float = 0.0,
    ) -> None:
        self.rng, self.drop, self.dup, self.shuffle, self.lose_ack = rng, drop, dup, shuffle, lose_ack
        self.dropped = 0

    def transmit(self, ops: Iterable[Op]) -> list[Op]:
        out: list[Op] = []
        for op in ops:
            if self.rng.random() < self.drop:
                self.dropped += 1
                continue
            out.append(op)
            if self.rng.random() < self.dup:
                out.append(op)
        if self.shuffle:
            self.rng.shuffle(out)
        return out

    def ack(self) -> bool:
        return self.rng.random() >= self.lose_ack


class Replica:
    """One device: its clock, its copy of the log, what it still owes its peers."""

    def __init__(self, node: str, physical: Callable[[], int]) -> None:
        self.node = node
        self.clock = Clock(node, physical)
        self.store = OpStore(physical)
        self.outbox: list[Op] = []
        self.cursors: dict[str, int] = {}

    def emit(self, order_id: str, kind: str, **data: object) -> Op:
        op = Op(
            op_id=str(uuid4()),
            order_id=order_id,
            hlc=self.clock.now(),
            device=self.node,
            kind=kind,
            data=dict(data),
        )
        self.store.append([op])
        self.outbox.append(op)
        return op

    def receive(self, ops: Iterable[Op]) -> list[Op]:
        accepted = self.store.append(ops)
        for op in accepted:
            self.clock.observe(op.hlc)
        return accepted

    def push(self, peer: Replica, channel: Channel) -> None:
        """Send the outbox; a lost ack just means the same ops are sent again later."""
        delivered = channel.transmit(list(self.outbox))
        peer.receive(delivered)
        if channel.ack():
            got = {op.op_id for op in delivered}
            self.outbox = [op for op in self.outbox if op.op_id not in got]

    def pull(self, peer: Replica, channel: Channel) -> None:
        """Fetch what the peer has past our cursor; the cursor moves only when everything arrived."""
        cursor = self.cursors.get(peer.node, 0)
        ops = peer.store.since(cursor)
        delivered = channel.transmit(ops)
        self.receive(delivered)
        if len({op.op_id for op in delivered}) == len(ops) and channel.ack():
            self.cursors[peer.node] = cursor + len(ops)


def converged(replicas: list[Replica]) -> bool:
    first = replicas[0]
    if any(r.store.op_ids() != first.store.op_ids() for r in replicas[1:]):
        return False
    for order_id in first.store.order_ids():
        want = first.store.state(order_id).snapshot()
        if any(r.store.state(order_id).snapshot() != want for r in replicas[1:]):
            return False
    return True


def random_action(rng: random.Random, replica: Replica, order_id: str, *, offline: bool = False) -> Op:
    """One plausible tap on `replica`; `offline` stamps it the way a terminal with no backend does (ADR 6)."""
    flag = {"offline": True} if offline else {}
    state = replica.store.state(order_id)
    live = [line_id for line_id, line in state.lines.items() if line.status == "active"]
    kinds = ["add_line"] * 4 + ["set_field"] * 2 + ["fire"]
    if live:
        kinds += ["set_line"] * 3 + ["void_line", "allergy"]
    if state.applied:
        kinds += ["close", "reopen", "void_order"] if rng.random() < 0.08 else ["close"]
    else:
        kinds = ["create"]
    kind = rng.choice(kinds)
    if kind == "create":
        return replica.emit(order_id, kind, table=rng.randint(1, 30), guests=rng.randint(1, 8), **flag)
    if kind == "set_field":
        name = rng.choice(["table", "guests", "note", "server", "split"])
        value: Any = rng.randint(1, 30) if name in ("table", "guests") else f"{name}-{rng.randint(1, 9)}"
        if name == "split":  # the table pays on several checks, or on one again
            value = rng.choice([None, {"by": "seat"}, {"by": "dish"}, {"by": "even", "ways": rng.randint(2, 4)}])
        return replica.emit(order_id, kind, **{name: value}, **flag)
    if kind == "add_line":
        return replica.emit(
            order_id,
            kind,
            line_id=f"L{rng.randint(1, 12)}",
            item=rng.choice(ITEMS),
            qty=rng.randint(1, 3),
            seat=rng.randint(1, 4),
            course=rng.choice(COURSES),
            **flag,
        )
    if kind == "set_line":
        name = rng.choice(["qty", "seat", "note", "course", "rank", "checks"])
        if name == "checks":  # moved to another check of a split table, shared between some, or put back
            value = rng.choice([None, [rng.randint(1, 4)], rng.sample(range(1, 5), 2)])
        elif name == "note":
            value = rng.choice(["extra spicy", "no MSG", ""])
        elif name == "course":
            value = rng.choice(COURSES)
        elif name == "rank":  # a drag on the check
            value = round(rng.uniform(0, 10), 2)
        else:
            value = rng.randint(1, 5)
        return replica.emit(order_id, kind, line_id=rng.choice(live), **{name: value}, **flag)
    if kind == "void_line":
        return replica.emit(order_id, kind, line_id=rng.choice(live), reason="guest changed mind", **flag)
    if kind == "fire":
        return replica.emit(order_id, kind, course=rng.choice(COURSES + ["*"]), **flag)
    if kind == "allergy":  # told for a seat or the table, changed, or taken off again
        allergens = rng.sample(ALLERGENS, rng.randint(0, 2))
        return replica.emit(order_id, kind, seat=rng.choice([None, 1, 2, 3]), allergens=allergens, **flag)
    return replica.emit(order_id, kind, **flag)


@dataclass
class Report:
    replicas: int
    rounds: int
    ops: int
    dropped: int
    converged: bool

    def __str__(self) -> str:
        return (
            f"{self.replicas} replicas, {self.rounds} rounds, {self.ops} ops, "
            f"{self.dropped} messages dropped, converged: {'yes' if self.converged else 'NO'}"
        )


def run(
    seed: int = 0,
    replicas: int = 3,
    rounds: int = 200,
    drop: float = 0.3,
    dup: float = 0.1,
    lose_ack: float = 0.1,
    skew_ms: int = 120_000,
    orders: int = 3,
) -> Report:
    rng = random.Random(seed)
    sim = SimTime()
    nodes = [Replica("hub", sim.skewed(0))]
    nodes += [Replica(f"t{i}", sim.skewed(rng.randint(-skew_ms, skew_ms))) for i in range(1, replicas)]
    hub, terminals = nodes[0], nodes[1:]
    order_ids = [f"o{j}" for j in range(orders)]
    lossy = Channel(rng, drop=drop, dup=dup, shuffle=True, lose_ack=lose_ack)

    for _ in range(rounds):
        random_action(rng, rng.choice(nodes), rng.choice(order_ids))
        if rng.random() < 0.5:
            terminal = rng.choice(terminals)
            terminal.push(hub, lossy) if rng.random() < 0.5 else terminal.pull(hub, lossy)

    clean = Channel(rng)
    for _ in range(3):
        for terminal in terminals:
            terminal.push(hub, clean)
        for terminal in terminals:
            terminal.pull(hub, clean)

    return Report(
        replicas=replicas,
        rounds=rounds,
        ops=len(hub.store),
        dropped=lossy.dropped,
        converged=converged(nodes),
    )


@dataclass
class OutageReport:
    replicas: int
    captured_orders: int
    captured_ops: int
    flagged: int  # ops the hub received carrying the offline flag
    matched: bool  # every captured order replays on the hub exactly as its terminal saw it
    converged: bool

    @property
    def ok(self) -> bool:
        return self.matched and self.converged

    def __str__(self) -> str:
        return (
            f"{self.replicas} replicas, backends dead mid-service: {self.captured_ops} ops on "
            f"{self.captured_orders} orders captured offline ({self.flagged} flagged), "
            f"orders match: {'yes' if self.matched else 'NO'}, converged: {'yes' if self.converged else 'NO'}"
        )


def run_outage(
    seed: int = 0,
    replicas: int = 3,
    rounds: int = 200,
    outage_rounds: int = 60,
    drop: float = 0.3,
    dup: float = 0.1,
    lose_ack: float = 0.1,
    skew_ms: int = 120_000,
    orders: int = 3,
) -> OutageReport:
    """ADR 6: every backend dies in the middle of service. Each terminal keeps taking orders on its own
    (capture-only mode: new orders on its own tables, flagged `offline`, nothing shared), then the hub comes
    back and the queues drain. Every order a terminal captured must come out of the hub's replay exactly as
    the terminal saw it when the lights came back, and every replica must agree afterwards."""
    rng = random.Random(seed)
    sim = SimTime()
    nodes = [Replica("hub", sim.skewed(0))]
    nodes += [Replica(f"t{i}", sim.skewed(rng.randint(-skew_ms, skew_ms))) for i in range(1, replicas)]
    hub, terminals = nodes[0], nodes[1:]
    shared = [f"o{j}" for j in range(orders)]
    lossy = Channel(rng, drop=drop, dup=dup, shuffle=True, lose_ack=lose_ack)

    # Normal service: everybody edits the shared orders over a lossy network.
    for _ in range(rounds):
        random_action(rng, rng.choice(nodes), rng.choice(shared))
        if rng.random() < 0.5:
            terminal = rng.choice(terminals)
            terminal.push(hub, lossy) if rng.random() < 0.5 else terminal.pull(hub, lossy)

    # The outage: no pushes, no pulls. Each terminal rings its own new tables and keeps editing them.
    captured: dict[str, list[str]] = {t.node: [] for t in terminals}
    captured_ops = 0
    for _ in range(outage_rounds):
        terminal = rng.choice(terminals)
        mine = captured[terminal.node]
        if not mine or rng.random() < 0.3:
            mine.append(f"{terminal.node}-table{len(mine) + 1}")
        random_action(rng, terminal, rng.choice(mine), offline=True)
        captured_ops += 1
    seen_by_terminal = {
        order_id: terminal.store.state(order_id).snapshot()
        for terminal in terminals
        for order_id in captured[terminal.node]
    }

    # The hub returns: the queues drain and everyone catches up.
    clean = Channel(rng)
    for _ in range(3):
        for terminal in terminals:
            terminal.push(hub, clean)
        for terminal in terminals:
            terminal.pull(hub, clean)

    matched = all(hub.store.state(order_id).snapshot() == seen for order_id, seen in seen_by_terminal.items())
    flagged = sum(1 for op in hub.store.since(0) if op.data.get("offline"))
    return OutageReport(
        replicas=replicas,
        captured_orders=len(seen_by_terminal),
        captured_ops=captured_ops,
        flagged=flagged,
        matched=matched,
        converged=converged(nodes),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--replicas", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=200)
    parser.add_argument("--drop", type=float, default=0.3)
    parser.add_argument("--dup", type=float, default=0.1)
    parser.add_argument("--lose-ack", type=float, default=0.1)
    parser.add_argument("--skew-ms", type=int, default=120_000)
    parser.add_argument(
        "--outage", action="store_true", help="kill every backend mid-service, capture orders, bring it back"
    )
    args = parser.parse_args()
    common = {
        "seed": args.seed,
        "replicas": args.replicas,
        "rounds": args.rounds,
        "drop": args.drop,
        "dup": args.dup,
        "lose_ack": args.lose_ack,
        "skew_ms": args.skew_ms,
    }
    if args.outage:
        outage = run_outage(**common)
        print(outage)
        raise SystemExit(0 if outage.ok else 1)
    report = run(**common)
    print(report)
    raise SystemExit(0 if report.converged else 1)


if __name__ == "__main__":
    main()
