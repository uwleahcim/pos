# Spike: the menu engine prices the worked example

**Question.** Does a Python package built from `docs/menu-engine-design.md` resolve the design's worked
example (General Tso's Chicken, quart, extra spicy, brown rice, add shrimp, from the dinner menu) to the
documented price, cost, allergens and kitchen label, and pass the design's property tests?

**Setup.** `backend/src/pos/menu`: definitions (`defs.py`), the request and resolved shapes (`request.py`,
`resolved.py`), the resolver (`engine.py`), the spreadsheet round-trip for the sell layer (`sheet.py`) and
the design's example catalog as a fixture (`fixtures/example.py`). Tests in `backend/tests/menu`.

```
cd backend && uv pip install -e '.[dev]' && pytest tests/menu
```

**Pass.** The worked example and the C5 combination plate resolve exactly as the design states; the
property tests pass; a spreadsheet round-trip of the fixture is lossless.

**Result (2026-10-25): passed in software.** 39 tests, all green, lint clean.

The worked example, `GTC:quart` on `dinner:87` with extra spicy, brown rice and add shrimp:

| What | Engine | Design |
| --- | --- | --- |
| Unit price | 24.95 (variant base) + 0.00 + 1.00 + 4.00 = 29.95 | 29.95 |
| Chicken thigh | 340.20 g used, 400.24 g purchased (85% yield) | 340 g / 400 g |
| Shrimp (added) | 85.05 g | 85 g |
| Brown rice (substituted for white, same quantity) | 151.20 g raw | 151 g |
| Dried chili (spice role scaled x2, quart x2) | 12 | 12 |
| Sauce ingredients | soy 67.5 ml, sugar 36 g, vinegar 36 ml, cornstarch 9 g, garlic and ginger 6.75 g each | same |
| Line cost | 7.05 | 7.05 |
| Food cost | 23.5% | 23.5% |
| Allergens | contains crustacean, soy, wheat; may contain peanut, sesame (wok station); the rest unknown because dried chili is unreviewed | same |
| Kitchen line (zh-Hans kitchen label) | `1 左宗鸡 (Qt) · 加辣 · 糙米 · 加虾` at the wok | same |

Also covered: the C5 combination plate (entree slot exposes the entree's modifiers, side and rice slots do
not; the combo's own kitchen line gives way to its children under a `C5` header), the pupu platter (locked
egg rolls, wings with a preset spice default, half a spring roll exploded inline), the lunch menu by schedule
and priority with its price override, search by number, code, alias and name across languages, item detail
with the question tree, dependents through preps and combo slots, every `menu check` validation on a broken
catalog, sold-out windows, and a lossless Items/Variants/Menu entries spreadsheet round-trip with a dry-run
diff report.

Hypothesis properties: the price is never negative and equals the sum of its parts; usage is exactly linear in
the line quantity; a same-amount substitution keeps the quantity; adding an option never removes an allergen;
the kitchen line always carries the selected labels.

Two things the design left open and the spike settled, written into the code:

- Ingredient costs stay exact in usage and are rounded once at the line, so the sauce's six ingredients sum
  to the design's 0.54 instead of a cent short.
- A rejected choice (sold out, hidden, unknown) still counts toward a group's minimum, so the order taker
  sees the real problem and not a second "too few" on top of it.
