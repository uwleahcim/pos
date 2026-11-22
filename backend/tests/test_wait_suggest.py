"""The suggested wait: what to tell the next party is worked out from how tonight's parties waited. Each place
in line took so long for the last parties that sat down, and so many are in line now; parties of about the
same size are counted together where enough of them have sat down, every size where not; a party ahead that
has waited longer already says the wait is at least theirs; and it is one of the waits the screens offer."""

from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from pos import localtime
from pos.api.app import create_app
from pos.menu.fixtures.example import build_example
from pos.menu.service import MenuService
from pos.printing.service import PrintService
from pos.sync.oplog import OpStore
from pos.waitlist import MOST_GUESTS, QUOTES, SIZE_BANDS, Party, Waitlist, suggestions

MINUTE = 60_000


def at(hour: int, minute: int = 0, *, day: int = 16) -> int:
    """A time on the restaurant's own clock in November 2026, in wall-clock milliseconds."""
    return int(datetime(2026, 11, day, hour, minute, tzinfo=localtime.zone()).timestamp() * 1000)


def party(
    name: str,
    size: int,
    came: int,
    *,
    sat: int | None = None,
    left: int | None = None,
    called: int | None = None,
) -> Party:
    return Party(
        name,
        name,
        size,
        at_ms=came,
        called_ms=called,
        seated_ms=sat,
        table="A1" if sat is not None else "",
        left_ms=left,
        left_why="left" if left is not None else "",
    )


def of(told: list[dict], size: int) -> dict | None:
    """The row for a party of `size`; None where nothing is suggested for it."""
    return next((row for row in told if row["from"] <= size <= row["to"]), None)


def test_the_bands_take_every_size_once():
    assert SIZE_BANDS[0][0] == 1 and SIZE_BANDS[-1][1] == MOST_GUESTS
    sizes = [size for low, high in SIZE_BANDS for size in range(low, high + 1)]
    assert sizes == list(range(1, MOST_GUESTS + 1))


def test_nothing_is_suggested_until_two_parties_have_sat_down():
    now = at(18, 30)
    assert suggestions([], now) == []
    waiting = [party("a", 4, at(18)), party("b", 2, at(18, 5))]
    assert suggestions(waiting, now) == []  # nobody has sat down: there is nothing to go by
    one = [party("a", 4, at(18), sat=at(18, 10)), party("b", 2, at(18, 5))]
    assert suggestions(one, now) == []
    two = [party("a", 4, at(18), sat=at(18, 10)), party("b", 2, at(18, 5), sat=at(18, 20))]
    told = suggestions(two, now)
    assert [(row["from"], row["to"]) for row in told] == list(SIZE_BANDS)
    assert all(row["like"] is False and row["seated"] == 2 for row in told)


def test_a_place_in_line_is_worth_what_it_took_the_parties_that_sat_down():
    # a came to an empty list and sat after 6 minutes: one place took 6. b came with a ahead and sat after
    # 10: two places took 10. Together three places took 16 minutes, a little over 5 each.
    parties = [
        party("a", 2, at(18), sat=at(18, 6)),
        party("b", 2, at(18, 2), sat=at(18, 12)),
        party("c", 2, at(18, 10)),
        party("d", 2, at(18, 12)),
        party("e", 2, at(18, 14)),
    ]
    told = suggestions(parties, at(18, 15))
    row = of(told, 2)
    assert row is not None
    assert row["by"] == "pace" and row["ahead"] == 3 and row["each_minutes"] == 5 and row["seated"] == 2
    assert row["about_minutes"] == 22  # four places at 16/3 minutes each, to the minute above
    assert row["minutes"] == 30  # the first wait on offer that is not under it
    assert row["longest_minutes"] == 5
    # the order the parties are handed over in does not matter: it is the order they came in that counts
    assert suggestions(parties[::-1], at(18, 15)) == told


def test_parties_of_a_size_are_counted_on_their_own_once_three_have_sat_down():
    # the twos sit quickly, the fours slowly
    parties = [
        party("two a", 2, at(18), sat=at(18, 3)),
        party("four a", 4, at(18, 1), sat=at(18, 21)),
        party("two b", 2, at(18, 2), sat=at(18, 6)),
        party("two c", 1, at(18, 4), sat=at(18, 8)),
        party("four b", 3, at(18, 5), sat=at(18, 45)),
        party("four c", 4, at(18, 30)),
    ]
    told = suggestions(parties, at(18, 50))
    twos, fours, sixes = of(told, 2), of(told, 4), of(told, 6)
    assert twos is not None and fours is not None and sixes is not None
    # three twos sat down: a came first (1 place, 3 min), b with a ahead (2 places, 4 min), c with a gone and
    # b ahead (2 places, 4 min): 11 minutes for 5 places. Nobody of two waits: one place, 3 minutes at most.
    assert twos["like"] is True and twos["seated"] == 3 and twos["ahead"] == 0 and twos["longest_minutes"] is None
    assert twos["about_minutes"] == 3 and twos["minutes"] == 5 and twos["each_minutes"] == 2
    # two fours sat down, short of three: every size is counted for a six, the one ahead too. The five that
    # sat down waited 71 minutes for 13 places, and two places are some 11 minutes.
    assert sixes["like"] is False and sixes["seated"] == 5 and sixes["ahead"] == 1 and sixes["each_minutes"] == 5
    assert sixes["by"] == "pace" and sixes["about_minutes"] == 11 and sixes["minutes"] == 15
    assert sixes["longest_minutes"] is None  # nobody of six waits
    # the same for a four, but a four ahead has waited 20 minutes already
    assert fours["like"] is False and fours["seated"] == 5 and fours["ahead"] == 1
    assert fours["by"] == "longest" and fours["longest_minutes"] == 20 and fours["minutes"] == 20
    # a third four sits down and the fours go by their own, slower, pace
    parties[-1] = party("four c", 4, at(18, 30), sat=at(18, 55))
    fours = of(suggestions(parties, at(18, 56)), 3)
    assert fours is not None and fours["like"] is True and fours["seated"] == 3 and fours["ahead"] == 0
    # 20 minutes for 1 place, 40 for 2, 25 for 2: 85 minutes for 5 places
    assert fours["about_minutes"] == 17 and fours["minutes"] == 20


def test_a_party_told_its_table_is_ready_is_not_in_line():
    parties = [
        party("a", 2, at(18), sat=at(18, 10)),
        party("b", 2, at(18, 1), sat=at(18, 12), called=at(18, 2)),  # called before c came: not ahead of c
        party("c", 2, at(18, 5), sat=at(18, 15)),
        party("d", 2, at(18, 20), called=at(18, 24)),  # table ready: not ahead of who comes now
        party("e", 2, at(18, 22)),
    ]
    row = of(suggestions(parties, at(18, 25)), 2)
    assert row is not None and row["like"] is True
    assert row["ahead"] == 1 and row["longest_minutes"] == 3
    # a: 1 place, 10 min. b: a ahead, 2 places, 11 min. c: a ahead (b was called), 2 places, 10 min.
    # 31 minutes for 5 places; two places now
    assert row["about_minutes"] == 13 and row["minutes"] == 15


def test_a_party_that_left_stood_in_line_while_it_was_there_and_is_no_wait_to_count():
    parties = [
        party("gone", 4, at(18), left=at(18, 20)),
        party("a", 4, at(18, 5), sat=at(18, 15)),  # gone was ahead: 2 places, 10 min
        party("b", 4, at(18, 25), sat=at(18, 30)),  # gone had left: 1 place, 5 min
    ]
    told = suggestions(parties, at(18, 31))
    row = of(told, 4)
    assert row is not None and row["seated"] == 2 and row["ahead"] == 0
    assert row["each_minutes"] == 5 and row["about_minutes"] == 5 and row["minutes"] == 5


def test_a_party_ahead_that_has_waited_longer_says_the_wait_is_at_least_theirs():
    parties = [
        party("a", 4, at(18), sat=at(18, 4)),
        party("b", 4, at(18, 1), sat=at(18, 7)),
        party("c", 3, at(18, 2), sat=at(18, 9)),
        party("slow", 4, at(18, 10)),
    ]
    row = of(suggestions(parties, at(18, 51)), 4)
    assert row is not None and row["like"] is True and row["ahead"] == 1
    # by the pace two places would take some 7 minutes; the one ahead has waited 41 already
    assert row["by"] == "longest" and row["longest_minutes"] == 41
    assert row["about_minutes"] == 41 and row["minutes"] == 45
    # a wait that is one of the waits on offer is that wait
    row = of(suggestions(parties, at(18, 55)), 4)
    assert row is not None and row["about_minutes"] == 45 and row["minutes"] == 45


def test_a_large_party_that_waits_long_says_nothing_of_a_table_for_two():
    parties = [
        party("eight", 8, at(17, 30)),  # the one large table will not come
        party("a", 2, at(18), sat=at(18, 4)),
        party("b", 4, at(18, 1), sat=at(18, 9)),
        party("c", 2, at(18, 20)),
    ]
    told = suggestions(parties, at(18, 30))
    twos, large = of(told, 2), of(told, 8)
    assert twos is not None and large is not None and twos["like"] is False and large["like"] is False
    # for two: the eight and c are ahead, counted by the pace of every size. a came with the eight ahead (2
    # places, 4 min), b with the eight and a ahead (3 places, 8 min): 12 minutes for 5 places, and three
    # places now are some 7 minutes. c, of its own size, has waited 10 already; the eight's hour is not its wait.
    assert twos["ahead"] == 2 and twos["each_minutes"] == 2
    assert twos["by"] == "longest" and twos["longest_minutes"] == 10
    assert twos["about_minutes"] == 10 and twos["minutes"] == 10
    # for a party of eight the one ahead of its own size has waited an hour
    assert large["by"] == "longest" and large["longest_minutes"] == 60 and large["minutes"] == 60


def test_a_wait_past_the_longest_on_offer_marks_the_longest_and_says_what_it_is():
    parties = [
        party("a", 4, at(18), sat=at(18, 4)),
        party("b", 4, at(18, 1), sat=at(18, 7)),
        party("slow", 4, at(18, 10)),
    ]
    row = of(suggestions(parties, at(19, 59)), 4)
    assert row is not None and row["about_minutes"] == 109
    assert row["minutes"] == QUOTES[-1] == 90


def test_only_the_last_six_to_sit_down_count_and_only_the_ones_of_the_last_two_hours():
    # eight parties sit down one after the other, each alone on the list: the first two took an hour, the
    # last six 4 minutes
    parties = [
        party("old a", 2, at(17), sat=at(18)),
        party("old b", 2, at(18), sat=at(19)),
    ] + [party(f"new {n}", 2, at(19, 10 * n), sat=at(19, 10 * n + 4)) for n in range(1, 6)]
    parties.append(party("new 6", 2, at(20), sat=at(20, 4)))
    row = of(suggestions(parties, at(20, 5)), 2)
    assert row is not None and row["seated"] == 6 and row["each_minutes"] == 4 and row["minutes"] == 5
    # two and a half hours on nothing of it is lately: the list says nothing of now
    assert suggestions(parties, at(22, 35)) == []
    # and with one party of the six still inside the two hours, one is too few
    assert suggestions(parties, at(22, 3)) == []


def test_parties_that_sat_down_at_once_suggest_the_shortest_wait():
    parties = [party("a", 2, at(18), sat=at(18)), party("b", 2, at(18, 1), sat=at(18, 1))]
    row = of(suggestions(parties, at(18, 2)), 2)
    assert row is not None and row["about_minutes"] == 1 and row["each_minutes"] == 1
    assert row["minutes"] == QUOTES[0]


# Through the hub -------------------------------------------------------------------------------------------


class Wall:
    def __init__(self, now: int) -> None:
        self.now = now

    def __call__(self) -> int:
        return self.now


def hub(now: int = at(18)) -> tuple[TestClient, Wall]:
    wall = Wall(now)
    app = create_app(
        OpStore(), menu=MenuService(build_example()), printing=PrintService([]), waitlist=Waitlist(now_ms=wall)
    )
    return TestClient(app), wall


def add(c: TestClient, name: str, size: int, **more) -> str:
    r = c.post("/waitlist", json={"staff_id": "s4", "name": name, "size": size, **more})
    assert r.status_code == 200, r.text
    return r.json()["party"]["id"]


def seat(c: TestClient, party_id: str, table: str = "A1") -> None:
    r = c.post(f"/waitlist/{party_id}/seat", json={"staff_id": "s4", "table": table})
    assert r.status_code == 200, r.text


def suggest(c: TestClient) -> dict:
    r = c.get("/waitlist/suggest")
    assert r.status_code == 200, r.text
    return r.json()


def test_the_hub_suggests_a_wait_from_tonights_list():
    c, wall = hub(at(18))
    assert suggest(c) == {"suggest": [], "quotes": list(QUOTES)}
    chen = add(c, "Chen", 4, phone="781 555 0101", note="booth")
    wall.now = at(18, 2)
    okafor = add(c, "Okafor", 4)
    wall.now = at(18, 8)
    seat(c, chen)  # 1 place, 8 minutes
    assert suggest(c)["suggest"] == []  # one party is too few to go by
    wall.now = at(18, 14)
    seat(c, okafor, "A2")  # Chen was ahead: 2 places, 12 minutes
    wall.now = at(18, 20)
    add(c, "Silva", 2)
    add(c, "Moreau", 6)
    wall.now = at(18, 21)
    told = suggest(c)
    row = of(told["suggest"], 4)
    # 20 minutes for 3 places; Silva and Moreau are ahead of whoever comes now, of any size
    assert row is not None and row["like"] is False and row["ahead"] == 2 and row["each_minutes"] == 7
    assert row["about_minutes"] == 20 and row["minutes"] == 20 and row["by"] == "pace"
    assert told["quotes"] == list(QUOTES)


def test_asking_changes_nothing_and_names_nobody():
    c, wall = hub(at(18))
    chen = add(c, "Chen", 4, phone="781 555 0101", note="booth by the window")
    wall.now = at(18, 5)
    seat(c, add(c, "Okafor", 2))
    seat(c, chen, "A2")
    add(c, "Silva", 2, phone="781 555 0199")
    before = c.get("/waitlist").json()
    r = c.get("/waitlist/suggest")
    assert r.status_code == 200 and r.json()["suggest"]
    for word in ("Chen", "Okafor", "Silva", "781", "booth", "Holly"):
        assert word not in r.text
    assert c.get("/waitlist").json() == before


def test_a_party_put_back_waits_again_and_last_nights_parties_say_nothing():
    c, wall = hub(at(18))
    a, b = add(c, "A", 2), add(c, "B", 2)
    wall.now = at(18, 10)
    seat(c, a)
    seat(c, b, "A2")
    wall.now = at(18, 11)
    row = of(suggest(c)["suggest"], 2)
    assert row is not None and row["seated"] == 2 and row["ahead"] == 0
    # B was seated by a slip and is put back: it waits again, and is no party that sat down
    assert c.post(f"/waitlist/{b}/back", json={"staff_id": "s4"}).status_code == 200
    assert suggest(c)["suggest"] == []
    seat(c, b, "A2")
    assert of(suggest(c)["suggest"], 2) is not None
    # the next evening starts with nothing to go by
    wall.now = at(18, 0, day=17)
    assert suggest(c)["suggest"] == []
