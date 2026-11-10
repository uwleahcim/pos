"""Modifier options that are dishes: a group sourced from a category, options linked by hand, the dish's own
choices one level down, and how such a line prints and shows on the check."""

from __future__ import annotations

from dataclasses import replace
from decimal import Decimal as D

from pos.menu import LineRequest, MenuEngine, Selection, admin, linked
from pos.menu.defs import Attachment, Group, Item, Option, Variant
from pos.menu.fixtures.example import build_example
from pos.menu.gloriafood import BUNDLED, ImportSettings, load_gloriafood, load_restaurant_menu, settings_from
from pos.menu.service import MenuService


def with_side_pick(defs=None):
    """The example with a group that offers every appetizer: a side slot that follows the category."""
    defs = defs or build_example()
    defs.add(
        Group("side_pick", {"en": "Pick a side"}, 1, 1, source_category="sides"),
        Option("side_pick:none", "side_pick", "none", {"en": "No side"}, "不要小食", sort=99),
        Attachment("item", "GTC", "side_pick", sort=9),
    )
    linked.sync(defs)
    return defs


def test_a_sourced_group_offers_the_dishes_of_its_category_and_follows_it():
    defs = with_side_pick()
    ids = [o.id for o in defs.options_of("side_pick")]
    assert ids == ["side_pick:EGGROLL", "side_pick:PUPU", "side_pick:SPRINGROLL", "side_pick:WINGS", "side_pick:none"]
    assert defs.options["side_pick:WINGS"].linked_variant == "WINGS:6pc"
    # a price set on a dish's option stays through a sync; a new dish in the category joins; one off sale goes
    defs.options["side_pick:WINGS"] = replace(defs.options["side_pick:WINGS"], price=D("2.00"))
    defs.add(
        Item("CRAB", "sides", {"en": "Crab Rangoon", "kitchen": "蟹角"}, sort=5),
        Variant("CRAB:6", "CRAB", "6", {"en": "6 pc"}, D("7.95")),
        Variant("CRAB:12", "CRAB", "12", {"en": "12 pc"}, D("13.95"), sort=1),
    )
    defs.items["PUPU"] = replace(defs.items["PUPU"], active=False)
    changed = linked.sync(defs)
    assert [c.split(":")[0] + ":" + c.split(":")[1].split(" ")[0] for c in changed] == [
        "option side_pick:CRAB-6",
        "option side_pick:CRAB-12",
        "option side_pick:PUPU",
    ]
    held = {o.id: o for o in defs.options_of("side_pick")}
    assert held["side_pick:WINGS"].price == D("2.00")
    assert "side_pick:PUPU" not in held and "side_pick:none" in held
    assert dict(defs.option_names(held["side_pick:CRAB-12"])) == {
        "en": "Crab Rangoon (12 pc)",
        "kitchen": "蟹角 (12 pc)",
    }
    assert defs.option_kitchen_label(held["side_pick:CRAB-6"]) == "蟹角 (6 pc)"
    assert defs.option_kitchen_label(held["side_pick:EGGROLL"]) == "蛋卷"
    assert linked.sync(defs) == []  # settled
    assert [p for p in MenuEngine(defs).check() if not p.code.startswith("warn_")] == []


def test_a_linked_option_is_called_what_its_dish_is_called_unless_named_itself():
    defs = with_side_pick()
    eggroll = defs.options["side_pick:EGGROLL"]
    assert dict(defs.option_names(eggroll)) == {"en": "Egg roll", "zh": "蛋卷", "kitchen": "蛋卷"}
    named = replace(eggroll, names={"en": "Crispy egg roll"})
    assert dict(defs.option_names(named)) == {"en": "Crispy egg roll"}
    assert defs.option_kitchen_label(named) == "蛋卷"  # the kitchen still reads the dish's name
    assert defs.option_kitchen_label(replace(named, kitchen_label="脆蛋卷")) == "脆蛋卷"


def test_the_dish_behind_a_choice_is_sold_as_a_child_line_with_its_own_station_and_choices():
    defs = with_side_pick()
    engine = MenuEngine(defs)
    line = engine.resolve(
        LineRequest(
            "GTC:quart",
            1,
            "dinner:87",
            (Selection("side_pick", "side_pick:WINGS", children=(Selection("spice", "spice:extra"),)),),
        )
    )
    assert line.ok, list(line.problems) + [p for c in line.children for p in c.problems]
    wings = line.children[0]
    assert (wings.origin, wings.variant_id, wings.unit_price, wings.price_source) == ("slot", "WINGS:6pc", D(0), "slot")
    assert [m.option_id for m in wings.modifiers] == ["spice:extra"]
    # the wok's line names the wings and how they are wanted; the fryer gets its own line under the dish
    assert [(k.station, k.text, k.header) for k in line.kitchen_lines] == [
        ("wok", "1 左宗鸡 (Qt) · 鸡翅 (加辣)", None),
        ("fryer", "1 鸡翅 · 加辣", "87 左宗鸡"),
    ]
    assert line.line_total == D("24.95")


def test_a_choice_cooked_at_the_dish_s_own_station_folds_into_its_line():
    """Two rolls of a maki combination, both at the sushi bar: one line names them both, not three lines."""
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    roll = defs.groups["roll_934419"]
    assert roll.source_category == "roll_maki"
    rolls = defs.options_of(roll.code)
    assert [o.id for o in rolls[:3]] == ["roll_934419:K01", "roll_934419:K02", "roll_934419:K03"]
    assert dict(defs.option_names(rolls[1])) == {"en": "Kanikyu", "kitchen": "sr:KANIYU"}  # the dish's own names
    soup = defs.groups["sushi_soup_2334003"]
    line = engine.resolve(
        LineRequest(
            "J55:regular",
            1,
            "dinner:J55",
            (*(Selection(roll.code, o.id) for o in rolls[:3]), Selection(soup.code, "sushi_soup_2334003:14653486")),
        )
    )
    assert line.ok, list(line.problems) + [p for c in line.children for p in c.problems]
    assert line.line_total == D("24.95")
    assert [(k.station, k.text, k.header) for k in line.kitchen_lines] == [
        ("sushi", "1 sr:MAKI COMBO s · sr:KAPPA MAKI · sr:KANIYU · sr:TEKKA MAKI · 酸辣湯 HOT & SOUR SOUP", None),
        ("soup", "1 酸辣湯 HOT & SOUR SOUP", "J55 sr:MAKI COMBO s"),
    ]
    # a roll that ran out is sold out as a choice too
    engine.set_availability("K02:regular", "sold_out")
    detail = engine.item_detail("J55", "dinner:J55")
    offered = {o.option_id: o for g in detail.groups for o in g.options}
    assert offered["roll_934419:K02"].status == "sold_out" and offered["roll_934419:K01"].status == "available"
    assert offered["roll_934419:K02"].linked_item == "K02"
    problems = engine.resolve(LineRequest("J55:regular", 1, "dinner:J55", (Selection(roll.code, rolls[1].id),)))
    assert "sold_out" in {p.code for c in problems.children for p in c.problems}


def test_item_detail_carries_a_linked_dish_s_groups_as_the_slot_exposes_them():
    defs = build_example()
    detail = MenuEngine(defs).item_detail("C5", "dinner:C5")
    slots = {g.group_id: g for g in detail.groups}
    gtc = next(o for o in slots["entree_slot"].options if o.option_id == "entree_slot:gtc")
    assert gtc.linked_item == "GTC"
    assert [g.group_id for g in gtc.groups] == ["spice", "rice", "addons"]  # exposed: all
    assert [o.is_default for o in gtc.groups[0].options] == [False, True, False]
    assert all(o.groups == () for o in slots["side_slot"].options)  # exposed: none
    # a slot's child_defaults win over the dish's own default
    defs.attachments = [
        replace(a, overrides={**a.overrides, "child_defaults": {"spice": "extra"}}) if a.group == "entree_slot" else a
        for a in defs.attachments
    ]
    detail = MenuEngine(defs).item_detail("C5", "dinner:C5")
    gtc = next(o for g in detail.groups for o in g.options if o.option_id == "entree_slot:gtc")
    assert [o.is_default for o in gtc.groups[0].options] == [False, False, True]
    # the JSON view says the same, so the sheet can ask the nested choices offline
    out = MenuService(build_example()).item("C5", "dinner:C5")
    option = next(o for g in out["groups"] for o in g["options"] if o["option_id"] == "entree_slot:gtc")
    assert option["linked_item"] == "GTC" and [g["group_id"] for g in option["groups"]] == ["spice", "rice", "addons"]


def test_the_check_lists_a_slot_dish_with_its_price_and_its_choices_one_level_deeper():
    service = MenuService(build_example())
    priced = service.priced(
        {
            "variant_id": "C5:regular",
            "entry_id": "dinner:C5",
            "selections": [
                {
                    "group_id": "entree_slot",
                    "option_id": "entree_slot:gtc",
                    "children": [
                        {"group_id": "spice", "option_id": "spice:extra"},
                        {"group_id": "addons", "option_id": "addons:shrimp"},
                    ],
                },
                {"group_id": "rice_slot", "option_id": "rice_slot:brown"},
            ],
        }
    )
    assert priced["unit_price"] == "19.50" and priced["problems"] == []
    rows = [(m["label"], m["price"], m["depth"], m["defaulted"]) for m in priced["modifiers"]]
    assert rows == [
        ("General Tso's Chicken", "0.00", 0, False),
        ("Extra spicy", "0.00", 1, False),
        ("White rice", "0.00", 1, True),
        ("Add shrimp", "4.00", 1, False),
        ("Egg roll", "0.00", 0, True),
        ("Brown rice", "1.00", 0, False),
    ]


def test_a_note_on_a_chosen_dish_travels_with_it_to_the_kitchen_and_the_check():
    """ "Extra hot" on the soup of a lunch special: the wok's line names it with the soup, the soup station prints
    it under its own line, and the check reads it under the soup, one level in, like a choice on it."""
    defs, _ = load_restaurant_menu()
    engine = MenuEngine(defs)
    soup = Selection("soup_929530", "soup_929530:4904287", notes="extra hot")
    line = engine.resolve(LineRequest("L01:regular", 1, "lunch:L01", (soup,)))
    assert line.ok, list(line.problems) + [p for c in line.children for p in c.problems]
    assert line.children[0].notes == "extra hot"
    assert [(k.station, k.text, k.header, k.note) for k in line.kitchen_lines] == [
        ("wok1", "1 L甜酸雞 LUN:SWEET & SOUR CHKN · White Rice · 日本湯 MISO SOUP (extra hot)", None, None),
        ("soup", "1 日本湯 MISO SOUP", "L01 L甜酸雞 LUN:SWEET & SOUR CHKN", "extra hot"),
    ]
    priced = MenuService(defs).priced(
        {
            "variant_id": "L01:regular",
            "entry_id": "lunch:L01",
            "selections": [{"group_id": "soup_929530", "option_id": "soup_929530:4904287", "notes": "extra hot"}],
        }
    )
    assert priced["problems"] == []
    rows = [(m["label"], m["price"], m["depth"], m.get("note", False)) for m in priced["modifiers"]]
    assert rows[1:] == [("Miso Soup", "0.00", 0, False), ("extra hot", "0.00", 1, True)]
    assert [(k["station"], k["note"]) for k in priced["kitchen"]] == [("wok1", None), ("soup", "extra hot")]
    # a blank note is no note
    blank = Selection("soup_929530", "soup_929530:4904287", notes="  ")
    assert (
        MenuService(defs).priced(
            {
                "variant_id": "L01:regular",
                "selections": [{"group_id": blank.group_id, "option_id": blank.option_id, "notes": blank.notes}],
            }
        )["kitchen"][1]["note"]
        is None
    )


def test_a_slot_s_price_on_the_sheet_is_what_the_slot_charges():
    """A slot priced "linked" charges the dish's own price and one priced "free" nothing: the sheet says so."""
    defs = build_example()
    spring, egg = defs.options["side_slot:springroll"], defs.options["side_slot:eggroll"]
    defs.options[spring.id] = replace(spring, price_mode="linked")
    defs.options[egg.id] = replace(egg, price_mode="free", price=D("2.00"))
    service = MenuService(defs)
    side = next(g for g in service.item("C5", "dinner:C5")["groups"] if g["group_id"] == "side_slot")
    prices = {o["option_id"]: o["price"] for o in side["options"]}
    assert prices == {
        "side_slot:eggroll": "0.00",
        "side_slot:springroll": str(defs.variants["SPRINGROLL:regular"].base_price),
    }
    with_spring = service.priced(
        {"variant_id": "C5:regular", "selections": [{"group_id": "side_slot", "option_id": "side_slot:springroll"}]}
    )
    plain = service.priced({"variant_id": "C5:regular"})
    assert D(with_spring["unit_price"]) - D(plain["unit_price"]) == defs.variants["SPRINGROLL:regular"].base_price


def test_a_dish_that_offers_itself_is_found_by_the_checks_and_stops_resolving():
    defs = build_example()
    defs.add(
        Group("again", {"en": "Again"}, 1, 1),
        Option("again:eggroll", "again", "eggroll", {}, is_default=True, linked_variant="EGGROLL:regular"),
        Attachment("item", "EGGROLL", "again"),
    )
    engine = MenuEngine(defs)
    cycles = [p for p in engine.check() if p.code == "cycle"]
    assert cycles and "EGGROLL -> EGGROLL" in cycles[0].message
    line = engine.resolve(LineRequest("EGGROLL:regular", 1, "dinner:1"))
    deepest = line
    while deepest.children:
        deepest = deepest.children[0]
    assert [p.code for p in deepest.problems] == ["too_deep"]


def test_saving_a_new_dish_into_a_sourced_category_offers_it_at_once():
    defs = with_side_pick()
    new = admin.apply(
        defs,
        [
            {
                "kind": "item",
                "op": "put",
                "data": {"code": "RANGOON", "category": "sides", "names": {"en": "Crab Rangoon"}},
            },
            {
                "kind": "variant",
                "op": "put",
                "data": {"item": "RANGOON", "code": "regular", "names": {"en": "6 pc"}, "base_price": "7.95"},
            },
        ],
    )
    assert new.options["side_pick:RANGOON"].linked_variant == "RANGOON:regular"
    assert "side_pick:RANGOON" not in defs.options  # the menu being sold from is untouched
    errors, _ = admin.problems(new)
    assert errors == []
    # a sourced group's category has to exist
    broken = admin.apply(
        defs,
        [{"kind": "group", "op": "put", "data": {**admin.encode(defs.groups["side_pick"]), "source_category": "nope"}}],
    )
    assert [p.message for p in admin.problems(broken)[0]] == ["group side_pick: category 'nope' does not exist"]


def test_relink_brings_a_hub_seeded_before_the_links_up_to_date():
    """A stored menu from the export alone (soups as words, twenty copies of the rolls), with the editor's
    work since: a renamed soup option and a hand-added option on the rolls."""
    stored = load_gloriafood(BUNDLED, replace(settings_from(), linked_groups={}))[0]
    soup, roll = "soup_929530", "roll_934419"
    assert all(o.linked_variant is None for o in stored.options_of(soup)) and len(stored.options_of(roll)) == 20
    miso = stored.options[f"{soup}:4904287"]
    stored.options[miso.id] = replace(miso, names={"en": "Miso soup (cup)"})
    stored.add(Option(f"{roll}:norolls", roll, "norolls", {"en": "No rolls"}, sort=50))
    bundled, _ = load_restaurant_menu()
    changed = linked.relink(stored, bundled)
    assert any(c.startswith(f"group {roll} now offers") for c in changed)
    assert sum(c.startswith(f"option {soup}:") and "linked to" in c for c in changed) == 4
    assert [o.id for o in stored.options_of(roll)] == [f"{roll}:norolls"]  # the export's copies went
    linked.sync(stored)
    assert len(stored.options_of(roll)) == 21 and stored.groups[roll].source_category == "roll_maki"
    held = {o.id: o for o in stored.options_of(soup)}
    assert held[miso.id].linked_variant == "801:regular" and dict(held[miso.id].names) == {"en": "Miso soup (cup)"}
    assert held[f"{soup}:4904289"].linked_variant == "802:regular" and dict(held[f"{soup}:4904289"].names) == {}
    assert held[f"{soup}:4904304"].linked_variant is None  # No Soup stays a word
    assert linked.relink(stored, bundled) == [] and linked.sync(stored) == []
    assert MenuEngine(stored).check() == []


def test_groups_json_is_read_with_the_settings(tmp_path):
    from pos.menu.gloriafood import linked_groups_from

    settings = settings_from()
    assert settings.linked_groups == {
        "Soup": {"items_from": "Soup"},
        "Sushi Soup": {"items_from": "Soup"},
        "Roll": {"category": "Roll (Maki)"},
    }
    bad = tmp_path / "groups.json"
    bad.write_text('{"linked": {"Rice": {"x": 1}}}')
    try:
        linked_groups_from(bad)
    except ValueError as err:
        assert "Rice" in str(err)
    else:
        raise AssertionError("a group needs category or items_from")
    assert ImportSettings().linked_groups == {}
