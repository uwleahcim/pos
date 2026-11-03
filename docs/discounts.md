# Discounts, comps and service charges

What moves a price after the menu has set it (architecture page, section 9), as built for phase 1. The
rules are data on the hub; the app only shows what the rules allow and the hub refuses anything else.

## On the order screen

Tap **Discount** on an open check.

1. **Reason.** One of the location's fixed list. A lock on the chip means a manager must put in their PIN
   before it goes on. With this restaurant's defaults:

   | Reason | How much | Who |
   | --- | --- | --- |
   | Manager comp | the whole item or check comes to nothing | manager |
   | Staff meal | always 50% | manager |
   | Loyalty reward | up to 20% or $20 | any server |
   | Promotion | up to 50% or $50 | manager |
   | Service recovery | any percentage, an amount, or a comp | manager |

2. **How much.** A percentage (presets within the cap, or type one), an amount, or a comp, as the reason
   allows.
3. **On.** The whole check or one item. Two comps on two different dishes are fine; a second discount on
   the same dish, or over the whole check on top of one, is refused unless both reasons stack.
4. **Manager PIN.** For a reason that needs one, the manager types their PIN on the spot. The PIN is
   checked by the hub (five misses lock the terminal for a minute, as at sign-in); the check and the
   reports then name the manager. A server's PIN is refused.

Every discount and charge is its own row under the subtotal, with who approved it. **Tap a row to take it
off.** The automatic gratuity comes off only with a manager's PIN; a delivery fee or a charge staff added
comes off freely.

Discounts need a hub or the cloud: a screen taking orders offline (red cloud) cannot apply one, because
nobody can check the PIN. Each discount takes the audit photo like a fire or a void.

## On the check: hold a price

The quick path for one dish. **Hold the price of a line** and a menu opens there with the reasons the rules
allow on one item, each with what it gives and a lock where a manager must approve. With this restaurant's
defaults: Manager comp (free), Staff meal (50% off), Loyalty reward (up to 20% or $20, no PIN), Promotion
(up to 50% or $50), Service recovery (any amount).

- A reason that is complete in itself (a comp, a fixed staff meal) goes straight to the manager's PIN, when
  one is needed, and onto the item.
- A reason with a range asks how much first: a percentage (presets within the cap, or typed), an amount, or
  the whole item where the reason allows it.
- A dish that already carries a discount shows it at the top of the menu with **Take off**; reasons that
  cannot go on top of it are greyed out, as the hub would refuse them.

The line stays on the check: its price shows the original struck through over what is left, and the line
says what came off ("Comped · Manager comp", "50% off · Staff meal"). The row under the subtotal is there
as before, and a tap on it still takes the discount off.

The rest of the line's gestures are unchanged: a tap on the price opens the dish like a tap anywhere on
the line, holding the dish's name drags it, and the quantity and the bin keep their own tap and hold.
Nothing happens on a price while a dish is in hand. Like the Discount button, the menu needs a hub or the
cloud, because somebody has to check the PIN.

## Service charges

- **Automatic**: the hub puts them on by itself when their conditions hold. Defaults: 18% gratuity on
  dine-in parties of six or more (a gratuity: paid to staff, not taxed), and a $4 delivery fee on delivery
  orders (taxed as a service charge).
- **Added by staff**: offered at the bottom of the discount sheet when the rules define any (none by
  default).

## The order of operations

Line discounts, then check discounts spread over the lines in proportion (so each line's tax base is right;
the odd cent lands on the largest line), then charges on the discounted subtotal, then tax on whatever each
class taxes. A comp takes the whole line and its tax with it.

## The rules file

The hub reads `POS_PRICING`, a JSON file with `discounts` and `charges` (the shape `GET /pricing/rules`
returns); without one it uses the defaults above (`backend/src/pos/orders/adjustments.py`). The admin portal
will edit these in phase 2.

## Reports

`GET /reports/adjustments?since=<ms>` lists every discount and charge on the orders active since then, with
totals by reason, by who applied them and by who approved them, and how many discounts were taken off
again. The audit photo for each one is in `/events/photos` under the operation's id.
