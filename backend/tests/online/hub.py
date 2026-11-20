"""A hub for the online-order tests: the restaurant's own menu, three printers, a clock that is moved by
hand, and a GloriaFood that hands over what the test queued."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.gloriafood import load_restaurant_menu
from pos.menu.service import MenuService
from pos.online.gloriafood import NAME, FetchFailed
from pos.online.inbox import Inbox
from pos.online.service import OnlineOrders
from pos.orders.adjustments import PricingRules
from pos.orders.numbers import OrderNumbers
from pos.printing.jobs import JobStore
from pos.printing.service import Printer, PrintService
from pos.settings import SettingStore
from pos.sync.oplog import OpStore
from pos.tax import massachusetts

from ..printing.fake_printer import decode

NOW = int(datetime(2027, 1, 15, 23, 1, tzinfo=UTC).timestamp() * 1000)
"""A minute after the orders of `tests.online.orders` were accepted: 18:01 in Winchester, dinner."""
MINUTE = 60_000


class FakeFood:
    """GloriaFood as the hub sees it: `queue` is what was accepted since it was last asked."""

    name = NAME

    def __init__(self) -> None:
        self.queue: list[dict[str, Any]] = []
        self.asked = 0
        self.fail: FetchFailed | None = None

    def pop(self) -> list[dict[str, Any]]:
        self.asked += 1
        if self.fail is not None:
            raise self.fail
        out, self.queue = self.queue, []
        return out


class Hub:
    def __init__(
        self,
        *,
        source: FakeFood | None = None,
        inbox: Inbox | None = None,
        rules: PricingRules | None = None,
        key: bool = True,
        printers: bool = True,
    ) -> None:
        self.clock = NOW
        self.food = source if source is not None else FakeFood()
        self.inbox = inbox if inbox is not None else Inbox()
        self.store = OpStore(physical=lambda: self.clock)
        self.jobs = JobStore()
        stations = [
            Printer("wok", "w:9100", stations=("wok1", "wok2")),
            Printer("sushi", "s:9100", stations=("sushi",)),
            Printer("front", "f:9100", stations=("takeout",)),
        ]
        self.printing = PrintService(
            stations if printers else [], store=self.jobs, direct=False, now=lambda: self.clock
        )
        self.menu = MenuService(load_restaurant_menu()[0])
        self.online = OnlineOrders(self.food if key else None, self.inbox, now=lambda: self.clock)
        self.client = TestClient(
            create_app(
                self.store,
                menu=self.menu,
                taxes=massachusetts(),
                pricing=rules,
                printing=self.printing,
                numbers=OrderNumbers(self.store, today=lambda: localtime.day_of(self.clock)),
                today=lambda: localtime.day_of(self.clock),
                settings=SettingStore(),
                online=self.online,
                location="The Restaurant",
            )
        )

    def accept(self, *orders: dict[str, Any]) -> dict[str, Any]:
        """These orders were accepted in GloriaFood's app, and the hub's minute came round."""
        self.food.queue.extend(orders)
        return self.online.round()

    def order(self, number: int) -> dict[str, Any]:
        return self.client.get(f"/orders/gf-{number}").json()

    def check(self, number: int) -> dict[str, Any]:
        return self.client.get(f"/orders/gf-{number}/check").json()

    def status(self) -> dict[str, Any]:
        return self.client.get("/online/status").json()

    def manager(self) -> dict[str, str]:
        token = self.client.post("/admin/session", json={"device": "office", "pin": "9999"}).json()["token"]
        return {"authorization": f"Bearer {token}"}

    def slips(self) -> list[str]:
        """The slips for somebody to look at, each as one text (a long line is folded on the paper)."""
        return [" ".join(" ".join(text).split()) for job_id, text in self.papers().items() if ":notice:" in job_id]

    def papers(self) -> dict[str, list[str]]:
        """What is waiting at the printers, by job, as the lines a person reads."""
        return {job.job_id: decode(job.data).text for job in self.jobs.pending()}

    def paper(self, ending: str) -> str:
        """One paper, by the end of its job's name ("fire:front"), as one text."""
        found = [text for job_id, text in self.papers().items() if job_id.endswith(ending)]
        assert len(found) == 1, (ending, list(self.papers()))
        return "\n".join(found[0])
