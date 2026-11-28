"""The guest display (docs/guest-display.md): a screen turned to the customer shows the order open on the
screen it is linked to, as the bill would say it. A screen says which order it has open; the hub turns that
order into what a guest may read; a screen that falls silent has nothing open."""

from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from pos.api.app import create_app
from pos.check_guests import guest_of
from pos.devices import DevicesSeen
from pos.guest_display import QUIET_MS, Showing, greeting_name, guest_view, host_view, tips_of
from pos.orders.adjustments import default_rules
from pos.orders.check import check_for
from pos.printing.bill import bill_for
from pos.printing.service import PrintService
from pos.settings import DEFAULTS, SettingStore, clean_guest_display
from pos.sync.oplog import OpStore, replay
from pos.tax import massachusetts

from .conftest import T0, make_op
from .orders.test_adjustments import DUCK, TEA, adj
from .printing.test_stations import manager

AT = datetime(2026, 11, 28, 18, 30)
SHRIMP = {
    "unit_price": "24.95",
    "tax_class": "prepared_food",
    "name": "General Gao's Chicken (Qt)",
    "modifiers": [
        {"label": "Brown rice", "price": "1.00"},
        {"label": "Spicy mayo", "price": "0", "depth": 1},
    ],
}


def to_go(*more, name: str = "Linda Chen"):
    return [
        make_op(
            "create",
            at=0,
            order_type="takeout",
            channel="counter",
            order_no=7,
            customer_name=name,
            phone="617-555-0142",
            server="Amy",
        ),
        make_op("add_line", at=1, line_id="L1", item="Tea", qty=2, priced=TEA),
        make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
        *more,
    ]


def view_of(ops):
    state = replay(list(ops), "o1")
    check = check_for(state, massachusetts(), default_rules())
    return guest_view(bill_for(check, state.fields, head=("China Sky",), at=AT), state.fields, state.status)


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now

    def pass_ms(self, ms: int) -> None:
        self.now += ms / 1000


def hub(*orders, settings: SettingStore | None = None, location: str | None = None):
    """A hub with these orders in its log, and the clock its screens are heard on."""
    store = OpStore(physical=lambda: T0 + 100)
    for ops in orders:
        store.append(ops)
    clock = Clock()
    devices = DevicesSeen(clock=clock)
    app = create_app(
        store,
        taxes=massachusetts(),
        pricing=default_rules(),
        printing=PrintService([]),
        devices=devices,
        showing=Showing(devices.last_heard, clock=clock),
        settings=settings,
        location=location,
    )
    return TestClient(app), clock


def says(c: TestClient, device: str, order_id: str | None):
    return c.post("/guest-display/showing", json={"device": device, "order_id": order_id})


def shown(c: TestClient, of: str = "mac1") -> dict:
    answer = c.get("/guest-display", params={"of": of})
    assert answer.status_code == 200
    return answer.json()


# What a guest reads ------------------------------------------------------------------------------------------


def test_a_guest_reads_the_bill_and_no_more():
    view = view_of(to_go())
    assert view["where"] == "Order #7"
    assert view["detail"] == "Linda"  # the first name alone, as on the pickup board
    assert [(line["qty"], line["name"], line["amount"]) for line in view["lines"]] == [
        (2, "Tea", "20.00"),
        (1, "Duck", "20.00"),
    ]
    assert view["sums"] == [
        {"label": "Subtotal", "amount": "40.00"},
        {"label": "Sales tax 7%", "amount": "2.80"},  # one line, as on the bill: 6.25% and 0.75%
    ]
    assert view["total"] == "42.80"
    assert view["paid"] == [] and view["due"] is None and view["paid_in_full"] is False
    # nothing of who took the order, the customer's family name or their number
    said = repr(view)
    for hidden in ("Amy", "Chen", "617", "Server", "counter"):
        assert hidden not in said, hidden


def test_a_choice_stands_under_its_dish_and_a_comp_is_said_and_taken_off():
    view = view_of(
        [
            make_op("create", at=0, table="5", guests=2, server="Amy", order_type="dine_in"),
            make_op("add_line", at=1, line_id="L1", item="GTC", qty=2, priced=SHRIMP),
            make_op("add_line", at=2, line_id="L2", item="Duck", qty=1, priced=DUCK),
            adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L2", applied_by="Amy"),
        ]
    )
    assert (view["where"], view["detail"]) == ("Table 5", "")
    gao, duck = view["lines"]
    assert gao["amount"] == "49.90"  # the dish with its choices, twice; the choices are said in words
    assert gao["notes"] == [{"text": "Brown rice +2.00", "depth": 0}, {"text": "Spicy mayo", "depth": 1}]
    assert duck["notes"] == [{"text": "Manager comp -20.00", "depth": 0}]
    assert {"label": "Manager comp, Duck", "amount": "-20.00"} in view["sums"]
    assert "Amy" not in repr(view)  # who approved it is the house's to know


def test_what_was_paid_and_the_change_are_on_it():
    part = adj("pay", 5, payment_id="P1", method="cash", amount="20.00", tendered="50.00")
    view = view_of(to_go(part))
    assert view["paid"] == [
        {"label": "Paid cash", "amount": "-20.00"},
        {"label": "50.00 handed over, 30.00 change", "amount": ""},
    ]
    assert (view["due"], view["paid_in_full"]) == ("22.80", False)
    rest = adj("pay", 6, payment_id="P2", method="card", amount="22.80")
    view = view_of(to_go(part, rest))
    assert (view["due"], view["paid_in_full"]) == ("0.00", True)


def test_a_tax_exempt_check_says_so_and_not_for_whom():
    exempt = make_op(
        "set_field",
        at=5,
        tax_exempt={
            "organisation": "Winchester Hospital",
            "certificate": "E-123456789",
            "approved_by": {"staff_id": "s3", "name": "Mike"},
        },
    )
    view = view_of(to_go(exempt))
    assert view["sums"][-1] == {"label": "Tax exempt", "amount": "0.00"}
    assert view["total"] == "40.00"
    for hidden in ("Hospital", "E-123456789", "Mike"):
        assert hidden not in repr(view), hidden


def test_nothing_to_show_of_an_order_with_no_dish_or_a_voided_one():
    assert view_of(to_go()[:1]) is None  # opened, nothing rung in yet
    assert view_of(to_go(make_op("void_line", at=3, line_id="L1"), make_op("void_line", at=4, line_id="L2"))) is None
    assert view_of(to_go(make_op("void_order", at=3))) is None


def test_a_bar_tab_is_called_by_a_first_name():
    view = view_of(
        [
            make_op("create", at=0, order_type="dine_in", tab=True, customer_name="Priya Raman"),
            make_op("add_line", at=1, line_id="L1", item="Tea", qty=1, priced=TEA),
        ]
    )
    assert (view["where"], view["detail"]) == ("Bar tab", "Priya")


# Which order a screen has open -------------------------------------------------------------------------------


def test_a_screen_says_what_it_has_open_and_a_silent_one_has_nothing():
    clock = Clock()
    devices = DevicesSeen(clock=clock)
    showing = Showing(devices.last_heard, clock=clock)
    assert showing.of("mac1") is None
    assert showing.say("mac1", "o1") is True
    assert showing.say("mac1", "o1") is False  # said again: no news
    assert showing.of("MAC1") == "o1"  # a screen is the same screen whatever the case
    assert showing.say("Mac1", "o2") is True and showing.of("mac1") == "o2"
    assert showing.of("mac2") is None
    # it is still there while the hub hears from it, however long the order stays open
    for _ in range(10):
        clock.pass_ms(15_000)
        devices.heard("mac1")
    assert showing.of("mac1") == "o2"
    # its app was closed with the order open: after a minute of silence it has nothing open
    clock.pass_ms(QUIET_MS)
    assert showing.of("mac1") == "o2"
    clock.pass_ms(1)
    assert showing.of("mac1") is None and showing.known("mac1") is False
    # it is back and never said otherwise: the order is still open on it
    devices.heard("mac1")
    assert showing.of("mac1") == "o2" and showing.known("mac1") is True
    # it left the order
    assert showing.left("mac1") == "o1"  # the one it had open before o2
    assert showing.say("mac1", None) is True
    assert showing.say("mac1", None) is False
    assert showing.of("mac1") is None
    assert showing.left("MAC1") == "o2" and showing.left("mac2") is None
    assert showing.say(" ", "o1") is False  # not a name


def test_with_nobody_keeping_track_of_the_screens_a_word_stands():
    clock = Clock()
    showing = Showing(clock=clock)
    showing.say("mac1", "o1")
    clock.pass_ms(10 * QUIET_MS)
    assert showing.of("mac1") == "o1" and showing.known("mac1") is False


# On the wire -------------------------------------------------------------------------------------------------


def test_the_display_shows_the_order_open_on_its_screen():
    c, _ = hub(to_go(), location="China Sky")
    # nothing open on the screen it is linked to: the restaurant's name to greet with, and no order
    assert shown(c) == {
        "of": "mac1",
        "known": False,
        "head": ["China Sky"],
        "showing": None,
        "order": None,
        "guest": None,
        "left": None,
    }
    assert says(c, "mac1", "o1").json() == {"device": "mac1", "order_id": "o1"}
    answer = shown(c)
    assert answer["known"] is True and answer["showing"] == "o1"
    assert answer["order"]["where"] == "Order #7" and answer["order"]["total"] == "42.80"
    # another screen's display is not shown it
    assert shown(c, "mac2")["order"] is None
    # a dish more on the order: the next read has it, and the total with it
    c.app.state.store.append([make_op("add_line", at=9, line_id="L3", item="Tea", qty=1, priced=TEA)])
    answer = shown(c)
    assert [line["name"] for line in answer["order"]["lines"]] == ["Tea", "Duck", "Tea"]
    assert answer["order"]["total"] == "53.51"  # each part of the tax rounded by itself, as on the check
    # the screen leaves the order
    says(c, "mac1", None)
    answer = shown(c)
    assert answer["order"] is None and answer["showing"] is None
    assert answer["left"] == {"order_id": "o1", "paid_in_full": False, "name": "Linda"}


def test_an_order_paid_and_left_in_one_tap_is_still_thanked_for():
    c, _ = hub(to_go())
    says(c, "mac1", "o1")
    assert shown(c)["order"]["paid_in_full"] is False
    # the payment and the leaving reach the hub together: the display's next read finds the order gone
    c.app.state.store.append([adj("pay", 5, payment_id="P1", method="card", amount="42.80")])
    says(c, "mac1", None)
    answer = shown(c)
    assert answer["order"] is None
    assert answer["left"] == {"order_id": "o1", "paid_in_full": True, "name": "Linda"}  # thanked by name
    # the next order is opened: the one left is still the one before it
    says(c, "mac1", "o-new")
    assert shown(c)["left"] == {"order_id": "o1", "paid_in_full": True, "name": "Linda"}
    # and when that one is left, it is the one left
    says(c, "mac1", None)
    assert shown(c)["left"] == {"order_id": "o-new", "paid_in_full": False, "name": ""}


def test_an_order_the_hub_has_not_been_sent_yet_is_named_and_not_shown():
    c, _ = hub()
    says(c, "mac1", "o-new")
    answer = shown(c)
    # the display knows which order to wait for: it reads again when the hub says that order changed
    assert answer["showing"] == "o-new" and answer["order"] is None


def test_the_answer_is_the_same_until_something_changes():
    c, _ = hub(to_go())
    says(c, "mac1", "o1")
    first = c.get("/guest-display", params={"of": "mac1"})
    again = c.get("/guest-display", params={"of": "mac1"}, headers={"If-None-Match": first.headers["etag"]})
    assert again.status_code == 304
    c.app.state.store.append([make_op("add_line", at=9, line_id="L3", item="Tea", qty=1, priced=TEA)])
    again = c.get("/guest-display", params={"of": "mac1"}, headers={"If-None-Match": first.headers["etag"]})
    assert again.status_code == 200


def test_a_screen_that_falls_silent_shows_nothing_to_the_guest():
    c, clock = hub(to_go())
    says(c, "mac1", "o1")
    clock.pass_ms(QUIET_MS + 1)
    answer = shown(c)
    assert answer["order"] is None and answer["known"] is False


def test_news_of_what_a_screen_shows_goes_out_on_the_feed():
    c, _ = hub(to_go())
    told: list[str] = []
    c.app.state.feed.changed = told.append
    says(c, "mac1", "o1")
    says(c, "mac1", "o1")  # the same again: nothing to tell
    says(c, "mac1", None)
    says(c, "mac2", None)  # it had none open: nothing to tell
    assert told == ["showing", "showing"]


def test_the_restaurants_own_lines_head_the_display():
    settings = SettingStore()
    settings.put("bill", {**settings.get("bill"), "header": ["China Sky", "Winchester"]})
    c, _ = hub(settings=settings, location="somewhere else")
    assert shown(c)["head"] == ["China Sky", "Winchester"]
    c, _ = hub()
    assert shown(c)["head"] == []  # no name was ever given: the display greets without one


def test_a_screen_with_no_name_is_refused():
    c, _ = hub()
    assert c.post("/guest-display/showing", json={"device": "", "order_id": "o1"}).status_code == 422
    assert c.get("/guest-display").status_code == 422


# The guest by name -------------------------------------------------------------------------------------------


def test_a_guest_is_called_by_the_first_name_or_by_the_title_they_gave():
    for typed, called in {
        "Linda Chen": "Linda",
        "linda chen": "Linda",  # typed in a hurry, or by the customer on the website
        "LINDA": "Linda",
        "DeShawn Carter": "DeShawn",  # typed with care: left as it is
        "Mr. Wong": "Mr. Wong",  # not "Mr."
        "mrs wong": "Mrs. Wong",
        "Dr Patel": "Dr. Patel",
        "Miss Li": "Miss Li",
        "Jean-Luc Picard": "Jean-Luc",
        "O'Brien": "O'Brien",
        "王小明": "王小明",
        "  Sam  ": "Sam",
        # what gets typed where a name goes when nobody gave one: better no name than a wrong one
        "": "",
        None: "",
        "Walk in": "",
        "walk-in": "",
        "Guest": "",
        "Table 5": "",
        "#12": "",
        "T5": "",
        "Mr.": "",
        "DoorDash": "",
    }.items():
        assert greeting_name(typed) == called, typed
    assert host_view("Linda Chen") == {"name": "Linda", "back": False}
    assert host_view("Linda Chen", back=True) == {"name": "Linda", "back": True}
    assert host_view("", back=True) == {"name": "", "back": True}  # known here, by a number with no name
    assert host_view("Walk in") is None and host_view(None) is None


LINDA = "6175550142"


def earlier(order_id: str = "o0", *, phone: str = "(617) 555-0142", at: int = -86_400_000):
    """An order the same number placed the day before."""
    return [
        make_op("create", order_id, at=at, order_type="takeout", channel="phone", order_no=3, phone=phone),
        make_op("add_line", order_id, at=at + 1, line_id="L1", item="Tea", qty=1, priced=TEA),
    ]


def test_the_display_greets_by_name_and_welcomes_back_a_number_that_ordered_before(monkeypatch):
    monkeypatch.setattr("pos.api.guest_display.BACK_KEPT_S", 0.0)
    c, _ = hub(to_go())
    says(c, "mac1", "o1")
    assert shown(c)["guest"] == {"name": "Linda", "back": False}  # her first order
    # the same number ordered yesterday, however it was typed then
    c.app.state.store.append(earlier())
    assert shown(c)["guest"] == {"name": "Linda", "back": True}
    # an order that was voided is no visit
    c.app.state.store.append([make_op("void_order", "o0", at=-86_000_000)])
    assert shown(c)["guest"] == {"name": "Linda", "back": False}
    # an order opened after this one does not make her a returning guest of this one
    c.app.state.store.append(earlier("o2", at=60_000))
    assert shown(c)["guest"] == {"name": "Linda", "back": False}
    # nothing of the number, the family name or anything a manager wrote about her
    said = repr(shown(c))
    assert "Chen" not in said and "617" not in said and "0142" not in said


def test_the_guest_is_greeted_before_the_first_dish_is_rung_in():
    c, _ = hub(
        [make_op("create", at=0, order_type="takeout", channel="counter", order_no=8, customer_name="sam o'neil")],
        earlier(phone="781 555 0000"),
    )
    says(c, "mac1", "o1")
    answer = shown(c)
    assert answer["order"] is None  # nothing to show of it yet
    assert answer["guest"] == {"name": "Sam", "back": False}  # no number on it: nobody to welcome back
    # an order that names nobody greets as it greets anyone
    c.app.state.store.append([make_op("set_field", at=5, customer_name="Walk in")])
    assert shown(c)["guest"] is None


def test_whether_a_number_was_here_before_is_kept_for_a_minute():
    c, _ = hub(to_go())
    says(c, "mac1", "o1")
    assert shown(c)["guest"]["back"] is False
    c.app.state.store.append(earlier())
    assert shown(c)["guest"]["back"] is False  # a display reads with every dish: the log is not searched each time


def test_at_a_table_the_guest_is_the_party_who_pays(monkeypatch):
    monkeypatch.setattr("pos.api.guest_display.BACK_KEPT_S", 0.0)
    table = [
        make_op("create", "t-1", at=0, table="12", guests=4, server="Amy", order_type="dine_in"),
        make_op("add_line", "t-1", at=1, line_id="L1", item="Duck", qty=1, priced=DUCK),
    ]
    c, _ = hub(table)
    says(c, "mac1", "t-1")
    assert shown(c)["guest"] is None  # nobody is named on the check
    guests = c.app.state.check_guests
    # the party of a reservation sat down on it: the table is theirs
    guests.put(guest_of("reservation", "b1", "t-1", LINDA, "Linda Papas", 1_000))
    assert shown(c)["guest"] == {"name": "Linda", "back": False}
    assert shown(c)["order"]["where"] == "Table 12"
    # she sat on another check last week
    guests.put(guest_of("waitlist", "p0", "t-0", LINDA, "Linda", 500))
    assert shown(c)["guest"] == {"name": "Linda", "back": True}
    # a second party joins the table: until somebody says who pays, no name is the right one
    guests.put(guest_of("waitlist", "p1", "t-1", "7815550199", "Omar", 2_000))
    assert shown(c)["guest"] is None
    guests.pay("waitlist", "p1", True, by="Amy")
    assert shown(c)["guest"] == {"name": "Omar", "back": False}


# Tip suggestions ---------------------------------------------------------------------------------------------

TIPS_ON = {"tips": True, "tip_percents": [18, 20, 25], "tip_base": "before_tax"}


def check_of(ops, order_id: str = "o1"):
    return check_for(replay(list(ops), order_id), massachusetts(), default_rules())


def test_no_tip_is_suggested_until_the_location_turns_it_on():
    assert DEFAULTS["guest_display"] == {"tips": False, "tip_percents": [18, 20, 25], "tip_base": "before_tax"}
    assert tips_of(check_of(to_go()), DEFAULTS["guest_display"]) is None
    assert view_of(to_go())["tips"] is None


def test_tips_are_percentages_of_the_food_and_drink_before_tax_or_of_the_total():
    check = check_of(to_go())  # 40.00 of food, 2.80 of tax
    assert tips_of(check, TIPS_ON) == {
        "base": "before_tax",
        "of": "40.00",
        "rows": [
            {"percent": 18, "amount": "7.20"},
            {"percent": 20, "amount": "8.00"},
            {"percent": 25, "amount": "10.00"},
        ],
    }
    assert tips_of(check, {**TIPS_ON, "tip_base": "after_tax", "tip_percents": [15]}) == {
        "base": "after_tax",
        "of": "42.80",
        "rows": [{"percent": 15, "amount": "6.42"}],
    }
    # what a comp or a discount took off is not tipped on
    comped = check_of(
        to_go(adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L2", applied_by="Amy"))
    )
    assert tips_of(comped, TIPS_ON)["of"] == "20.00"
    # to the cent, a half cent up
    odd = check_of([*to_go(), make_op("add_line", at=4, line_id="L3", item="Roll", qty=1, priced=ODD)])
    assert [row["amount"] for row in tips_of(odd, TIPS_ON)["rows"]] == ["7.49", "8.33", "10.41"]  # of 41.63


ODD = {"unit_price": "1.63", "tax_class": "prepared_food", "name": "Roll"}


def test_no_tip_is_suggested_on_a_check_that_carries_a_gratuity_or_has_nothing_on_it():
    party = [
        make_op("create", at=0, table="5", guests=6, server="Amy", order_type="dine_in"),
        make_op("add_line", at=1, line_id="L1", item="Duck", qty=6, priced=DUCK),
    ]
    check = check_of(party)
    assert any(charge["gratuity"] for charge in check["charges"])  # 18% for a party of six
    assert tips_of(check, TIPS_ON) is None  # nobody is asked twice
    assert tips_of(check_of(party[:1]), TIPS_ON) is None  # no dish
    everything_comped = check_of(
        [*party[:1], make_op("add_line", at=1, line_id="L1", item="Duck", qty=1, priced=DUCK)]
        + [adj("discount", 3, discount_id="D1", reason="comp", kind="comp", line_id="L1", applied_by="Amy")]
    )
    assert tips_of(everything_comped, TIPS_ON) is None


def test_the_tips_go_when_the_check_is_paid_in_full():
    def view(*more):
        state = replay(list(to_go(*more)), "o1")
        check = check_for(state, massachusetts(), default_rules())
        bill = bill_for(check, state.fields, head=("China Sky",), at=AT)
        return guest_view(bill, state.fields, state.status, tips=tips_of(check, TIPS_ON))

    assert view()["tips"]["of"] == "40.00"
    part = view(adj("pay", 5, payment_id="P1", method="cash", amount="20.00"))
    assert part["tips"]["of"] == "40.00" and part["due"] == "22.80"  # still of the whole check
    assert view(adj("pay", 5, payment_id="P1", method="card", amount="42.80"))["tips"] is None


def test_the_setting_is_checked():
    assert clean_guest_display({}) == DEFAULTS["guest_display"]
    assert clean_guest_display({"tips": True, "tip_percents": [22, 18], "tip_base": "after_tax"}) == {
        "tips": True,
        "tip_percents": [18, 22],  # lowest first, however they were typed
        "tip_base": "after_tax",
    }
    for bad in (
        {"tips": "yes"},
        {"tip_percents": []},
        {"tip_percents": [10, 15, 18, 20]},
        {"tip_percents": [18, 18]},
        {"tip_percents": [0]},
        {"tip_percents": [101]},
        {"tip_percents": [17.5]},
        {"tip_percents": [True]},
        {"tip_percents": "18"},
        {"tip_base": "pretax"},
    ):
        try:
            clean_guest_display(bad)
        except ValueError:
            continue
        raise AssertionError(f"{bad} was let through")


def test_a_manager_turns_tip_suggestions_on_and_every_display_follows():
    c, _ = hub(to_go())
    says(c, "mac1", "o1")
    assert c.get("/settings/guest_display").json() == DEFAULTS["guest_display"]
    assert shown(c)["order"]["tips"] is None
    assert c.put("/settings/guest_display", json={"tips": True}).status_code == 401
    boss = manager(c)
    told = []
    c.app.state.feed.changed = told.append
    saved = c.put("/settings/guest_display", json={"tips": True}, headers=boss)
    assert saved.json() == {"tips": True, "tip_percents": [18, 20, 25], "tip_base": "before_tax"}
    assert told == ["settings"]  # a display reads again when the settings change
    assert [row["amount"] for row in shown(c)["order"]["tips"]["rows"]] == ["7.20", "8.00", "10.00"]
    # one thing changed, the rest as it was
    assert c.put("/settings/guest_display", json={"tip_percents": [15, 20]}, headers=boss).json() == {
        "tips": True,
        "tip_percents": [15, 20],
        "tip_base": "before_tax",
    }
    assert [row["percent"] for row in shown(c)["order"]["tips"]["rows"]] == [15, 20]
    refused = c.put("/settings/guest_display", json={"tip_base": "the moon"}, headers=boss)
    assert refused.status_code == 422 and "tip_base" in refused.json()["detail"]["message"]
    assert c.put("/settings/guest_display", json={"tips": False}, headers=boss).json()["tips"] is False
    assert shown(c)["order"]["tips"] is None
