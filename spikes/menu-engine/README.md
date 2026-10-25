# Spike: the menu engine prices the worked example

**Question.** Does a Python package built from `docs/menu-engine-design.md` resolve the design's worked
example (General Tso's Chicken, quart, extra spicy, brown rice, add shrimp, from the dinner menu) to the
documented price, cost, allergens and kitchen label, and pass the design's property tests?

**Setup.** `backend/src/pos/menu` with the catalog, variants, modifier groups, menus and the resolver,
loaded from a fixture that holds the example data. Hypothesis tests for: price never negative, a
same-amount substitution keeps quantity, adding never removes an allergen.

**Pass.** The worked example and the C5 combination plate resolve exactly as the design states; the
property tests pass; a spreadsheet round-trip of the fixture is lossless.

**Result.** Pending.
