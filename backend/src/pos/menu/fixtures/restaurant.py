"""A sample full-service menu: the worked example's kitchen plus a sushi bar and a full bar.

Stands in for the restaurant's real menu until that is imported from its spreadsheet, so the order screen,
station routing and taxes can be tried with dishes from every station.
"""

from __future__ import annotations

from decimal import Decimal as D

from ..defs import Attachment, Category, Definitions, Entry, Group, Item, Option, Section, Station, Variant
from .example import build_example


def _item(defs: Definitions, code, category, en, zh, kitchen, prices, *, number, section, menu="dinner", tags=()):
    """One item with its variants ({code: (en, price)}) and its dinner menu entry."""
    defs.add(Item(code, category, {"en": en, "zh": zh, "kitchen": kitchen}, tags=tuple(tags)))
    for sort, (vcode, (ven, price)) in enumerate(prices.items()):
        defs.add(Variant(f"{code}:{vcode}", code, vcode, {"en": ven}, D(price), sort=sort))
    defs.add(Entry(f"{menu}:{number}", menu, section, code, number, sort=len(defs.entries)))


def build_restaurant() -> Definitions:
    defs = build_example()
    defs.add(
        Station("sushi", {"en": "Sushi bar", "zh": "寿司"}, ("sushi",), frozenset({"fish", "crustacean", "sesame"})),
        Station("bar", {"en": "Bar", "zh": "酒吧"}, ("bar",)),
        Category("sushi", {"en": "Sushi", "zh": "寿司"}, tax_class="prepared_food", station="sushi", prep_minutes=10),
        Category("rolls", {"en": "Rolls", "zh": "卷"}, parent="sushi"),
        Category("nigiri", {"en": "Nigiri", "zh": "握寿司"}, parent="sushi"),
        Category("drinks", {"en": "Drinks", "zh": "饮料"}, tax_class="beverage", station="bar"),
        Category("beer", {"en": "Beer", "zh": "啤酒"}, parent="drinks", tax_class="alcohol"),
        Category("cocktails", {"en": "Cocktails", "zh": "鸡尾酒"}, parent="drinks", tax_class="alcohol"),
        Category("spirits", {"en": "Spirits", "zh": "烈酒"}, parent="drinks", tax_class="alcohol"),
        Section("dinner/sushi", "dinner", {"en": "Sushi bar", "zh": "寿司"}, sort=3),
        Section("dinner/bar", "dinner", {"en": "Bar", "zh": "酒吧"}, sort=4),
        Section("dinner/drinks", "dinner", {"en": "Soft drinks", "zh": "饮料"}, sort=5),
        Group("roll_style", {"en": "Roll style", "zh": "做法"}, 0, 1, sort=1),
        Option("roll_style:inside_out", "roll_style", "inside_out", {"en": "Inside out"}, "反卷", is_default=True),
        Option("roll_style:soy_paper", "roll_style", "soy_paper", {"en": "Soy paper"}, "豆皮", price=D("1.00")),
        Option("roll_style:brown_rice", "roll_style", "brown_rice", {"en": "Brown rice"}, "糙米", price=D("1.00")),
        Attachment("category", "rolls", "roll_style"),
        Group("spirit_style", {"en": "Served", "zh": "做法"}, 1, 1, sort=1),
        Option("spirit_style:neat", "spirit_style", "neat", {"en": "Neat"}, "NEAT", is_default=True),
        Option("spirit_style:rocks", "spirit_style", "rocks", {"en": "On the rocks"}, "ROCKS"),
        Option("spirit_style:up", "spirit_style", "up", {"en": "Up"}, "UP"),
        Attachment("category", "spirits", "spirit_style"),
    )
    _item(
        defs,
        "CALROLL",
        "rolls",
        "California roll",
        "加州卷",
        "加州卷",
        {"roll": ("Roll", "8.50")},
        number="S1",
        section="dinner/sushi",
    )
    _item(
        defs,
        "SPTUNA",
        "rolls",
        "Spicy tuna roll",
        "辣金枪鱼卷",
        "辣吞拿卷",
        {"roll": ("Roll", "9.50")},
        number="S2",
        section="dinner/sushi",
        tags=("raw",),
    )
    _item(
        defs,
        "SALNIG",
        "nigiri",
        "Salmon nigiri",
        "三文鱼握寿司",
        "三文鱼握",
        {"2pc": ("2 pieces", "7.00")},
        number="S3",
        section="dinner/sushi",
        tags=("raw",),
    )
    _item(
        defs,
        "DRAGON",
        "rolls",
        "Dragon roll",
        "龙卷",
        "龙卷",
        {"roll": ("Roll", "15.95")},
        number="S4",
        section="dinner/sushi",
    )
    _item(
        defs,
        "TSINGTAO",
        "beer",
        "Tsingtao",
        "青岛啤酒",
        "Tsingtao",
        {"bottle": ("Bottle", "6.50")},
        number="B1",
        section="dinner/bar",
        tags=("21+",),
    )
    _item(
        defs,
        "DRAFT",
        "beer",
        "House draft",
        "生啤",
        "Draft",
        {"pint": ("Pint", "7.00"), "pitcher": ("Pitcher", "22.00")},
        number="B2",
        section="dinner/bar",
        tags=("21+",),
    )
    _item(
        defs,
        "MAITAI",
        "cocktails",
        "Mai Tai",
        "迈泰",
        "Mai Tai",
        {"glass": ("Glass", "12.00")},
        number="B3",
        section="dinner/bar",
        tags=("21+",),
    )
    _item(
        defs,
        "SAKE",
        "spirits",
        "House sake",
        "清酒",
        "Sake",
        {"carafe": ("Carafe", "9.00")},
        number="B4",
        section="dinner/bar",
        tags=("21+",),
    )
    _item(
        defs,
        "WHISKY",
        "spirits",
        "Japanese whisky",
        "日本威士忌",
        "Whisky",
        {"2oz": ("2 oz", "14.00")},
        number="B5",
        section="dinner/bar",
        tags=("21+",),
    )
    _item(
        defs,
        "TEA",
        "drinks",
        "Hot tea",
        "热茶",
        "Hot tea",
        {"pot": ("Pot", "2.50")},
        number="D1",
        section="dinner/drinks",
    )
    _item(
        defs,
        "SODA",
        "drinks",
        "Soda",
        "汽水",
        "Soda",
        {"glass": ("Glass", "2.95")},
        number="D2",
        section="dinner/drinks",
    )
    return defs
