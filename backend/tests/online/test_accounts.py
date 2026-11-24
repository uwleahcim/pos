"""A restaurant with several accounts at GloriaFood (pos.online.accounts; docs/online-orders.md, "Several
accounts"): two websites and one it tests with. Every account is asked with its own key, an order keeps
which account brought it and says so where it shows, and an order of the account for testing says TEST."""

from __future__ import annotations

import httpx
import pytest

from pos.keys import HubKeys, UnknownKey, slot_for
from pos.online.accounts import MAIN, MOST, Account, account_of_slot, accounts_of, clean_accounts, new_id, slot_of
from pos.online.gloriafood import FetchFailed, GloriaFood, pushed_by
from pos.online.service import STALE_MS, OnlineOrders

from ..printing.fake_printer import decode
from .hub import MINUTE, NOW, FakeFood, Hub
from .orders import order, row

FIRST = Account(MAIN)
SUSHI = Account("s1", "Sushi site")
TESTING = Account("t1", "Testing", test=True)
MAIN_KEY, SUSHI_KEY, TEST_KEY = "made-up-key-of-the-first", "made-up-key-of-the-sushi-site", "made-up-key-to-test-with"
"""Nobody's keys."""
CHICKEN = ("Sweet & Sour Chicken", 2)
COMBO = ("Maki Combination",)


def three(**more) -> tuple[Hub, FakeFood, FakeFood, FakeFood]:
    """A hub of a restaurant with two websites and an account it tests with."""
    first, sushi, testing = FakeFood(MAIN, MAIN_KEY), FakeFood("s1", SUSHI_KEY), FakeFood("t1", TEST_KEY)
    hub = Hub(source=first, more=(sushi, testing), accounts=(FIRST, SUSHI, TESTING), **more)
    return hub, first, sushi, testing


def of_sushi(number: int, *rows, **more) -> dict:
    """An order placed on the second website: another restaurant to GloriaFood, with its own number and key."""
    about = {"restaurant_id": 2, "restaurant_name": "The Sushi Site", "restaurant_key": SUSHI_KEY}
    return order(number, [row(*r) for r in rows] or [row(*COMBO)], **{**about, **more})


def to_test(number: int, **more) -> dict:
    about = {"restaurant_id": 3, "restaurant_name": "Testing", "restaurant_key": TEST_KEY}
    return order(number, [row(*CHICKEN)], **{**about, **more})


def online_of(hub: Hub, number: int) -> dict:
    return hub.order(number)["fields"]["online"]


# --- what an account is ------------------------------------------------------------------------------------------


def test_the_first_account_is_always_there_and_the_others_are_named():
    assert accounts_of(None) == [FIRST] and accounts_of({"accounts": []}) == [FIRST]
    stored = clean_accounts({"accounts": [SUSHI.about(), {"id": MAIN, "name": " Main  site "}, TESTING.about()]})
    assert [a["id"] for a in stored["accounts"]] == [MAIN, "s1", "t1"], "the first account first"
    assert accounts_of(stored) == [Account(MAIN, "Main site"), SUSHI, TESTING]
    assert (slot_of(MAIN), slot_of("s1")) == ("online", "online:s1")
    assert (account_of_slot("online"), account_of_slot("online:s1")) == (MAIN, "s1")
    assert account_of_slot("online:main") is None and account_of_slot("maps") is None
    assert account_of_slot("online:S 1") is None
    assert new_id(["s1"]) not in ("s1", MAIN)


@pytest.mark.parametrize(
    ("rows", "problem"),
    [
        ([{"id": "s1", "name": ""}], "give the account a name"),
        ([SUSHI.about(), {"id": "s2", "name": "sushi SITE"}], "two accounts are named"),
        ([SUSHI.about(), SUSHI.about()], "the same id"),
        ([{"id": "Not An Id", "name": "x"}], "small letters and digits"),
        ([{"id": "s1", "name": "x" * 31}], "too long"),
        ([{"id": "s1", "name": "x", "test": "yes"}], "true or false"),
        ([{"id": f"a{n}", "name": f"Site {n}"} for n in range(MOST)], "is the most"),
    ],
)
def test_accounts_that_cannot_be_are_refused_in_words(rows, problem):
    with pytest.raises(ValueError, match=problem):
        clean_accounts({"accounts": rows})


def test_a_further_account_s_key_is_sealed_under_its_own_name_and_goes_with_the_account():
    keys = HubKeys(environ={"POS_GLORIAFOOD_KEY": MAIN_KEY})
    assert slot_for("online:s1") is not None and slot_for("online:main") is None and slot_for("nothing:s1") is None
    view = keys.set("online:s1", {"key": SUSHI_KEY}, by="Mike")
    assert (view["name"], view["set"], view["source"], view["ending"], view["by"]) == (
        "online:s1",
        True,
        "app",
        SUSHI_KEY[-4:],
        "Mike",
    )
    assert SUSHI_KEY not in str(view) and SUSHI_KEY.encode() not in keys.store.all()["online:s1"].sealed
    assert keys.data("online:s1") == {"key": SUSHI_KEY} and keys.data("online") == {"key": MAIN_KEY}
    assert [v["name"] for v in keys.views() if v["name"].startswith("online")] == [
        "online",
        "online_push",
        "online_tunnel",
    ], "as before: an account's key is no key of the hub's own"
    assert keys.environ()["POS_GLORIAFOOD_KEY"] == MAIN_KEY, "the hub's own file names the first account's"
    before = keys.mark()
    keys.forget("online:s1", by="Mike")
    assert keys.data("online:s1") is None and "online:s1" not in keys.store.all() and keys.mark() != before
    with pytest.raises(UnknownKey):
        keys.forget("online", by="Mike")  # the first account's key is removed, never forgotten
    with pytest.raises(ValueError, match="does not look like a key"):
        keys.set("online:s1", {"key": "no key"}, by="Mike")


def test_an_order_is_its_account_s_by_the_key_it_carries_and_the_key_goes_no_further():
    sushi = GloriaFood(SUSHI_KEY, account="s1")
    assert sushi.owns({"id": 1, "restaurant_key": SUSHI_KEY}) and sushi.owns({"restaurant_key": f" {SUSHI_KEY}\n"})
    assert not sushi.owns({"id": 1, "restaurant_key": MAIN_KEY}) and not sushi.owns({"id": 1})
    assert not sushi.owns({"restaurant_key": 7}) and not sushi.owns({"restaurant_key": ""})
    assert sushi.same_as(GloriaFood(SUSHI_KEY, account="s1"))
    assert not sushi.same_as(GloriaFood(SUSHI_KEY)) and not sushi.same_as(GloriaFood(MAIN_KEY, account="s1"))
    body = b'{"count": 2, "orders": [{"id": 1, "restaurant_key": "a", "restaurant_token": "t"}, {"id": 2}]}'
    seen = []

    def whose(told) -> str:
        seen.append(told.get("restaurant_key"))
        return "s1" if told.get("restaurant_key") == "a" else ""

    assert pushed_by(body, whose) == [("s1", {"id": 1}), ("", {"id": 2})]
    assert seen == ["a", None]


# --- asking ------------------------------------------------------------------------------------------------------


def test_every_account_is_asked_each_round_and_an_order_keeps_which_one_brought_it():
    hub, first, sushi, testing = three()
    first.queue.append(order(301, [row(*CHICKEN)]))
    sushi.queue.append(of_sushi(302))
    done = hub.online.round()
    assert (done["asked"], done["came"], done["placed"]) == (True, 2, 2)
    assert (first.asked, sushi.asked, testing.asked) == (1, 1, 1)
    assert (hub.inbox.get("gloriafood", "301").account, hub.inbox.get("gloriafood", "302").account) == (MAIN, "s1")
    # the order says which website it came from, where the restaurant named it
    assert online_of(hub, 301)["account"] == MAIN and "store" not in online_of(hub, 301)
    assert (online_of(hub, 302)["account"], online_of(hub, 302)["store"]) == ("s1", "Sushi site")
    assert "test" not in online_of(hub, 302)
    # and so do its papers, beside the channel
    assert "Online: Sushi site" in hub.paper("gf-302:fire:sushi") and "Online: Sushi site" in hub.paper(
        "gf-302:fire:front"
    )
    assert "Online" in hub.paper("gf-301:fire:wok") and "Online:" not in hub.paper("gf-301:fire:wok")
    status = hub.status()
    assert [(a["id"], a["name"], a["test"], a["configured"], a["came"]) for a in status["accounts"]] == [
        (MAIN, "", False, True, 1),
        ("s1", "Sushi site", False, True, 1),
        ("t1", "Testing", True, True, 0),
    ]
    assert all(a["answered_ms"] == NOW and a["last_failure"] is None for a in status["accounts"])
    assert (status["configured"], status["answered_ms"], status["today"]["came"]) == (True, NOW, 2)


def test_gloriafood_s_number_is_still_what_an_order_is_known_by_whichever_account_brings_it():
    hub, first, sushi, _ = three()
    sushi.queue.append(of_sushi(302))
    assert hub.online.round()["placed"] == 1
    first.queue.append(of_sushi(302))  # the same order, by whatever mistake, from another account
    done = hub.online.round()
    assert (done["came"], done["known"], done["placed"]) == (1, 1, 0)
    assert hub.inbox.get("gloriafood", "302").account == "s1", "the first stands"
    assert hub.status()["today"]["came"] == 1


def test_one_account_that_does_not_answer_is_told_of_by_name_and_the_others_bring_their_orders():
    hub, first, sushi, _ = three()
    sushi.fail = FetchFailed("GloriaFood refused the key")
    first.queue.append(order(301, [row(*CHICKEN)]))
    asked = hub.online.ask_now()
    assert (asked["placed"], asked["answered"], asked["reason"]) == (1, False, "Sushi site: GloriaFood refused the key")
    assert [(a["id"], a["answered"], a["reason"]) for a in asked["accounts"]] == [
        (MAIN, True, None),
        ("s1", False, "GloriaFood refused the key"),
        ("t1", True, None),
    ]
    status = hub.status()
    by_id = {a["id"]: a for a in status["accounts"]}
    assert by_id["s1"]["last_failure"] == {"at_ms": NOW, "reason": "GloriaFood refused the key"}
    assert by_id[MAIN]["last_failure"] is None and by_id[MAIN]["answered_ms"] == NOW
    assert status["last_failure"]["reason"] == "GloriaFood refused the key" and status["trouble"] == []
    hub.clock += STALE_MS
    hub.online.round()
    trouble = hub.status()["trouble"]
    assert [(t["code"], t["account"], t["store"], t["urgent"], t["since_ms"]) for t in trouble] == [
        ("not_answering", "s1", "Sushi site", True, NOW)
    ]
    sushi.fail = None
    hub.clock += MINUTE
    hub.online.round()
    assert hub.status()["trouble"] == [] and hub.status()["last_failure"] is None


def test_the_account_for_testing_alarms_nobody_when_it_does_not_answer():
    hub, _, _, testing = three()
    testing.fail = FetchFailed("GloriaFood refused the key")
    hub.online.round()
    hub.clock += STALE_MS
    hub.online.round()
    assert [(t["account"], t["test"], t["urgent"]) for t in hub.status()["trouble"]] == [("t1", True, False)]


def test_a_hub_with_one_account_says_of_its_trouble_what_it_always_said():
    hub = Hub()
    hub.food.fail = FetchFailed("GloriaFood did not answer in time")
    assert hub.online.ask_now()["reason"] == "GloriaFood did not answer in time"
    assert "accounts" not in hub.online.ask_now()
    hub.clock += STALE_MS
    hub.online.round()
    assert hub.status()["trouble"] == [
        {"code": "not_answering", "since_ms": NOW, "reason": "GloriaFood did not answer in time", "urgent": True}
    ]


def test_what_is_known_of_an_account_stays_when_another_account_s_key_changes():
    def answers(request: httpx.Request) -> httpx.Response:
        refused = request.headers["authorization"] == "a-wrong-key-for-the-sushi-site"
        return httpx.Response(403) if refused else httpx.Response(200, json={"count": 0, "orders": []})

    def food(key: str, account: str) -> GloriaFood:
        return GloriaFood(key, account=account, client=httpx.Client(transport=httpx.MockTransport(answers)))

    clock = [NOW]
    online = OnlineOrders(
        [food(MAIN_KEY, MAIN), food("a-wrong-key-for-the-sushi-site", "s1")],
        accounts=[FIRST, SUSHI],
        now=lambda: clock[0],
    )
    online.round()
    by_id = {a["id"]: a for a in online.status()["accounts"]}
    assert by_id[MAIN]["answered_ms"] == NOW and by_id["s1"]["last_failure"]["reason"] == "GloriaFood refused the key"
    clock[0] += MINUTE
    online.use([food(MAIN_KEY, MAIN), food(SUSHI_KEY, "s1")])  # the right key typed for the second
    by_id = {a["id"]: a for a in online.status()["accounts"]}
    assert by_id[MAIN]["answered_ms"] == NOW, "nothing of the first changed"
    assert (by_id["s1"]["asked_ms"], by_id["s1"]["answered_ms"], by_id["s1"]["last_failure"]) == (None, None, None)
    assert online.ask_now()["soon"] is False, "whoever asks now is served at once"
    assert all(a["answered_ms"] == clock[0] for a in online.status()["accounts"])
    online.use([food(MAIN_KEY, MAIN)], [FIRST])  # and the second account is taken away
    assert [a["id"] for a in online.status()["accounts"]] == [MAIN]


# --- a push ------------------------------------------------------------------------------------------------------


def test_a_pushed_order_is_put_to_the_account_whose_key_it_carries():
    hub, _, _, _ = three(push=True)
    assert hub.push(of_sushi(302)).status_code == 200
    arrival = hub.inbox.get("gloriafood", "302")
    assert (arrival.account, arrival.via, arrival.state) == ("s1", "push", "placed")
    assert "restaurant_key" not in arrival.raw and "restaurant_token" not in arrival.raw
    assert online_of(hub, 302)["store"] == "Sushi site"
    assert "Online: Sushi site" in hub.paper("gf-302:fire:front")
    by_id = {a["id"]: a for a in hub.status()["accounts"]}
    assert (by_id["s1"]["came"], by_id[MAIN]["came"]) == (1, 0)


def test_a_pushed_order_without_a_key_the_hub_knows_goes_by_gloriafood_s_number_for_the_restaurant():
    hub, _, sushi, _ = three(push=True)
    sushi.queue.append(of_sushi(302))  # asked for: this account's restaurant is number 2 at GloriaFood
    hub.online.round()
    assert hub.push(of_sushi(303, restaurant_key="a-key-the-hub-was-never-told")).status_code == 200
    assert hub.inbox.get("gloriafood", "303").account == "s1"
    # and after a restart, when nothing is remembered but what was written down
    again = Hub(inbox=hub.inbox, more=(FakeFood("s1", SUSHI_KEY),), accounts=(FIRST, SUSHI), push=True)
    assert again.push(of_sushi(304, restaurant_key="a-key-the-hub-was-never-told")).status_code == 200
    assert again.inbox.get("gloriafood", "304").account == "s1"


def test_a_pushed_order_no_account_can_be_told_for_is_taken_all_the_same_and_names_none():
    hub, _, _, _ = three(push=True)
    stranger = order(305, [row(*CHICKEN)], restaurant_id=9, restaurant_key="a-key-the-hub-was-never-told")
    assert hub.push(stranger).status_code == 200
    arrival = hub.inbox.get("gloriafood", "305")
    assert (arrival.account, arrival.state) == ("", "placed")
    assert "account" not in online_of(hub, 305) and "store" not in online_of(hub, 305)
    assert "Online:" not in hub.paper("gf-305:fire:front")


def test_an_order_pushed_with_no_account_learns_it_when_the_asking_brings_it_and_the_next_push_is_told():
    hub, _, _, testing = three(push=True)
    # the testing account's first order ever, pushed with a key the hub was never told: no account is named
    first = to_test(401, restaurant_key="a-key-the-hub-was-never-told")
    assert hub.push(first).status_code == 200
    assert hub.inbox.get("gloriafood", "401").account == ""
    # within the minute the asking brings it for the testing account: still one order, and now its account's
    testing.queue.append(to_test(401))
    done = hub.online.round()
    assert (done["came"], done["known"], done["placed"]) == (1, 1, 0)
    arrival = hub.inbox.get("gloriafood", "401")
    assert (arrival.account, arrival.via, arrival.state, arrival.order_id) == ("t1", "push", "placed", "gf-401")
    assert len(hub.inbox.since(0)) == 1
    # so the next one that is pushed the same way is a test order, also after a restart
    again = Hub(inbox=hub.inbox, more=(FakeFood("t1", TEST_KEY),), accounts=(FIRST, TESTING), push=True)
    assert again.push(to_test(402, restaurant_key="a-key-the-hub-was-never-told")).status_code == 200
    assert again.inbox.get("gloriafood", "402").account == "t1"
    assert online_of(again, 402)["test"] is True
    assert "TEST ORDER" in again.paper("gf-402:fire:front")


def test_on_a_hub_with_one_account_every_pushed_order_is_that_account_s():
    hub = Hub(push=True, accounts=(Account(MAIN, "Main site"),))
    assert hub.push(order(301, [row(*CHICKEN)])).status_code == 200
    assert hub.inbox.get("gloriafood", "301").account == MAIN
    assert online_of(hub, 301)["store"] == "Main site"


# --- the account for testing -------------------------------------------------------------------------------------


def test_an_order_from_the_account_for_testing_says_test_on_the_order_and_on_every_paper():
    hub, _, _, testing = three()
    testing.queue.append(to_test(401))
    assert hub.online.round()["placed"] == 1
    about = online_of(hub, 401)
    assert (about["account"], about["store"], about["test"]) == ("t1", "Testing", True)
    for paper in ("gf-401:fire:wok", "gf-401:fire:front"):
        assert "TEST ORDER" in hub.paper(paper) and "DO NOT MAKE" in hub.paper(paper)
    # it is an order like any other for the rest: numbered, on a check, sent
    got = hub.order(401)
    assert (got["status"], got["fields"]["order_no"], bool(got["fired"])) == ("open", 1, True)
    printed = hub.client.post("/orders/gf-401/pack-sheet")
    assert printed.status_code == 202, printed.text
    sheet = "\n".join(decode(hub.jobs.get(printed.json()["job_id"]).data).text)
    assert "PACK SHEET" in sheet and "TEST ORDER" in sheet and "DO NOT MAKE" in sheet and "Online: Testing" in sheet
    # the kitchen's screens say it too
    screen = hub.client.get("/kitchen/screen", params={"stations": "wok1"}).json()
    assert [(t["test"], t["store"]) for t in screen["tickets"]] == [(True, "Testing")]


def test_an_order_of_any_other_account_says_nothing_of_a_test():
    hub, first, sushi, _ = three()
    first.queue.append(order(301, [row(*CHICKEN)]))
    sushi.queue.append(of_sushi(302, CHICKEN))
    hub.online.round()
    for paper in ("gf-301:fire:wok", "gf-302:fire:wok"):
        assert "TEST" not in hub.paper(paper)
    screen = hub.client.get("/kitchen/screen", params={"stations": "wok1"}).json()
    assert [("test" in t, t.get("store")) for t in screen["tickets"]] == [(False, None), (False, "Sushi site")]


def test_the_ones_to_look_at_say_which_account_they_are_from():
    hub, _, sushi, testing = three()
    sushi.queue.append(of_sushi(302, items=[]))  # an order with no dishes cannot be put on
    testing.queue.append(order(402, [], restaurant_id=3))
    hub.online.round()
    look = {r["id"]: r for r in hub.status()["look"]}
    assert (look["302"]["account"], look["302"]["store"], "test" in look["302"]) == ("s1", "Sushi site", False)
    assert (look["402"]["store"], look["402"]["test"]) == ("Testing", True)
    assert any("Online order 302 (Sushi site)" in slip for slip in hub.slips())
    shown = hub.client.get("/online/orders/302").json()
    assert (shown["account"], shown["store"]) == ("s1", "Sushi site")


# --- the dishes of another website -------------------------------------------------------------------------------


def renumbered(told: dict) -> dict:
    """An order as the restaurant's second website sends it: the same dishes, sizes and choices under the
    numbers GloriaFood gave them there, which the menu on the POS has never seen."""
    rows = []
    for n, dish in enumerate(told["items"]):
        options = [{**o, "type_id": 880_000 + 10 * n + m} for m, o in enumerate(dish.get("options") or [])]
        rows.append({**dish, "type_id": 990_000 + n, "options": options})
    return {**told, "items": rows}


def test_a_dish_of_another_website_is_found_by_its_name_when_its_number_is_not_on_the_menu():
    hub, first, sushi, _ = three()
    first.queue.append(order(301, [row(*CHICKEN), row(*COMBO)]))
    sushi.queue.append(renumbered(of_sushi(302, CHICKEN, COMBO)))
    assert hub.online.round()["placed"] == 2
    here, there = hub.order(301), hub.order(302)

    def dishes(got: dict) -> list[tuple]:
        lines = got["lines"].values()
        return [(line["priced"]["item"], line["priced"]["variant_id"], line["qty"]) for line in lines]

    assert dishes(there) == dishes(here) and all(code for code, _, _ in dishes(there))
    assert not any((line["priced"].get("online") or {}).get("as_written") for line in there["lines"].values())
    assert hub.check(302)["total"] == hub.check(301)["total"]
    # so each is cooked where it always is
    assert sorted(job.split(":")[-1] for job in hub.papers() if job.startswith("gf-302:fire")) == [
        "front",
        "sushi",
        "wok",
    ]
    assert hub.status()["look"] == []


def test_a_dish_nobody_on_the_pos_is_called_goes_on_as_written_as_before():
    hub, _, sushi, _ = three()
    told = renumbered(of_sushi(302, CHICKEN))
    told["items"][0]["name"] = "Chef's Surprise Roll"
    sushi.queue.append(told)
    assert hub.online.round()["placed"] == 1
    line = next(iter(hub.order(302)["lines"].values()))
    assert line["priced"]["online"] == {"as_written": True} and line["priced"]["name"] == "Chef's Surprise Roll"
