"""The menu design's worked example: General Tso's Chicken, Combination Plate C5 and their world.

Quantities, prices and costs follow docs/menu-engine-design.md, "Worked example".
"""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal as D

from ..defs import (
    Allergen,
    AllergenDecl,
    Attachment,
    Category,
    Component,
    ComponentOverride,
    Definitions,
    Effect,
    Entry,
    Group,
    Ingredient,
    Item,
    Localizer,
    Menu,
    Option,
    Recipe,
    Section,
    Station,
    Unit,
    Variant,
)

REVIEWED = datetime(2026, 10, 1, tzinfo=UTC)


def stock(code, en, base, cost, *, yield_pct=100, allergens=(), reviewed=True, tags=(), each_grams=None, category=None):
    return Ingredient(
        code,
        {"en": en},
        "stock",
        base,
        category=category,
        each_grams=D(each_grams) if each_grams else None,
        yield_pct=D(yield_pct),
        cost_per_base_unit=D(cost),
        dietary_tags=tuple(tags),
        allergens=tuple(AllergenDecl(a, "contains", True, "supplier sheet") for a in allergens),
        allergens_reviewed_at=REVIEWED if reviewed else None,
    )


def prep(code, en, base):
    return Ingredient(code, {"en": en}, "prep", base, allergens_reviewed_at=REVIEWED)


def comp(cid, ref, qty, unit, role=None, *, kind="ingredient", scales=True, defaults=None, locked=False):
    return Component(cid, kind, ref, D(qty), unit, role, scales=scales, defaults=defaults or {}, locked=locked)


def build_example() -> Definitions:
    defs = Definitions(Localizer({"zh-Hant": ("zh-Hant", "zh", "en"), "kitchen": ("kitchen", "zh", "en")}))
    defs.add(
        Unit("g", "mass", D(1)),
        Unit("kg", "mass", D(1000)),
        Unit("oz", "mass", D("28.35")),
        Unit("lb", "mass", D("453.6")),
        Unit("ml", "volume", D(1)),
        Unit("l", "volume", D(1000)),
        Unit("tsp", "volume", D("4.93")),
        Unit("tbsp", "volume", D("14.79")),
        Unit("cup", "volume", D("236.6")),
        Unit("each", "count", D(1)),
    )
    for sort, (code, en, major) in enumerate(
        [
            ("milk", "Milk", True),
            ("egg", "Eggs", True),
            ("fish", "Fish", True),
            ("crustacean", "Crustacean shellfish", True),
            ("tree_nut", "Tree nuts", True),
            ("peanut", "Peanuts", True),
            ("wheat", "Wheat", True),
            ("soy", "Soybeans", True),
            ("sesame", "Sesame", True),
            ("msg", "MSG", False),
        ]
    ):
        defs.add(Allergen(code, {"en": en}, major, sort))
    defs.add(
        Station("wok", {"en": "Wok", "zh": "炒锅"}, ("kitchen-1",), frozenset({"sesame", "peanut"})),
        Station("fryer", {"en": "Fryer", "zh": "油炸"}, ("kitchen-1",), frozenset({"crustacean", "fish", "wheat"})),
        Station("cold", {"en": "Cold", "zh": "冷菜"}, ("kitchen-2",)),
        Category("entrees", {"en": "Entrees", "zh": "主菜"}, tax_class="prepared_food", station="wok", prep_minutes=12),
        Category("chefs", {"en": "Chef's Specials", "zh": "招牌菜"}, parent="entrees"),
        Category("combos", {"en": "Combination Plates", "zh": "套餐"}, tax_class="prepared_food"),
        Category(
            "sides", {"en": "Appetizers", "zh": "前菜"}, tax_class="prepared_food", station="fryer", prep_minutes=8
        ),
        Category("rice", {"en": "Rice", "zh": "饭"}, tax_class="prepared_food", station="wok"),
    )
    # --- ingredients
    defs.add(
        stock("chicken_thigh", "Chicken thigh, raw", "g", "0.0066", yield_pct=85, tags=("meat",), category="protein"),
        stock(
            "shrimp_3140",
            "Shrimp 31/40",
            "g",
            "0.022",
            allergens=("crustacean",),
            tags=("shellfish",),
            category="protein",
        ),
        stock("broccoli", "Broccoli", "g", "0.004365", yield_pct=90, category="produce"),
        prep("gt_sauce", "General Tso sauce", "ml"),
        stock("soy_sauce", "Soy sauce", "ml", "0.003", allergens=("wheat", "soy"), tags=("gluten",), category="sauce"),
        stock("sugar", "Sugar", "g", "0.002", category="dry"),
        stock("rice_vinegar", "Rice vinegar", "ml", "0.004", category="sauce"),
        stock("cornstarch", "Cornstarch", "g", "0.003", category="dry"),
        stock("garlic", "Garlic", "g", "0.008", category="produce"),
        stock("ginger", "Ginger", "g", "0.006", category="produce"),
        prep("white_rice_cooked", "Cooked white rice", "g"),
        stock("white_rice_raw", "White rice, raw", "g", "0.002", category="dry"),
        prep("brown_rice_cooked", "Cooked brown rice", "g"),
        stock("brown_rice_raw", "Brown rice, raw", "g", "0.0033", category="dry"),
        stock("dried_chili", "Dried chili", "each", "0.05", reviewed=False, category="dry"),
        stock("pint_container", "Pint container", "each", "0.15", category="packaging"),
        stock("qt_container", "Quart container", "each", "0.35", category="packaging"),
        stock("beef_flank", "Beef flank", "g", "0.012", yield_pct=90, tags=("meat",), category="protein"),
        stock(
            "oyster_sauce",
            "Oyster sauce",
            "ml",
            "0.005",
            allergens=("soy", "wheat"),
            tags=("gluten", "shellfish"),
            category="sauce",
        ),
        stock(
            "eggroll_wrapper",
            "Egg roll wrapper",
            "each",
            "0.08",
            allergens=("wheat", "egg"),
            tags=("gluten", "egg"),
            each_grams=12,
        ),
        stock("cabbage", "Cabbage", "g", "0.002", category="produce"),
        stock("pork_ground", "Ground pork", "g", "0.009", tags=("meat", "pork"), category="protein"),
        stock(
            "springroll_wrapper",
            "Spring roll wrapper",
            "each",
            "0.06",
            allergens=("wheat",),
            tags=("gluten",),
            each_grams=10,
        ),
        stock("carrot", "Carrot", "g", "0.0015", category="produce"),
        stock("pork_bbq", "BBQ pork", "g", "0.011", tags=("meat", "pork"), category="protein"),
        stock("egg", "Egg", "each", "0.25", allergens=("egg",), tags=("egg",), each_grams=50),
        stock("scallion", "Scallion", "g", "0.004", category="produce"),
        stock("fortune_cookie", "Fortune cookie", "each", "0.05", allergens=("wheat",), tags=("gluten",)),
        stock("combo_container", "Combo container", "each", "0.30", category="packaging"),
        stock("chicken_wings", "Chicken wings", "each", "0.45", tags=("meat",), each_grams=90, category="protein"),
        Recipe(
            "gt_sauce@1",
            "ingredient",
            "gt_sauce",
            1,
            (
                comp("gts1", "soy_sauce", 1500, "ml"),
                comp("gts2", "sugar", 800, "g"),
                comp("gts3", "rice_vinegar", 800, "ml"),
                comp("gts4", "cornstarch", 200, "g"),
                comp("gts5", "garlic", 150, "g"),
                comp("gts6", "ginger", 150, "g"),
            ),
            D(4000),
            "ml",
        ),
        Recipe(
            "white_rice_cooked@1",
            "ingredient",
            "white_rice_cooked",
            1,
            (comp("wr1", "white_rice_raw", 1000, "g"),),
            D(3000),
            "g",
        ),
        Recipe(
            "brown_rice_cooked@1",
            "ingredient",
            "brown_rice_cooked",
            1,
            (comp("br1", "brown_rice_raw", 1000, "g"),),
            D(3000),
            "g",
        ),
    )
    # --- modifier library
    defs.add(
        Group("spice", {"en": "Spice level", "zh": "辣度"}, 0, 1, sort=1),
        Option("spice:mild", "spice", "mild", {"en": "Mild"}, "少辣", sort=1),
        Option("spice:medium", "spice", "medium", {"en": "Medium"}, None, is_default=True, sort=2),
        Option(
            "spice:extra",
            "spice",
            "extra",
            {"en": "Extra spicy", "zh": "加辣"},
            "加辣",
            effects=(Effect("scale", role="spice", factor=D(2)),),
            sort=3,
        ),
        Group("rice", {"en": "Choice of rice", "zh": "饭"}, 1, 1, sort=2),
        Option("rice:white", "rice", "white", {"en": "White rice"}, None, is_default=True, sort=1),
        Option(
            "rice:brown",
            "rice",
            "brown",
            {"en": "Brown rice"},
            "糙米",
            price=D("1.00"),
            effects=(Effect("substitute", role="starch", ingredient="brown_rice_cooked"),),
            sort=2,
        ),
        Option(
            "rice:none", "rice", "none", {"en": "No rice"}, "不要饭", effects=(Effect("remove", role="starch"),), sort=3
        ),
        Group("addons", {"en": "Add-ons", "zh": "加料"}, 0, None, allow_quantity=True, sort=3),
        Option(
            "addons:shrimp",
            "addons",
            "shrimp",
            {"en": "Add shrimp"},
            "加虾",
            price=D("3.00"),
            effects=(Effect("add", ingredient="shrimp_3140", qty=D(3), unit="oz", role="protein"),),
            max_qty=3,
            sort=1,
        ),
        Option(
            "addons:sauce",
            "addons",
            "sauce",
            {"en": "Extra sauce"},
            "多汁",
            price=D("0.50"),
            effects=(Effect("scale", role="sauce", factor=D("1.5")),),
            sort=2,
        ),
        Option("addons:nomsg", "addons", "nomsg", {"en": "No MSG"}, "不要味精", effects=(Effect("note"),), sort=3),
        Option(
            "addons:sauceside",
            "addons",
            "sauceside",
            {"en": "Sauce on side"},
            "汁另放",
            effects=(Effect("note"),),
            sort=4,
        ),
        Group("entree_slot", {"en": "Entree"}, 1, 1, sort=1),
        Option(
            "entree_slot:gtc",
            "entree_slot",
            "gtc",
            {"en": "General Tso's Chicken"},
            None,
            is_default=True,
            linked_variant="GTC:lunch",
            sort=1,
        ),
        Option(
            "entree_slot:bb", "entree_slot", "bb", {"en": "Beef with Broccoli"}, None, linked_variant="BB:lunch", sort=2
        ),
        Group("side_slot", {"en": "Side"}, 1, 1, sort=2),
        Option(
            "side_slot:eggroll",
            "side_slot",
            "eggroll",
            {"en": "Egg roll"},
            None,
            is_default=True,
            linked_variant="EGGROLL:regular",
            sort=1,
        ),
        Option(
            "side_slot:springroll",
            "side_slot",
            "springroll",
            {"en": "Spring roll"},
            None,
            linked_variant="SPRINGROLL:regular",
            sort=2,
        ),
        Group("rice_slot", {"en": "Rice"}, 1, 1, sort=3),
        Option(
            "rice_slot:pfr",
            "rice_slot",
            "pfr",
            {"en": "Pork fried rice"},
            None,
            is_default=True,
            linked_variant="PFR:side",
            sort=1,
        ),
        Option(
            "rice_slot:white", "rice_slot", "white", {"en": "White rice"}, None, linked_variant="WRICE:side", sort=2
        ),
        Option(
            "rice_slot:brown",
            "rice_slot",
            "brown",
            {"en": "Brown rice"},
            None,
            price=D("1.00"),
            linked_variant="BRICE:side",
            sort=3,
        ),
        Attachment("category", "entrees", "spice", sort=1),
        Attachment("category", "entrees", "rice", sort=2),
        Attachment("item", "GTC", "addons", {"prices": {"shrimp": D("4.00")}}, sort=3),
        Attachment("item", "WINGS", "spice", {"default": "medium"}, sort=1),
        Attachment("item", "C5", "entree_slot", {"expose_linked_groups": "all"}, sort=1),
        Attachment("item", "C5", "side_slot", {"expose_linked_groups": "none"}, sort=2),
        Attachment("item", "C5", "rice_slot", {"expose_linked_groups": "none"}, sort=3),
    )
    # --- catalog
    defs.add(
        Item(
            "GTC",
            "chefs",
            {"en": "General Tso's Chicken", "zh": "左宗棠鸡", "kitchen": "左宗鸡"},
            aliases=("general chicken", "gtc", "zzt", "zuo zong tang ji"),
            tags=("spicy", "popular"),
        ),
        Variant("GTC:pint", "GTC", "pint", {"en": "Pint", "kitchen": "Pt"}, D("13.95"), sort=1),
        Variant(
            "GTC:quart",
            "GTC",
            "quart",
            {"en": "Quart", "kitchen": "Qt"},
            D("24.95"),
            D(2),
            (ComponentOverride("packaging", "qt_container", D(1), "each"),),
            sort=2,
        ),
        Variant("GTC:lunch", "GTC", "lunch", {"en": "Lunch", "kitchen": "L"}, D("10.95"), D("0.75"), sort=3),
        Recipe(
            "GTC@1",
            "item",
            "GTC",
            1,
            (
                comp("gtc1", "chicken_thigh", 6, "oz", "protein"),
                comp("gtc2", "gt_sauce", 90, "ml", "sauce"),
                comp("gtc3", "broccoli", 2, "oz", "veg"),
                comp("gtc4", "white_rice_cooked", 8, "oz", "starch"),
                comp("gtc5", "dried_chili", 3, "each", "spice"),
                comp("gtc6", "pint_container", 1, "each", "packaging", scales=False),
            ),
        ),
        Item(
            "BB",
            "entrees",
            {"en": "Beef with Broccoli", "zh": "芥兰牛", "kitchen": "芥兰牛"},
            aliases=("beef broccoli", "bb"),
        ),
        Variant("BB:regular", "BB", "regular", {"en": "Regular"}, D("14.95"), sort=1),
        Variant("BB:lunch", "BB", "lunch", {"en": "Lunch", "kitchen": "L"}, D("10.95"), D("0.75"), sort=2),
        Recipe(
            "BB@1",
            "item",
            "BB",
            1,
            (
                comp("bb1", "beef_flank", 6, "oz", "protein"),
                comp("bb2", "oyster_sauce", 60, "ml", "sauce"),
                comp("bb3", "broccoli", 3, "oz", "veg"),
                comp("bb4", "white_rice_cooked", 8, "oz", "starch"),
                comp("bb5", "pint_container", 1, "each", "packaging", scales=False),
            ),
        ),
        Item("EGGROLL", "sides", {"en": "Egg roll", "zh": "蛋卷", "kitchen": "蛋卷"}, aliases=("egg roll", "eggroll")),
        Variant("EGGROLL:regular", "EGGROLL", "regular", {"en": "2 pc"}, D("3.50")),
        Recipe(
            "EGGROLL@1",
            "item",
            "EGGROLL",
            1,
            (
                comp("er1", "eggroll_wrapper", 2, "each"),
                comp("er2", "cabbage", 60, "g", "veg"),
                comp("er3", "pork_ground", 40, "g", "protein"),
            ),
        ),
        Item("SPRINGROLL", "sides", {"en": "Spring roll", "zh": "春卷", "kitchen": "春卷"}),
        Variant("SPRINGROLL:regular", "SPRINGROLL", "regular", {"en": "2 pc"}, D("3.25")),
        Recipe(
            "SPRINGROLL@1",
            "item",
            "SPRINGROLL",
            1,
            (
                comp("sr1", "springroll_wrapper", 2, "each"),
                comp("sr2", "cabbage", 50, "g", "veg"),
                comp("sr3", "carrot", 20, "g", "veg"),
            ),
        ),
        Item(
            "PFR", "rice", {"en": "Pork fried rice", "zh": "叉烧炒饭", "kitchen": "叉烧炒饭"}, aliases=("fried rice",)
        ),
        Variant("PFR:regular", "PFR", "regular", {"en": "Regular"}, D("9.95"), sort=1),
        Variant("PFR:side", "PFR", "side", {"en": "Side", "kitchen": "small"}, D("3.50"), D("0.5"), sort=2),
        Recipe(
            "PFR@1",
            "item",
            "PFR",
            1,
            (
                comp("pfr1", "white_rice_cooked", 10, "oz", "starch"),
                comp("pfr2", "pork_bbq", 2, "oz", "protein"),
                comp("pfr3", "egg", 1, "each"),
                comp("pfr4", "soy_sauce", 15, "ml", "sauce"),
                comp("pfr5", "scallion", 10, "g", "veg"),
            ),
        ),
        Item("WRICE", "rice", {"en": "White rice", "zh": "白饭", "kitchen": "白饭"}),
        Variant("WRICE:side", "WRICE", "side", {"en": "Side"}, D("1.50")),
        Recipe("WRICE@1", "item", "WRICE", 1, (comp("wr1", "white_rice_cooked", 8, "oz", "starch"),)),
        Item("BRICE", "rice", {"en": "Brown rice", "zh": "糙米饭", "kitchen": "糙米饭"}),
        Variant("BRICE:side", "BRICE", "side", {"en": "Side"}, D("2.50")),
        Recipe("BRICE@1", "item", "BRICE", 1, (comp("brr1", "brown_rice_cooked", 8, "oz", "starch"),)),
        Item("WINGS", "sides", {"en": "Chicken wings", "zh": "鸡翅", "kitchen": "鸡翅"}),
        Variant("WINGS:6pc", "WINGS", "6pc", {"en": "6 pc"}, D("8.95")),
        Recipe(
            "WINGS@1",
            "item",
            "WINGS",
            1,
            (comp("w1", "chicken_wings", 6, "each", "protein"), comp("w2", "dried_chili", 2, "each", "spice")),
        ),
        Item(
            "C5",
            "combos",
            {"en": "Combination Plate", "zh": "套餐", "kitchen": "套餐"},
            kind="combo",
            aliases=("combo", "combination"),
        ),
        Variant("C5:regular", "C5", "regular", {"en": "Regular"}, D("14.50")),
        Recipe(
            "C5@1",
            "item",
            "C5",
            1,
            (
                comp("c5a", "fortune_cookie", 1, "each", "garnish", scales=False),
                comp("c5b", "combo_container", 1, "each", "packaging", scales=False),
            ),
        ),
        Item("PUPU", "sides", {"en": "Pu Pu Platter", "zh": "宝宝盘", "kitchen": "宝宝盘"}, aliases=("pupu",)),
        Variant("PUPU:regular", "PUPU", "regular", {"en": "Regular"}, D("16.95")),
        Recipe(
            "PUPU@1",
            "item",
            "PUPU",
            1,
            (
                comp("pp1", "EGGROLL:regular", 1, "each", kind="variant", locked=True),
                comp("pp2", "WINGS:6pc", 1, "each", kind="variant", defaults={"spice": "mild"}),
                comp("pp3", "SPRINGROLL:regular", "0.5", "each", kind="variant"),
                comp("pp4", "combo_container", 1, "each", "packaging", scales=False),
            ),
        ),
    )
    # --- menus
    defs.add(
        Menu("dinner", {"en": "Dinner", "zh": "晚餐"}, ("pos", "online", "phone"), {}, 0),
        Section("dinner/chefs", "dinner", {"en": "Chef's Specials", "zh": "招牌菜"}, sort=1),
        Section("dinner/combos", "dinner", {"en": "Combination Plates", "zh": "套餐"}, sort=2),
        Section("dinner/apps", "dinner", {"en": "Appetizers", "zh": "前菜"}, sort=0),
        Entry("dinner:87", "dinner", "dinner/chefs", "GTC", "87", ("GTC:pint", "GTC:quart"), sort=1),
        Entry("dinner:88", "dinner", "dinner/chefs", "BB", "88", ("BB:regular",), sort=2),
        Entry("dinner:C5", "dinner", "dinner/combos", "C5", "C5", sort=1),
        Entry("dinner:1", "dinner", "dinner/apps", "EGGROLL", "1", sort=1),
        Entry("dinner:2", "dinner", "dinner/apps", "SPRINGROLL", "2", sort=2),
        Entry("dinner:3", "dinner", "dinner/apps", "WINGS", "3", sort=3),
        Entry("dinner:4", "dinner", "dinner/apps", "PUPU", "4", sort=4),
        Entry("dinner:40", "dinner", "dinner/combos", "PFR", "40", ("PFR:regular",), sort=2),
        Menu(
            "lunch",
            {"en": "Lunch", "zh": "午餐"},
            ("pos", "phone"),
            {"weekly": [{"days": [1, 2, 3, 4, 5], "from": "11:00", "to": "15:00"}]},
            10,
        ),
        Section("lunch/specials", "lunch", {"en": "Lunch Specials", "zh": "午市特价"}, sort=1),
        Entry("lunch:L12", "lunch", "lunch/specials", "GTC", "L12", ("GTC:lunch",), {"GTC:lunch": D("10.95")}, sort=1),
        Entry("lunch:L13", "lunch", "lunch/specials", "BB", "L13", ("BB:lunch",), {"BB:lunch": D("10.95")}, sort=2),
    )
    return defs
