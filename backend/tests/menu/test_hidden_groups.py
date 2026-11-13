"""A modifier group names the stations whose tickets leave its choices off (`Group.hidden_at`): the cooks do
not read the rice or the soup a dish comes with. The line keeps every choice and says where each is left
off, so the takeout counter and the check still read them."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from pos.menu import LineRequest, MenuEngine, Selection, admin
from pos.menu.defs import Attachment, Group, Option
from pos.menu.engine import ticket_labels
from pos.menu.fixtures.example import build_example
from pos.menu.gloriafood import BUNDLED, STATIONS, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.resolved import ResolvedModifier
from pos.menu.seed import fill
from pos.menu.service import MenuService

from .test_linked import with_side_pick

COOKS_AS_LISTED = ("wok1", "wok2", "wok3", "broiler", "range", "fryer", "sushi")  # the order groups.json has them
COOKS = tuple(sorted(COOKS_AS_LISTED))
SPICY_BROWN = (Selection("spice", "spice:extra"), Selection("rice", "rice:brown"))


def hiding(defs, group: str, *stations: str):
    defs.groups[group] = replace(defs.groups[group], hidden_at=stations)
    return defs


def resolved(defs, *selections, variant="GTC:quart", entry="dinner:87"):
    line = MenuEngine(defs).resolve(LineRequest(variant, 1, entry, selections))
    assert line.ok, list(line.problems) + [p for c in line.children for p in c.problems]
    return line


def test_a_line_keeps_every_choice_and_says_where_each_is_left_off():
    wok = resolved(hiding(build_example(), "rice", "wok"), *SPICY_BROWN).kitchen_lines[0]
    assert (wok.station, wok.labels, wok.depths) == ("wok", ("加辣", "糙米"), (0, 0))
    assert wok.hidden == ((), ("wok",))  # the spice is read everywhere, the rice not at the wok
    assert wok.text == "1 左宗鸡 (Qt) · 加辣 · 糙米"  # the whole dish on one line, for the logs
    # a menu that hides nothing says nothing: lines are as they always were
    assert resolved(build_example(), *SPICY_BROWN).kitchen_lines[0].hidden == ()
    # a group a manager set to print everywhere is the same as one nobody set
    assert resolved(hiding(build_example(), "rice"), *SPICY_BROWN).kitchen_lines[0].hidden == ()


def test_the_snapshot_an_order_line_keeps_carries_it_only_when_something_is_hidden():
    request = {
        "variant_id": "GTC:quart",
        "entry_id": "dinner:87",
        "selections": [{"group_id": g, "option_id": o} for g, o in (("spice", "spice:extra"), ("rice", "rice:brown"))],
    }
    priced = MenuService(hiding(build_example(), "rice", "wok", "fryer")).priced(request)
    assert priced["kitchen"][0]["labels"] == ["加辣", "糙米"]
    assert priced["kitchen"][0]["hidden"] == [[], ["fryer", "wok"]]
    assert [m["kitchen_label"] for m in priced["modifiers"]] == ["加辣", "糙米"]  # the check lists both
    assert "hidden" not in MenuService(build_example()).priced(request)["kitchen"][0]


def test_what_stands_under_a_hidden_choice_is_hidden_with_it():
    spice = ResolvedModifier("spice", "spice:hot", 1, "XXXhot", D(0), hidden_at=("wok",))
    soup = ResolvedModifier("soup", "soup:miso", 1, "MISO", D(0), children=(spice,), hidden_at=("fryer",))
    assert list(ticket_labels([soup])) == [(0, "MISO", ("fryer",)), (1, "XXXhot", ("fryer", "wok"))]
    # the soup the dish comes with is listed only for the change under it: a station that does not read the
    # change has no use for the soup's name either
    came_with = replace(soup, defaulted=True, hidden_at=())
    assert list(ticket_labels([came_with])) == [(0, "MISO", ("wok",)), (1, "XXXhot", ("wok",))]
    # two changes under it, one read at the wok: the wok reads the soup's name and that one
    note = (0, "no tofu", ())
    assert list(ticket_labels([replace(came_with, under=(note,))])) == [
        (0, "MISO", ()),
        (1, "no tofu", ()),
        (1, "XXXhot", ("wok",)),
    ]


def test_a_dish_behind_a_hidden_choice_still_prints_at_its_own_station():
    """The wings picked as a side are fried at the fryer, whatever the wok reads."""
    line = resolved(
        hiding(with_side_pick(), "side_pick", "wok"),
        Selection("side_pick", "side_pick:WINGS", children=(Selection("spice", "spice:extra"),)),
    )
    wok, fryer = line.kitchen_lines
    assert (wok.station, wok.labels, wok.hidden) == ("wok", ("鸡翅", "加辣"), (("wok",), ("wok",)))
    assert (fryer.station, fryer.text, fryer.header, fryer.hidden) == ("fryer", "1 鸡翅 · 加辣", "87 左宗鸡", ())


def with_fried_rice_side(defs=None):
    """The example with a side of pork fried rice offered on General Tso's: both are cooked at the wok."""
    defs = defs or build_example()
    defs.add(
        Group("side_rice", {"en": "Side of rice"}, 0, 1),
        Option("side_rice:pfr", "side_rice", "pfr", {}, linked_variant="PFR:side", price_mode="free"),
        Attachment("item", "GTC", "side_rice", sort=9),
    )
    return defs


def test_a_dish_cooked_where_its_choice_is_hidden_keeps_a_line_of_its_own_there():
    """A side cooked at the dish's own station is one of the dish's choices on one line. Hide the group there
    and the choice goes, so the side prints as its own line: a station never loses a dish it cooks."""
    pick = Selection("side_rice", "side_rice:pfr")
    folded = resolved(with_fried_rice_side(), pick)
    assert [(k.station, k.text, k.header) for k in folded.kitchen_lines] == [
        ("wok", "1 左宗鸡 (Qt) · 叉烧炒饭 (small)", None),
    ]
    apart = resolved(hiding(with_fried_rice_side(), "side_rice", "wok"), pick)
    assert [(k.station, k.text, k.header, k.hidden) for k in apart.kitchen_lines] == [
        ("wok", "1 左宗鸡 (Qt) · 叉烧炒饭 (small)", None, (("wok",),)),
        ("wok", "1 叉烧炒饭 (small)", "87 左宗鸡", ()),
    ]


def test_the_restaurant_s_rice_and_soup_are_off_the_cooks_tickets():
    defs, report = load_restaurant_menu()
    assert not [note for note in report.notes if "hid" in note]  # every group and station named exists
    hidden = {g.names["en"]: g.hidden_at for g in defs.groups.values() if g.hidden_at is not None}
    assert hidden == dict.fromkeys(("Rice", "Lunch Rice", "Soup", "Sushi Soup"), COOKS_AS_LISTED)
    assert admin.problems(defs)[0] == []
    rice, soup = "lunch_rice_929539", "soup_929530"
    brown = Selection(rice, f"{rice}:4904330")
    hot_sour = next(o for o in defs.options_of(soup) if defs.option_names(o).get("en") == "Hot & Sour Soup")
    line = resolved(defs, brown, Selection(soup, hot_sour.id), variant="L01:regular", entry="lunch:L01")
    wok, at_soup = line.kitchen_lines
    # the wok cooks the sweet and sour chicken and reads neither the rice nor the soup
    assert (wok.station, wok.labels) == ("wok1", ("Brown Rice", "酸辣湯 HOT & SOUR SOUP"))
    assert wok.hidden == (COOKS, COOKS)
    # the soup station ladles the soup as before, under the dish it goes with
    assert (at_soup.station, at_soup.text, at_soup.hidden) == ("soup", "1 酸辣湯 HOT & SOUR SOUP", ())
    assert at_soup.header == "L01 L甜酸雞 LUN:SWEET & SOUR CHKN"


def test_the_editor_sets_the_stations_and_one_that_does_not_exist_is_refused():
    defs = build_example()
    row = next(g for g in admin.catalog(defs)["group"] if g["key"] == "rice")
    assert row["hidden_at"] is None  # nobody has said
    data = {k: v for k, v in row.items() if k != "key"}
    saved = admin.apply(defs, [{"kind": "group", "op": "put", "data": {**data, "hidden_at": ["wok", "fryer"]}}])
    assert saved.groups["rice"].hidden_at == ("wok", "fryer") and admin.problems(saved)[0] == []
    assert next(g for g in admin.catalog(saved)["group"] if g["key"] == "rice")["hidden_at"] == ["wok", "fryer"]
    shown = admin.apply(saved, [{"kind": "group", "op": "put", "data": {**data, "hidden_at": []}}])
    assert shown.groups["rice"].hidden_at == () and admin.problems(shown)[0] == []
    wrong = admin.apply(defs, [{"kind": "group", "op": "put", "data": {**data, "hidden_at": ["grill"]}}])
    assert [p.message for p in admin.problems(wrong)[0]] == ["group rice: station 'grill' does not exist"]


def test_a_running_hub_takes_the_files_stations_only_on_a_group_nobody_set():
    bundled, _ = load_restaurant_menu()
    stored = load_gloriafood(BUNDLED, replace(settings_from(STATIONS), hidden_groups={}))[0]  # seeded before
    rice, lunch_rice, soup, sushi_soup = "rice_929524", "lunch_rice_929539", "soup_929530", "sushi_soup_2334003"
    assert all(stored.groups[code].hidden_at is None for code in (rice, lunch_rice, soup, sushi_soup))
    stored.groups[lunch_rice] = replace(stored.groups[lunch_rice], hidden_at=())  # a manager: print it everywhere
    stored.groups[soup] = replace(stored.groups[soup], hidden_at=("fryer",))  # a manager's own pick
    del stored.stations["sushi"]  # this hub has no sushi bar (and nothing printing there)
    filled = fill(stored, bundled)
    without_sushi = tuple(code for code in COOKS_AS_LISTED if code != "sushi")
    assert [line for line in filled if "tickets" in line] == [
        f"group {rice} is left off the tickets at {', '.join(without_sushi)}",
        f"group {sushi_soup} is left off the tickets at {', '.join(without_sushi)}",
    ]
    assert stored.groups[rice].hidden_at == stored.groups[sushi_soup].hidden_at == without_sushi
    assert stored.groups[lunch_rice].hidden_at == () and stored.groups[soup].hidden_at == ("fryer",)
    assert [line for line in fill(stored, bundled) if "tickets" in line] == []  # once is enough
