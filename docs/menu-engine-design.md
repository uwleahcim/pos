# Menu Engine Design

Oct 24, 2026 · @Michael Wu

## Goals and design principles

The menu engine is the single source of truth for what the restaurant sells, how each item can be configured, what it costs to make, and what it contains. Ordering, kitchen printing, inventory, the online storefront and reporting all read from it; none of them keep their own copy of the menu.

- **Everything is data, nothing is a special case.** One line-item model covers a plain item, a sized item, an item with modifiers, nested choices and a combination plate. A new menu shape means new rows, not new code.
- **Define once, present many ways.** The catalog (what exists) is separate from menus (where and when it shows, at what price, under what number). General Tso's Chicken is one item whether it is #87 on the dinner menu, L12 on the lunch menu, or a slot in a combo.
- **Resolve, don't store.** Prices, allergens, food cost and ingredient usage are computed from definitions plus the customer's choices. The database holds definitions and point-of-sale snapshots, never derived values that can drift.
- **Ingredients are the ground truth.** Allergens and costs flow up from ingredients through recipes. A dish's allergen profile changes correctly when a modifier adds shrimp or removes peanuts.
- **Safe by default.** The engine may infer that a dish contains an allergen, but it may only declare a dish free of one when every ingredient's allergen data is verified. Unknown is a first-class answer.
- **Progressive disclosure.** A sellable item needs a name and a price. Recipes, allergens, modifiers, schedules and translations are layers added later without restructuring anything.
- **History survives change.** An order line snapshots the name, price and recipe version at the time of sale, so reports and inventory depletion stay right after the menu changes.

## Where the engine sits

&#91;embedded content: menu engine boundaries · 1 upstream, 5 consumers\]

The engine is one in-process package in the modular monolith: the order, kitchen, inventory and reporting modules call it directly, FastAPI exposes the same calls to the POS, storefront and driver apps, and the only data it depends on from elsewhere is the ingredient master, which inventory maintains (stock, purchases, cost) and the engine reads (units, cost per unit, allergen declarations).

## Core concepts

A dozen nouns carry the whole design, held apart by two separations: catalog versus menu (what exists versus where it is shown), and definition versus resolution (what is stored versus what the engine computes per order line).

| Term | What it is | Example |
| --- | --- | --- |
| Item | A sellable thing in the catalog | General Tso's Chicken |
| Variant | A size or form of an item with its own price and recipe scale; every item has at least one, named Regular by default | Pint, Quart |
| Category | Groups items and holds defaults they inherit: tax class, kitchen station, modifier groups | Chef's Specials |
| Modifier group | A reusable question asked at order time, with selection rules (min, max, required, free count) | Spice level; Choice of rice |
| Modifier | One answer in a group; carries a price delta and recipe effects | Extra spicy; Sub brown rice (+$1.00) |
| Recipe effect | What a modifier does to the recipe: add, remove, substitute, scale, or a kitchen note only | Add shrimp adds 3 oz shrimp |
| Role | A label on a recipe component so effects can target it generically | protein, starch, sauce |
| Combo | An item whose modifier groups offer other items as choices (slots) | Combination Plate C5 |
| Menu | A presentation of catalog items for a channel and schedule, with its own sections, numbers and price overrides | Dinner (POS + online); Lunch, weekdays 11 to 3 |
| Menu entry | One item placed on one menu, with its number and optional price override | L12 is General Tso's Chicken at $10.95 |
| Ingredient | Anything a recipe consumes: stock (purchased) or prep (made in-house from its own recipe) | Chicken thigh (stock); General Tso sauce (prep) |
| Recipe | The components and quantities that make one variant or one batch of a prep; versioned | 6 oz chicken thigh, 3 oz sauce, 2 oz broccoli |
| Allergen profile | Per allergen: contains, may contain, free, or unknown, derived for a configured line | Contains wheat, soy; may contain shellfish |
| Resolved line | The engine's output for one configured order line: price, kitchen lines, ingredient usage, allergens, snapshot | Quart, extra spicy, sub brown rice |

## Catalog: categories, items, variants

An item is a name, a category and one or more variants; everything else is optional or inherited from the category.

**Categories** form a tree and carry defaults that items inherit: tax class, kitchen station, attached modifier groups, prep time. Attaching Choice of rice and Spice level to the Chef's Specials category gives every item in it both questions; an item can add groups of its own or explicitly exclude an inherited one. Resolution order for any inherited setting is item, then nearest ancestor category, then system default.

**Items** carry:

- `code`: a short internal handle such as `GTC`, stable across renames and menus
- `names`: one per locale plus a kitchen name, for example `{"en": "General Tso's Chicken", "zh": "左宗棠鸡", "kitchen": "左宗鸡"}`; the kitchen name is what prints on tickets
- `aliases`: search handles such as `general chicken`, `gtc`, pinyin, so POS lookup works however a cashier types it
- `kind`: `standard` or `combo` (combos are covered in their own section)
- `tax_class`, `station`, `prep_minutes`: all inheritable
- `tags`: free labels such as spicy, chef-special, new, popular, used for display badges and filtering
- `attrs`: a JSON bag for anything not yet modelled, so a new need never waits on a migration
- `description` and `image` per channel, since the storefront needs a photo and the POS button needs a short label

**Variants** are the unit the order line points at. Every item has at least one; a single-size item gets an implicit Regular variant, so the line model never has a special case for unsized items. A variant has a `name`, `base_price`, `sort`, an optional `plu`, and either its own recipe or a `recipe_scale` applied to the item's recipe (Quart = 2.0 × Pint, defined once). Reusable **variant sets** (Pint/Quart, Small/Large, 6 pc/12 pc) stamp the variants onto an item in one step; the operator then only types prices.

**Price** for a configured line is: the menu entry's override for that variant if one exists, otherwise the variant's `base_price`; plus modifier deltas; times quantity. The engine attaches the tax class; the order service applies tax rates, which belong outside the menu.

## Modifiers: groups, options, rules and recipe effects

A modifier group is a reusable question, a modifier is an answer with a price and a list of recipe effects, and the same machinery covers kitchen instructions, add-ons, substitutions and nested choices.

**Groups** carry the selection rules the engine enforces: `min_select`, `max_select` (null for unlimited), `free_count` (the first N selections cost nothing), `allow_quantity` (2 × extra chicken), `display` (inline buttons or a popup) and `sort`. A group is attached to an item or a category; each attachment can override sort, min/max, defaults, hide specific options, and override option prices (Add shrimp is +$3.00 on lo mein but +$4.00 on fried rice).

**Options** carry `names` per locale, a `kitchen_label` that prints on the ticket (usually short Chinese), `price_mode` (delta, absolute, or free), `price`, `default` (pre-selected), `max_qty`, `effects`, optional `child_groups` for nested questions, and an optional `linked_variant` when the option is really another catalog item (the combo case).

**Recipe effects** are what tie modifiers to inventory and allergens. Each effect targets either a named ingredient or a role on the recipe. Roles are the trick that keeps setup small: Sub brown rice is attached once to the whole entree category and replaces whichever component carries the `starch` role in each dish, with no per-dish configuration.

| Effect | Targets | What it does | Example |
| --- | --- | --- | --- |
| `add` | ingredient + qty | Adds a component | Add shrimp: +3 oz shrimp 31/40 |
| `remove` | role or ingredient | Drops matching components | No peanuts: remove role `nuts` |
| `substitute` | role → ingredient (+ qty) | Removes the role's components, adds the replacement | Sub brown rice: starch → 8 oz brown rice |
| `scale` | role or ingredient + factor | Multiplies the component quantity | Extra sauce: sauce × 1.5 |
| `note` | none | Prints the kitchen label only, no inventory effect | Sauce on side |

**Substitution, precisely.** `substitute` removes every component carrying the target role and adds the replacement. When `qty` is given, that quantity is used; when it is omitted, the replacement inherits the removed component's quantity, which the engine allows only when both share a unit dimension (mass for mass, count for count). If the recipe has no component with that role, the inventory effect is a no-op, the kitchen note still prints, and the admin screen warns at setup time ("3 items using this group have no `starch` role"). The price delta lives on the modifier and is independent of the recipe arithmetic. Allergens follow the components: the removed component's allergens leave `contains` unless another component carries them, the replacement's allergens arrive, and `may contain` from the station never drops.

**Nesting.** An option's `child_groups` ask further questions once it is chosen: Make it a combo → Choose a side → Choose a drink. Depth is unlimited in the model; the resolved tree records the full path, and the UI reveals one level at a time.

**Quantity.** When a group allows quantity, both the effects and the price delta multiply by the selection quantity, and `free_count` is consumed across the group's total units.

**Instructions.** An option whose only effect is `note` is a pure instruction (no MSG, sauce on side) with zero inventory impact. Free-text notes on a line are still allowed, but recurring instructions should be options so the kitchen always sees the same label in the same place.

## Menus: channels, schedules, sections, numbers, prices

A menu is a presentation: which items, in which sections, under which numbers, at which prices, on which channels and when. The same catalog serves every menu, so there is exactly one copy of each item to maintain.

- A **menu** has `channels` (pos, online, kiosk, phone), a `schedule` (weekly time windows plus optional date range), `active`, and a `priority` for when two menus overlap.
- A **section** tree per menu (Appetizers, Soups, Sushi → Maki) with names per locale, sort order, and display hints such as POS button colour or column count.
- A **menu entry** places one item in one section with the `number` customers order by (`87`, `L12`, `C5`), the variants offered on this menu, optional per-variant `price_override`, `visible`, `featured`, and an optional description or photo override.

| Menu | Section | Number | Item | Variants offered | Price |
| --- | --- | --- | --- | --- | --- |
| Dinner | Chef's Specials | 87 | General Tso's Chicken | Pint, Quart | base ($13.95 / $24.95) |
| Lunch | Lunch Specials | L12 | General Tso's Chicken | Lunch | override $10.95 |
| Dinner | Combination Plates | C5 | Combination Plate | Regular | base $14.50 |
| Online | Chef's Specials | 87 | General Tso's Chicken | Pint, Quart | base |

**Time-based pricing is just another menu.** Lunch is a menu with a schedule and its own entries, not a separate price-level system. One mechanism covers lunch specials, happy hour, holiday menus and a delivery menu with a markup.

**Numbers live on the entry, not the item.** The same dish is #87 at dinner and L12 at lunch, and may appear in two sections of one menu through two entries. Numbers are unique per menu, validated on save, and never changed by drag-and-drop reordering, because printed menus depend on them. Renumbering is a deliberate bulk operation.

**Overlap.** When two menus are active at once (Lunch from 11 to 3 inside an all-day Dinner menu), the POS shows both as tabs and number search looks in the higher-priority menu first. The engine never hides a menu because another one is active; that is a display decision left to the client.

**Resolution.** `menu_for(channel, at)` returns the active menus for that channel at that moment, each as sections → entries → variants with resolved prices, availability and allergen summaries, ready to render on a POS grid or the storefront.

## Combos and platters

A combo is an item whose modifier groups are slots, and a slot option is a link to a catalog variant; nothing else is new. Combination plates, lunch specials, family dinners and build-your-own platters all fall out of the modifier machinery plus one field, `linked_variant`.

**Slots.** Combination Plate C5 has three slots: Entree (General Tso's Chicken lunch portion, Beef with Broccoli, …), Side (Egg roll, Spring roll) and Rice (Pork fried rice, White rice, Brown rice +$1.00). Each slot is a modifier group attached to the combo with these settings:

- `min_select` / `max_select`, and `allow_duplicates` for platters that take three entrees, two of them the same
- `price_mode` for its options: `delta` (in-combo upcharge on top of the combo price, the default), `absolute` (the slot sets its own price), or `linked` (charge the variant's standalone price, for build-your-own bundles priced as parts minus a discount)
- `expose_linked_groups`: `all`, `none`, or a list, deciding which of the linked item's own modifier groups the customer is asked about inside the combo
- `default`: the pre-selected option, so a combo with sensible defaults rings in with one tap

**Slot defaults and per-component customization.** Defaults resolve most-specific-first: the slot's `child_defaults` for the linked item's groups, then the linked item's own attachment defaults (Spice level defaults to Medium on General Tso's everywhere), then the option's `default` flag. A slot with a default is valid unanswered; a required slot with no default must be answered. Choosing a different slot option is a substitution between components; Sub brown rice inside the entree is a substitution within a component through roles. Both work at the same time and neither needs combo-specific configuration. The request addresses the nested item through the choice that produced it: a `Selection` for the slot carries `children` (answers to the linked item's own groups) and `components` (customizations of items nested in the linked item's recipe), and a `ComponentRequest` does the same for an item nested in a recipe. The slot's `expose_linked_groups: none` locks the linked item against customization.

**Portions.** A slot option points at a specific variant, which is how a combo gets the lunch portion of a dish without duplicating the item or its recipe.

**Pricing.** `combo.base_price` plus each slot option's price under the slot's `price_mode`, plus any nested modifier deltas on the components (Add shrimp on the combo's entree is still +$3.00).

**Kitchen, inventory, allergens.** The resolved tree carries one child line per slot selection, each with its own station, recipe explosion and allergen profile. Tickets group the children under the combo header with its number; the entree routes to the wok, the egg roll to the fryer. The combo's own recipe holds only shared components (a fortune cookie, a container), and its allergen profile is the union of its children's.

## Recipes and inventory

Recipes connect every variant to the ingredient master, and exploding a resolved line yields stock-ingredient quantities for depletion and a theoretical cost for margin reporting.

**Ingredient master.** One table, shared with the inventory module: the menu engine reads it, inventory owns stock levels, purchases and counts. An ingredient has a `code`, `names`, a `kind` of `stock` (purchased) or `prep` (made in-house), a `base_unit` (g, ml or each), a `category` (protein, produce, dry, sauce, packaging), `cost_per_base_unit` maintained by inventory from purchases and entered the way the invoice reads (a purchase pack: a case of 240 pint containers for $36 is $0.15 each, and at 98% yield $0.1531 per container used), a `yield_pct` for trim and cook loss (raw chicken thigh at 85% usable), its allergen declarations, `track_stock`, and `critical` for ingredients whose stock-out should auto-86 the dishes that use them. A prep ingredient carries its own recipe with a batch yield: General Tso sauce makes 4,000 ml from soy, sugar, vinegar, cornstarch, garlic and ginger. Preps nest, so a stock feeds a soup base that feeds wonton soup. A cut is the simplest prep: one source ingredient and a yield (red pepper chunks and strips are each red pepper at 85%; fine dice is strips at 99%), stored as a one-line recipe so a dish that uses 1 oz of chunks explodes to 33 g of raw pepper and 1 kg of dice to 1,188 g, each step's yield applied in turn. The loss lives in the cut, and \`yield\_pct\` on the raw ingredient applies only when it is used as bought, so nothing is counted twice.

**Units.** A `unit` table holds `code`, `dimension` (mass, volume, count) and the factor to the base unit (oz → 28.35 g, lb → 453.6 g, cup → 236.6 ml, tbsp → 14.79 ml). Recipes are written in whatever unit the cook thinks in and converted at explosion. Cross-dimension conversions live on the ingredient: `each_grams` (one egg is 50 g) and `grams_per_ml` (sauce measured by the cup, bought by weight). A recipe that uses a unit the ingredient cannot convert is refused at save time with the reason, never silently mis-counted.

**Recipes.** A recipe belongs to exactly one owner: an item (shared by its variants through `recipe_scale`), a single variant (when sizes differ in kind, not amount), or a prep ingredient. It holds `yield_qty` and `yield_unit` (1 for a dish, the batch size for a prep), free-text method notes for training, and its components: `ingredient`, `qty`, `unit`, `role` (protein, starch, sauce, veg, garnish, nuts, packaging; free text with a suggested vocabulary), `optional`, and `sort`.

**Nested items.** A component is either an ingredient or another item's variant. A Pu Pu Platter lists two Egg roll variants and six wings as fixed components; there is no slot because the customer makes no choice, and the egg roll's recipe is never duplicated as a prep. A nested item is resolved as a child line of its own, exactly like a combo slot choice: it keeps its own modifier groups, so the customer can customize it in place (extra spicy wings inside the platter), and it contributes its own kitchen line, ingredient usage and allergens. Its price is included in the parent (unit price 0, `price_source` `included`); only its modifiers can add cost. The recipe line can preset the nested item's defaults for this dish only (`1 WINGS/6pc (appetizer, spice=mild)`) or mark it `locked`, in which case a customization request comes back as a problem rather than being applied silently. Nesting is unlimited in both directions (a prep inside a dish inside a platter inside a combo), and the save-time validator rejects any cycle. A fractional portion of another dish (0.5 EGGROLL) is exploded inline instead and cannot be customized.

**Versioning.** Saving a recipe writes a new immutable version and marks it current; the old version stays. An order line records the `recipe_version_id` it was sold under, so depletion and cost reports for past orders use the recipe that was actually in effect.

**Explosion.** Given a resolved line:

1. Take the variant's recipe, scaled by `recipe_scale` and line quantity.
2. Apply the selected modifiers' effects in order: add, remove, substitute, scale, by role or by ingredient.
3. Recurse into child lines (combo slots, nested options with a linked variant).
4. Expand each prep or nested-variant component through its own current recipe (a prep by quantity over batch yield, a variant by its count and recipe scale) until only stock ingredients remain.
5. Convert to each ingredient's base unit, divide by `yield_pct` to get the purchased quantity, and aggregate by ingredient.

The result is a list of (ingredient, quantity in base unit, cost). Inventory posts a depletion per closed order (or per day in batch), and reporting compares theoretical usage to physical counts to find variance.

**Costing.** Line cost is the sum of exploded quantity × `cost_per_base_unit`; prep cost is its batch cost over its yield. The admin screen shows food cost and margin beside every variant price and every menu entry, so the lunch price and the dinner price of the same dish each show their own margin. An ingredient price change updates every theoretical cost at once with no recipe edits.

## Allergens and dietary attributes

Allergens are declared once, on ingredients, and derived everywhere else; the engine answers contains, may contain, free or unknown per allergen, and only answers free when the data has earned it.

**Reference list.** The `allergen` table holds the nine US major allergens (milk, eggs, fish, crustacean shellfish, tree nuts, peanuts, wheat, soybeans, sesame) plus anything the restaurant chooses to track, such as gluten, molluscan shellfish, MSG, pork or alcohol, each with `code`, `names` per locale, `is_major` and `sort`.

**Declarations on ingredients.** `ingredient_allergen` rows carry `allergen`, `level` (`contains` or `may_contain`), `verified`, and a `source` (label photo, supplier spec sheet, date). An ingredient also has `allergens_reviewed_at`: until someone has reviewed it, the absence of a declaration means unknown, not free. This single rule is what makes the whole system safe to rely on.

**Cross-contact by station.** Each kitchen station lists its `cross_contact` allergens: the fryer carries crustacean shellfish, fish and wheat; the sushi bar carries fish, shellfish and sesame. Every line routed through a station picks up those allergens as `may_contain`, and no modifier can remove them.

**Overrides.** `item_allergen_override` rows (on an item or a variant) set an allergen to `contains`, `may_contain` or `free` with a reason, for what ingredients cannot express: a dish finished in shared peanut oil, or one the chef guarantees in a dedicated pan. A `free` override is a deliberate act that beats station cross-contact and is logged.

**Derivation for a configured line:**

1. Explode the recipe after modifier effects down to stock ingredients.
2. `contains` is the union of their `contains` declarations; `may_contain` is the union of their `may_contain` declarations plus the cross-contact of every station the line touches.
3. Apply overrides, item level then variant level.
4. Every other tracked allergen is `free` if every exploded ingredient has been reviewed, otherwise `unknown`.
5. For a combo, union the children and keep the per-child detail.

| State | Meaning | Shown as |
| --- | --- | --- |
| contains | A reviewed or declared ingredient contains it | Contains: wheat, soy |
| may contain | Declared trace, or station cross-contact | May contain: shellfish |
| free | Reviewed ingredients, none declare it, no cross-contact | Peanut-free badge |
| unknown | At least one ingredient not yet reviewed | Ask staff |

**Dietary attributes** (vegetarian, vegan, gluten-free, no pork) are claims evaluated by rule over ingredient `dietary_tags` (meat, fish, shellfish, dairy, egg, honey, gluten, pork, alcohol): vegetarian means no meat, fish or shellfish tag; vegan adds no dairy, egg or honey. Each evaluates to true, false or unknown by the same reviewed-ingredient rule. Spice level is a plain tag, not a dietary rule.

**Where it shows.** The storefront prints the contains and may-contain lists per item and previews each modifier's effect (Add shrimp adds shellfish). The POS shows a badge when a line conflicts with an allergy noted on the order. The kitchen ticket prints the order's allergy note in bold on every station's copy. A cached profile per unmodified variant is invalidated through a reverse index from ingredient to variants whenever an ingredient, override or station changes.

## Availability, 86 state, kitchen routing, localization

Definitions and live state are kept apart: menus and schedules say when something is normally sold, and a small, fast 86 table says what is sold out right now.

**Availability rules.** Menu schedules cover normal hours. An item or entry can add a rule of its own: days and times, a date range for seasonal dishes (soft-shell crab from May to September), channels (not offered for delivery), and a lead time for dishes that need notice.

**86 state.** `availability_state` is keyed by variant or modifier option and holds `status` (`available`, `sold_out`, `hidden`), `until` (end of service, a specific time, or until cleared), `reason`, `set_by` and `set_at`. It is cached in memory and pushed to every client over server-sent events, so the storefront and every POS screen reflect an 86 within a second. Expired entries clear themselves. Options can be 86'd too, so running out of brown rice removes one choice rather than a dish.

**Auto-86.** When inventory reports a `critical` ingredient at zero on hand, the engine finds every dependent variant through the reverse index and marks it `sold_out` with the reason `stock: soft-shell crab`; a restock clears it. This is opt-in per ingredient and off by default, because counts drift and a false 86 costs sales.

**Kitchen routing.** A `station` (wok, fryer, sushi, cold, drinks, expo) has its printers and its cross-contact list. Items get a station by inheritance; a modifier can add one (Add fried rice sends a second line to the wok). A resolved line yields `kitchen_lines`: one per station with quantity, the kitchen name, modifier kitchen labels, the order's allergy note, and a course or fire tag. Combo children print under the combo header with its number. Prep minutes per item feed quote times for takeout and delivery.

**Localization and display.** Items, variants, groups, options, sections and allergens all carry `names` per locale; every engine call takes a `locale` and falls back to English. The kitchen name is its own key, not a locale, because it is a short label chosen for the ticket, not a translation. Display hints are per channel: a short label, colour and position for the POS grid, a description, photo and tag badges for the storefront, and whether Chinese names print on the customer receipt.

## The resolved tree and the engine API

The engine's one real output is a `ResolvedLine`: an immutable tree that carries price, kitchen lines, ingredient usage, allergens and a snapshot for one configured order line, so every downstream module reads the same object and none of them re-derive anything.

**Input.** The order client sends what the customer chose and nothing else:

```python
@dataclass(frozen=True)
class ComponentRequest:            # customization of an item nested in a recipe
    component_id: str              # the recipe component, from item_detail
    selections: tuple["Selection", ...] = ()
    components: tuple["ComponentRequest", ...] = ()
    notes: str | None = None

@dataclass(frozen=True)
class Selection:
    group_id: str
    option_id: str
    qty: int = 1
    children: tuple["Selection", ...] = ()       # nested groups, or a slot's linked item's groups
    components: tuple[ComponentRequest, ...] = () # a slot's linked item's nested components

@dataclass(frozen=True)
class LineRequest:
    variant_id: str
    qty: int = 1
    menu_entry_id: str | None = None         # which menu it was ordered from
    selections: tuple[Selection, ...] = ()
    components: tuple[ComponentRequest, ...] = ()
    notes: str | None = None
```

**Output.** Resolution is a pure function of (definitions as of now, request, time, locale):

```python
@dataclass(frozen=True)
class ResolvedLine:
    variant_id: str
    menu_entry_id: str | None
    qty: int
    names: Mapping[str, str]                 # by locale, plus "kitchen"
    unit_price: Decimal                      # entry override, variant base, or 0 when nested
    price_source: str                        # "entry_override" | "variant_base" | "slot" | "included"
    modifiers: tuple[ResolvedModifier, ...]
    children: tuple["ResolvedLine", ...]     # slot choices and nested recipe items
    line_total: Decimal                      # (unit_price + deltas + children) * qty
    tax_class: str
    kitchen_lines: tuple[KitchenLine, ...]   # one per station touched; children carry parent + origin
    usage: tuple[IngredientUsage, ...]       # stock ingredients, base units, yield applied
    allergens: AllergenProfile               # contains / may_contain / free / unknown + sources
    cost: Decimal
    snapshot: Snapshot                       # recipe_version_id, resolved_at, engine_version
    problems: tuple[Problem, ...]            # unanswered required group, 86'd option, locked, ...
    origin: str = "line"                     # "line" | "slot" | "component"
    component_id: str | None = None          # recipe component this child came from
    option_id: str | None = None             # slot option this child came from
    locked: bool = False

@dataclass(frozen=True)
class ResolvedModifier:
    group_id: str
    option_id: str
    qty: int
    kitchen_label: str
    price_delta: Decimal
    effects_applied: tuple[EffectResult, ...]  # what changed, no-ops noted
    children: tuple["ResolvedModifier", ...]
```

Three rules make the contract hold: every derived value carries its provenance (`price_source`, allergen sources, effect results), validation failures come back as `problems` so a UI can show them inline rather than catching exceptions, and the order service stores the resolved line as JSON on the order, so reprints, refunds and reports never recompute against a changed menu.

**API.** The engine is an in-process Python package; FastAPI exposes it for the POS, storefront and driver apps, and the order, kitchen and inventory modules call it directly inside the monolith.

```python
class MenuEngine:
    # presentation
    def menu_for(self, channel: str, at: datetime | None = None, locale: str = "en") -> list[ResolvedMenu]
    def search(self, query: str, channel: str | None = None) -> list[Hit]      # number, name, alias, zh, pinyin
    def item_detail(self, item_id: str, menu_entry_id: str | None = None) -> ItemDetail

    # ordering
    def resolve(self, request: LineRequest, at: datetime | None = None, locale: str = "en") -> ResolvedLine
    def validate(self, request: LineRequest) -> list[Problem]

    # inventory and reporting
    def explode(self, line: ResolvedLine) -> list[IngredientUsage]
    def cost(self, variant_id: str, selections: tuple[Selection, ...] = ()) -> CostBreakdown
    def dependents(self, ingredient_id: str) -> list[str]                      # variants that use it

    # live state
    def set_availability(self, target_id: str, status: str, until: datetime | None = None, reason: str | None = None, by: str | None = None) -> None
    def availability_stream(self) -> AsyncIterator[AvailabilityEvent]

    # authoring
    def save_item(...); def save_recipe(...); def attach_group(...)
    def import_sheet(path) -> ImportReport; def export_sheet() -> Path
```

The pipeline inside `resolve` is load → validate → price → route → explode → derive allergens → snapshot, each step a small pure function over the loaded definitions, which is also what makes the engine easy to test with fixtures and no database.

## Worked example

One order line, a Quart of General Tso's Chicken, extra spicy, brown rice, add shrimp, resolves to $29.95, seven stock ingredients, a food cost near 24%, and an allergen profile that correctly adds shellfish and refuses to call anything free. Quantities, prices and costs below are illustrative.

**Definitions.** Item `GTC` in Chef's Specials (station wok; inherited groups Spice level and Choice of rice). Variants: Pint $13.95 at scale 1.0, Quart $24.95 at scale 2.0, Lunch $10.95 at scale 0.75. Recipe per Pint: 6 oz chicken thigh (protein), 90 ml General Tso sauce prep (sauce), 2 oz broccoli (veg), 8 oz cooked white rice prep (starch), 3 dried chilies (spice), 1 pint container (packaging, marked non-scaling; the Quart variant overrides it to a quart container). Modifiers: Extra spicy scales the `spice` role × 2; Brown rice (+$1.00) substitutes the `starch` role with cooked brown rice prep and no quantity, so it inherits the amount it replaces; Add shrimp (+$4.00) adds 3 oz shrimp, a fixed add-on amount that does not scale with the variant.

**Price.** Quart base $24.95 (no dinner-menu override, so `price_source` is `variant_base`) + $0 + $1.00 + $4.00 = **$29.95**.

**Explosion.** Scale the Pint recipe by 2.0, apply the three effects, expand the two preps by their share of a batch, convert to base units, apply yield.

| Ingredient | Role | Quantity | Cost |
| --- | --- | --- | --- |
| Chicken thigh, raw | protein | 340 g used, 400 g at 85% yield | $2.64 |
| Shrimp 31/40 | protein (added) | 85 g | $1.87 |
| Broccoli | veg | 113 g used, 126 g at 90% yield | $0.55 |
| Soy sauce, sugar, rice vinegar, cornstarch, garlic, ginger | sauce, 180 ml of a 4,000 ml batch | 4.5% of the batch | $0.54 |
| Brown rice, raw | starch (substituted) | 151 g, from 454 g cooked at the prep's 3:1 yield | $0.50 |
| Dried chili | spice, × 2 | 12 each | $0.60 |
| Quart container | packaging | 1 each | $0.35 |

Total theoretical cost $7.05, food cost 23.5% of $29.95. White rice does not appear: the substitution removed it before explosion.

**Allergens.** Soy sauce declares wheat and soybeans; shrimp declares crustacean shellfish; the wok station lists sesame and peanuts as cross-contact. Dried chili has not been reviewed yet. Result: **contains** wheat, soybeans, crustacean shellfish; **may contain** sesame, peanuts; every other allergen **unknown**, so the storefront shows no free-from badges until someone reviews the chili. Review it, and milk, eggs, fish and tree nuts flip to free with no other change.

**Kitchen.** One line to the wok: `1 左宗鸡 (Qt) · 加辣 · 糙米 · 加虾`, with the order's allergy note if any.

**Combo.** Combination Plate C5 at $14.50 with slots Entree, Side and Rice. The cashier taps C5 and the defaults fill: Entree General Tso's Chicken (Lunch variant, delta $0, Spice level Medium inherited from the item's own default), Side Egg roll, Rice Pork fried rice. Price $14.50. The resolved line has three children. The wok gets the entree and the fried rice, the fryer gets the egg roll, all three printed under `C5`. Allergens are the union: the egg roll adds wheat and eggs to `contains`, and the fryer's cross-contact adds fish and crustacean shellfish to `may contain`. Explosion is the sum of the three children's usage plus the combo's own fortune cookie and container.

## Keeping it simple to operate

Simplicity comes from defaults, inheritance and reuse rather than from hiding features: the minimum item is two fields, and each further layer adds capability without reworking what is already there.

| Layer | What you enter | What you get |
| --- | --- | --- |
| 1. Sell | Item name, price, category; a menu with numbers | POS, storefront and tickets work; tax and station come from the category |
| 2. Configure | Modifier groups attached to categories | Sizes, spice levels, rice choices, add-ons on every item at once |
| 3. Cost | Ingredients with prices; recipes with roles | Food cost and margin per variant and per menu; theoretical usage per order |
| 4. Declare | Allergen declarations and ingredient reviews | Contains / may contain on every item, free-from badges where earned |
| 5. Automate | Critical ingredients, schedules, reverse index | Auto-86, seasonal menus, instant allergen and cost updates |

**Defaults and inheritance.** Categories supply tax class, station, prep time and modifier groups. Variant sets stamp Pint/Quart onto an item in one click. Roles let one Sub brown rice option serve eighty entrees. A new dish in Chef's Specials is correct the moment it has a name and a price.

**Reuse.** One modifier library, one prep library, one ingredient master shared with inventory. Duplicate item copies everything including the recipe. Where used on any ingredient, prep or group shows every item it touches before you change it.

**Spreadsheet round-trip.** Export the whole catalog (items, variants, prices, menu numbers, groups, recipes) to a workbook, edit it, and re-import with a dry run that reports the diff: 12 prices changed, 3 new items, 1 error. This is both the initial load from the current POS item list and the way a seasonal price change happens.

**Validation that explains itself.** Saves are refused with the reason, never accepted silently: a unit the ingredient cannot convert, a duplicate menu number, a required group with no options, a role an attached modifier targets that the recipe lacks, a free-from claim resting on an unreviewed ingredient.

**Back-of-house screens** (HTMX): Catalog, Menus with drag-and-drop sections where numbers stay put, Modifier library, Ingredients and recipes with a live cost and allergen preview as you type, an Allergen review queue listing unreviewed ingredients, an 86 board for one-tap sold-outs, and an audit log with undo of the last change to any definition.

**Rollout order.** Week one: items, prices, menus, and you can sell. Week two: modifier groups by category. Month one: ingredients and recipes for the top fifty sellers, which already covers most of the cost. Then allergen review, one ingredient at a time, with the queue showing how many dishes each review unlocks.

## Schema sketch

Nineteen tables cover the whole engine; names, effects and schedules live in JSONB so new attributes never wait on a migration, while everything the engine joins on is a real column.

```sql
create type owner_kind      as enum ('item','variant','ingredient','category');
create type ingredient_kind as enum ('stock','prep');
create type allergen_level  as enum ('contains','may_contain','free');
create type avail_status    as enum ('available','sold_out','hidden');

create table station (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null,
  names         jsonb not null,                         -- {"en": "Wok", "zh": "炒锅"}
  printers      text[] not null default '{}',
  cross_contact text[] not null default '{}'            -- allergen codes
);

create table category (
  id           uuid primary key default gen_random_uuid(),
  parent_id    uuid references category,
  code         text unique not null,
  names        jsonb not null,
  tax_class    text,
  station_id   uuid references station,
  prep_minutes int,
  sort         int not null default 0,
  active       boolean not null default true
);

create table item (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,                     -- 'GTC'
  category_id  uuid not null references category,
  kind         text not null default 'standard' check (kind in ('standard','combo')),
  names        jsonb not null,                           -- {"en", "zh", "kitchen"}
  aliases      text[] not null default '{}',
  description  jsonb not null default '{}',              -- per channel and locale
  tax_class    text,                                     -- null = inherit
  station_id   uuid references station,                  -- null = inherit
  prep_minutes int,
  tags         text[] not null default '{}',
  attrs        jsonb not null default '{}',
  active       boolean not null default true,
  sort         int not null default 0
);

create table item_variant (
  id                  uuid primary key default gen_random_uuid(),
  item_id             uuid not null references item on delete cascade,
  code                text not null,                     -- 'regular','pint','quart','lunch'
  names               jsonb not null,
  base_price          numeric(10,2) not null,
  recipe_scale        numeric(8,4) not null default 1,
  component_overrides jsonb not null default '[]',       -- [{"role":"packaging","ingredient":"qt_container","qty":1,"unit":"each"}]
  plu                 text,
  sort                int not null default 0,
  active              boolean not null default true,
  unique (item_id, code)
);

create table modifier_group (
  id               uuid primary key default gen_random_uuid(),
  code             text unique not null,
  names            jsonb not null,
  min_select       int not null default 0,
  max_select       int,                                  -- null = unlimited
  free_count       int not null default 0,
  allow_quantity   boolean not null default false,
  allow_duplicates boolean not null default false,
  display          text not null default 'inline',
  sort             int not null default 0
);

create table modifier_option (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references modifier_group on delete cascade,
  code              text not null,
  names             jsonb not null,
  kitchen_label     text,
  price_mode        text not null default 'delta' check (price_mode in ('delta','absolute','free','linked')),
  price             numeric(10,2) not null default 0,
  is_default        boolean not null default false,
  max_qty           int,
  effects           jsonb not null default '[]',         -- [{"op":"substitute","role":"starch","ingredient":"brown_rice_cooked"}]
  linked_variant_id uuid references item_variant,        -- set for combo slot options
  child_group_ids   uuid[] not null default '{}',
  sort              int not null default 0,
  active            boolean not null default true,
  unique (group_id, code)
);

create table modifier_attachment (                       -- group attached to an item or a category
  id         uuid primary key default gen_random_uuid(),
  owner_kind owner_kind not null check (owner_kind in ('item','category')),
  owner_id   uuid not null,
  group_id   uuid not null references modifier_group,
  overrides  jsonb not null default '{}',                -- min, max, default, hidden options, price overrides, expose_linked_groups, child_defaults
  excluded   boolean not null default false,             -- item opts out of an inherited group
  sort       int not null default 0,
  unique (owner_kind, owner_id, group_id)
);

create table menu (
  id       uuid primary key default gen_random_uuid(),
  code     text unique not null,
  names    jsonb not null,
  channels text[] not null,                              -- {pos, online, kiosk, phone}
  schedule jsonb not null default '{}',                  -- {"weekly":[{"days":[1,2,3,4,5],"from":"11:00","to":"15:00"}],"from":null,"to":null}
  priority int not null default 0,
  active   boolean not null default true
);

create table menu_section (
  id        uuid primary key default gen_random_uuid(),
  menu_id   uuid not null references menu on delete cascade,
  parent_id uuid references menu_section,
  names     jsonb not null,
  display   jsonb not null default '{}',
  sort      int not null default 0
);

create table menu_entry (
  id              uuid primary key default gen_random_uuid(),
  menu_id         uuid not null references menu on delete cascade,
  section_id      uuid not null references menu_section,
  item_id         uuid not null references item,
  number          text,                                  -- '87', 'L12', 'C5'
  variant_ids     uuid[],                                -- null = every active variant
  price_overrides jsonb not null default '{}',           -- {"<variant_id>": "10.95"}
  availability    jsonb not null default '{}',
  visible         boolean not null default true,
  featured        boolean not null default false,
  display         jsonb not null default '{}',
  sort            int not null default 0,
  unique (menu_id, number)
);

create table availability_state (                        -- live 86 board
  target_id uuid primary key,                            -- item_variant.id or modifier_option.id
  status    avail_status not null,
  until     timestamptz,
  reason    text,
  set_by    text,
  set_at    timestamptz not null default now()
);

create table unit (
  code      text primary key,                            -- g, kg, oz, lb, ml, l, tsp, tbsp, cup, each
  dimension text not null check (dimension in ('mass','volume','count')),
  to_base   numeric(14,6) not null                       -- factor to g, ml or each
);

create table allergen (
  code     text primary key,                             -- milk, egg, fish, crustacean, tree_nut, peanut, wheat, soy, sesame, ...
  names    jsonb not null,
  is_major boolean not null default false,
  sort     int not null default 0
);

create table ingredient (                                -- shared with inventory; inventory owns stock and cost
  id                    uuid primary key default gen_random_uuid(),
  code                  text unique not null,
  names                 jsonb not null,
  kind                  ingredient_kind not null,
  category              text,
  base_unit             text not null references unit,
  each_grams            numeric(10,3),
  grams_per_ml          numeric(10,4),
  yield_pct             numeric(5,2) not null default 100,
  cost_per_base_unit    numeric(12,6) not null default 0,
  dietary_tags          text[] not null default '{}',    -- meat, fish, shellfish, dairy, egg, honey, gluten, pork, alcohol
  allergens_reviewed_at timestamptz,                     -- null = allergens unknown
  track_stock           boolean not null default true,
  critical              boolean not null default false,
  active                boolean not null default true
);

create table ingredient_allergen (
  ingredient_id uuid not null references ingredient on delete cascade,
  allergen_code text not null references allergen,
  level         allergen_level not null check (level <> 'free'),
  verified      boolean not null default false,
  source        text,
  primary key (ingredient_id, allergen_code)
);

create table item_allergen_override (
  id            uuid primary key default gen_random_uuid(),
  owner_kind    owner_kind not null check (owner_kind in ('item','variant')),
  owner_id      uuid not null,
  allergen_code text not null references allergen,
  level         allergen_level not null,
  reason        text not null,
  set_by        text,
  set_at        timestamptz not null default now()
);

create table recipe (                                    -- one row per version; owner is an item, a variant, or a prep ingredient
  id         uuid primary key default gen_random_uuid(),
  owner_kind owner_kind not null,
  owner_id   uuid not null,
  version    int not null,
  yield_qty  numeric(12,3) not null default 1,
  yield_unit text references unit,
  notes      text,
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text,
  unique (owner_kind, owner_id, version)
);
create unique index recipe_current on recipe (owner_kind, owner_id) where is_current;

create table recipe_component (
  id            uuid primary key default gen_random_uuid(),
  recipe_id     uuid not null references recipe on delete cascade,
  component_kind text not null default 'ingredient' check (component_kind in ('ingredient','variant')),
  ingredient_id  uuid references ingredient,             -- set when component_kind = 'ingredient'
  variant_id     uuid references item_variant,           -- set when component_kind = 'variant': a fixed nested item, e.g. two egg rolls on a platter
  qty           numeric(12,4) not null,
  unit          text not null references unit,
  role          text,                                    -- protein, starch, sauce, veg, spice, packaging
  optional      boolean not null default false,
  scales        boolean not null default true,           -- false for packaging and fixed garnish
  sort          int not null default 0
);
create index recipe_component_ingredient on recipe_component (ingredient_id);   -- reverse index for allergen cache and auto-86
create index recipe_component_variant    on recipe_component (variant_id);      -- which platters nest this dish

create table audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      text,
  table_name text not null,
  row_id     uuid not null,
  action     text not null,
  before     jsonb,
  after      jsonb
);
```

The order module's line table, outside this engine, stores the `ResolvedLine` as JSONB beside `variant_id`, `recipe_version_id` and `menu_entry_id`. Search uses a `pg_trgm` GIN index over names and aliases; a small pinyin column generated at save time lets a cashier type `zzt` for 左宗棠.

## Implementation plan and open decisions

Build the resolver as a pure Python package first, tested against in-memory fixtures, and put PostgreSQL, FastAPI and the screens around it second; the first usable milestone is selling from a menu with numbers and prices, and every later milestone adds a layer without touching the ones before.

1. **Package `menu_engine`**: frozen dataclasses for definitions and the resolved tree; `resolve()` over an in-memory definition set; the worked example as a golden test; property tests (a price is never negative, a same-amount substitution conserves quantity, `add` never removes an allergen).
2. **Storage**: the schema above with Alembic migrations, a repository that loads one definition snapshot per channel and time, and a cache invalidated from `audit_log`.
3. **API**: `GET /menus`, `GET /items/{id}`, `POST /lines/resolve`, `PUT /availability`, `GET /availability/stream` (SSE), plus admin CRUD; the order, kitchen and inventory modules call the package directly.
4. **Import and export**: the workbook round-trip with a dry-run diff, used for the initial load from the current item list.
5. **Back-of-house screens**: catalog, menus, modifier library, recipes with live preview, allergen review queue, 86 board.
6. **Consumers**: the order module stores the resolved line; kitchen printing reads `kitchen_lines`; inventory posts `usage`; the storefront renders `menu_for`.

A `menu check` command runs every validation across the whole catalog (duplicate numbers, missing roles, unconvertible units, unreviewed ingredients behind a free-from claim) and is part of CI once the data is in.

**Decisions to confirm**

- [ ] Ingredient master lives in one shared table that inventory owns and the menu engine reads (recommended), rather than a copy per module.
- [ ] Lunch, delivery and holiday pricing are separate menus (recommended), not a price-level system.
- [ ] Money is `numeric(10,2)`, rounded half-up per line; tax is applied by the order module.
- [ ] Locales are `en` and `zh` plus a typed `kitchen` label, and the kitchen label is whatever script the kitchen reads.
- [ ] Single location for now; `location_id` on `menu` and `availability_state` is a cheap later addition.
- [ ] The `linked` combo price mode ships later unless a build-your-own bundle is needed at launch.
- [ ] Auto-86 stays opt-in per ingredient.
