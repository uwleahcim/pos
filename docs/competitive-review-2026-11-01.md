# Competitive review: this POS against Toast, Square, Clover, Lightspeed and TouchBistro

1 November 2026. Second pass; the first (draft 7 of the architecture) covered features only and from memory.

**What was compared.** The architecture (draft 7), the code as built, and the app running on an iPad Pro 11-inch
simulator against the local backend with the real floor plan and the imported menu. Against: Toast (product
pages, Toast Central help, release notes, and the China Sky Toast admin for the module map), Square for
Restaurants, Clover, Lightspeed Restaurant (K-Series) and TouchBistro (help centers, legal terms, release notes,
reviews). Vendor claims that could not be confirmed are marked unverified. Prices and rates are what the vendors
or recent third-party reviews publish; none are quotes.

## 1. What to change

In priority order. Items 1 to 3 are gaps in the specification; 4 and 5 are design changes; the rest are small.

1. **Discounts, promotions and charges have no model yet.** Every competitor ships item and check discounts,
   promo codes, minimum spend, stacking rules, approval rules, and configurable service charges (percent or
   fixed, taxable or not, by order type and channel). The design has `Discount · Comp · Void` entities, auto
   gratuity and the card surcharge, and nothing else. Add a section: discount types (percent, amount, price
   override, buy-one-get-one, combo pricing), scope (line, seat, check), who may apply which with what approval,
   schedules and channels, promo codes, stacking order against surcharges and tax, consolidation on screen and
   receipt, and the reasons report. Basic discounts, comps and service charges belong in phase 1; promotions in 2.
2. **A counter (quick-order) mode.** Toast and Square run two modes: table service (floor plan first) and quick
   order (menu first, pay first, order number, name on the ticket). The app has the floor plan and a "To go"
   button that opens the same table-service order screen. A takeout counter needs: name and phone captured on
   the first tap, pay before fire (Toast's "send order after check is paid", overridable), fast cash tenders,
   an order number called at the shelf, and return to the sign-in screen after the order is sent. Phase 1.
3. **Kitchen: load balancing, start queue, all-day view.** Toast's current KDS routes the same prep item to the
   least busy of two identical stations, starts items so a table's dishes finish together (start queue), runs
   assembly lines and shows all-day counts per station; Square added staggered prep across stations in 2026.
   The design has stations, routing, course pacing and (draft 7) pacing per time slot, but routes a dish to one
   station, has no cook-time aware start, and all-day counts only at the sushi station. Add to the phase 2
   kitchen display: a station group (two woks) with least-busy routing, prep times per item used to stagger
   starts within a course, and an all-day view at every station.
4. **Order screen: give the dishes the room.** On the 11-inch iPad in landscape, two and a half rows of category
   tiles stay open above the dishes, so the dishes get under half the panel and a 12-dish category already needs
   scrolling. Toast and Square keep groups in a compact strip or rail and give the grid to items. Keep the
   current tray on phones; on tablets and Macs, collapse the categories to a single scrollable row (or a left
   rail) once one is open. Also: the customization icon appears on every tile because every dish has a rice
   group, so it says nothing; show it only when a tap will open the required-choices tray. Tile colors or photos
   per category (the design plans photo tiles; the code has none yet). The table map shows only labels on free
   tables; busy tables should carry time seated, spend and the server's initials, as Toast's do.
5. **Capture-only mode on the terminal.** The one case where Toast beats the design: a Toast terminal with no
   network at all still rings orders (in a per-device silo). Here the terminal shows "No connection to server".
   The outbox and the local replay already exist, and the menu is already read every five minutes; caching the
   last menu on disk and allowing `create` and `add_line` with estimated prices under a red banner, no tickets
   and no cards, is a small extension of what is built. It needs an ADR, because ADR 1 says terminals hold no
   rules; this holds no rules either, only queued operations and a cached menu, but the line should be drawn in
   writing.
6. **Small additions.** Tip approval thresholds (a tip above a set percent or amount needs a manager, as Toast
   has). A manager log (shift notes and incidents by day and location, in the owner app). Opening and closing
   checklists with a photo as proof, since every station has a camera (Lightspeed Tasks, without the camera).
   In-app text size and a high-contrast setting per user; Toast has no in-app font setting and it is a recurring
   complaint. Shared dishes split across seats on a by-seat split, stated explicitly. A "stay" variant of send
   (send to the kitchen and stay on the check) beside fire-and-exit.
7. **Still open from the first pass.** Upsell prompts (Toast Menu Upsells, Square kiosk upsells, Lightspeed AI
   upsells; all three now ship it) and a natural-language assistant over reports and settings (Toast IQ, Square
   AI, Lightspeed AI). Neither blocks phase 1.

## 2. Architecture: the hard cases side by side

| | This design | Toast | Square | Clover | Lightspeed K-Series | TouchBistro |
|---|---|---|---|---|---|---|
| Local authority | Two hubs per location, both live, plus the cloud; terminals use any that answers | None; cloud. Offline after about 40 s; one auto-picked wired device becomes a local sync hub | None; cloud | None; cloud, with a LAN "Local Connect" for KDS | One "active" iPad acts as local server, plus a KDS Hub device; the app must stay open | One "Main Device" (iPad or Mac mini) holds all data; every iPad must reach it |
| Authority fails | Standby takes over in about 5 s with a witness vote; a repaired hub rejoins | Devices fall to per-device offline | n/a | n/a | Other devices "won't function properly"; no failover documented | "The POS does not work"; manual move of the main role |
| Internet down, LAN up | Everything, including printing, KDS, 86, menu edits queued; cards per processor's store-and-forward limits | Orders per device, not shared between terminals; KDS only with the hub and multicast on one subnet; printers on LAN; cards swipe only; no 86, menu edits, guest lookup or reports; online ordering stops within 5 min | Payments offline on most devices; KDS has no offline mode; online orders held; open checks and printing offline unverified | Orders captured, payments queued; no routing to KDS or kitchen printers in device offline mode; pending orders lost if the device loses power | Orders, sync, printing, KDS, cash from the local cache; cards only on cellular terminals in standalone mode; integrations and online orders stop | Orders, cash, offline cards on some terminals, tickets, KDS; no menu or floor edits, no online orders |
| Merge after a split | Union of operations with hybrid clocks, proven by property tests and a hardware test | No algorithm documented; duplicates voided by hand; stored cards re-authorized on reconnect | Not documented | Not documented | Active device uploads its log; no rules documented | Not documented |
| Processing | Any provider, routed to the cheapest reachable reader | Toast Payments only, by contract | Square only | Clover (Fiserv) in practice | Lightspeed Payments where eligible, else a monthly fee | Several processors supported |
| Hardware | Any Mac, iPad, iPhone, Android; any Ethernet ESC/POS printer | Toast hardware only; Toast router required for new accounts | Square devices and iPads; listed printers | Clover devices only | Listed iPads and printers | Listed iPads, Mac mini, printers |
| Chinese on tickets | Any printer; image fallback when a printer lacks the glyphs | Special-order printers, one CJK pack per printer; TP200 packs do not work on Flex 3 | Kitchen names print; Chinese on today's KDS or printers unverified, one unresolved failure report | Alternate names may print on an "Asian characters" impact printer (unverified) | Undocumented | Thermal printers only, via the short name |
| Staff UI language | Per user, unlimited | Per device: English, Spanish, French, Simplified Chinese | No Chinese | No Chinese | No Chinese | No Chinese |
| API | Documented, under the same roles | Standard access read-only; writes for approved partners | Full public API | REST and app market; REST orders break Clover Dining | Partner-gated | Unpublished |

Conclusion: none of the five fails over its local authority automatically, and none merges orders taken on
separate devices while cut off. The two-hub design is ahead of the market on exactly the case that costs a
restaurant a Friday night. What it gives up is the per-device silo (item 5 above). Two details worth copying
from Toast: handhelds with cellular (Go 3) switch to the cloud when the Wi-Fi dies, which the ranked backend list
already allows for an iPhone and should be stated; and Toast publishes an offline runbook for staff (what to
do, what not to press while payments are processing), which this design should have before phase 1 go-live.

## 3. The order screen, as built, against theirs

Seen on the simulator: sign-in, floor map, order screen, category tray, required choices, item sheet, held and
fired states, check footer with live tax.

**Where it is better.** Tapping a dish with defaults adds it at once; Toast walks every required group and
Square's new check view opens item details on every tap, which users cannot turn off. Required choices open
inline below the dish instead of a modal. Item numbers (C01, C12) on tiles and in search match a numbered
Chinese menu and phone orders; no competitor leads with numbers. The check groups by course with a held or
fired state and a one-tap fire per course; the quantity chip with "table" or "seat n" is clearer than Toast's
seat buttons. The backend prices every change, so screens never disagree. The theme (brick red, warm paper
tones, system font, Material 3) is calmer than Toast's and Square's.

**Where it is behind.** Vertical space (item 4). Tiles are plain: Toast and Square color them per group, Square
and TouchBistro show photos; the design plans photo tiles. The check has no actions yet beyond quantity, edit,
fire and close: no pay, print, split, discount, transfer, dining option, open item or reprint; these are planned
and not built. Takeout orders carry only a free-text note; Toast's customer screen takes name, phone, address,
schedule and reorders. The floor map does not yet show time seated, spend or server. The handheld layout (check
and menu as two tabs) matches Toast Go's menu-first screen well enough; Toast Go keeps Hold, Stay and Send
pinned at the bottom, which the phone layout should copy once those exist.

**Sign-in.** A PIN pad with the camera beside it; Toast, Square and Clover use a passcode pad; none show the
camera. Fine as is; the tag and face methods are the differentiator.

## 4. Feature gaps by area

"Designed" means in the architecture doc; "built" means in the repository today.

| Area | They have | Here | Action |
|---|---|---|---|
| Discounts, promos, charges | Item and check discounts, promo codes, min spend, stacking, service charges (all five) | Entities only | Item 1 |
| Counter mode | Quick order, pay first, order numbers (Toast, Square, Clover) | Table service flow with a To go button | Item 2 |
| Kitchen display | Load balancing, start queue, assembly lines, all-day view, bump bars (Toast); staggered prep (Square); expo and prep-time reports (Clover) | Designed: stations, expo, pacing; not built | Item 3 |
| Modifiers | Required min and max, pre-modifiers NO/EXTRA/SIDE with price multipliers (Toast); nested to 3 levels (Square) | Designed and built: groups, rules, nesting, instructions | Pre-modifier shorthand (no, extra, on side, light) as a one-tap row in the item sheet |
| Takeout and online | First-party online ordering, order-ready texts, curbside, quote strategies, throttling, DoorDash Drive and Uber Direct (Toast); curbside and in-house delivery (Square) | Designed in draft 7; storefront phase 3 | None beyond draft 7 |
| Phone orders | Caller ID box, US only, pop-up only in quick order (Toast) | FreePBX connector, call pool, call card | Ahead |
| Reservations and waitlist | Native: Toast Tables, Lightspeed Reservations, TouchBistro Reserve | Built-in book and waitlist designed; Resy phase 4 | None |
| Payments | Surcharge or dual pricing (Toast, Square beta, Lightspeed), tip presets and approval thresholds, saved cards, Scan to Pay | Designed: routing, surcharge, QR pay | Tip approval threshold |
| Labor | Time clock, scheduling, tips manager, payroll, team app, geofenced clock-in | Designed: clock, pooling, ADP, scheduling adapter | Shift checklists; manager log |
| Reporting and owner app | Toast Now, Square Dashboard app, Lightspeed Pulse; AI questions over data | Owner app in draft 7 | Assistant later |
| CRM and loyalty | Profiles, segments, points, tiers, gift cards, email and SMS builders (all) | Designed, phase 3 | None |
| Inventory | xtraCHEF invoice scanning and recipe costing (Toast); ingredient-level with auto orders (Lightspeed) | Recipe engine built; inventory phase 4 | None |
| Catering | Quotes, BEOs, deposits, invoicing (Toast); none native (Lightspeed, TouchBistro) | Designed, phase 1 | None |
| Accessibility | Android font size only (Toast); nothing documented elsewhere | Nothing stated | Text size and contrast per user |
| Food waste | Waste tracking (Toast) | Waste operation designed | None |
| Menu management | Items database, bulk editor, price editor, item tags, scheduled price changes, "review and publish" staging (Toast) | Spreadsheet round-trip, validating saves, audit with undo, snapshots, in-app editor (built) | Item tags for filters and reports (allergen, spicy, chef's pick) if not already a property |

## 5. Where the design is ahead

Failover and merge (section 2). Open hardware and any ESC/POS printer. Several processors routed by cost, which
no competitor allows. Unlimited languages per user and Chinese tickets on any printer; Toast's Chinese support
is real but needs special-order printers, and the other four have no Chinese staff UI. The call pool and call
cards. A photo on every major action; nobody else records who was at the screen. The recipe, allergen and
cross-contact model inside the menu engine, where competitors bolt inventory on. An API the owner can read in
full. Two years of avoided lock-in: Toast's own terms make Toast Payments exclusive, restrict use to approved
hardware, let Toast change card rates on 30 days' notice, and charge the remaining software fees to leave.

## 6. Built against designed, 1 November 2026

Built and tested: the operation log with hybrid clocks and merge rules; the menu engine with combos, allergens,
recipes, stations, availability and 86, schedules and channels, the spreadsheet round-trip and the GloriaFood
import; the tax model with a Massachusetts profile; the floor plan with table status; PIN sign-in with event
photos; ESC/POS printing from the hub and through the terminal relay; the FreePBX manager-interface probe; the
in-app menu editor; the order screen with seats, courses, hold and fire, void-after-fire tickets, and local
estimates while offline. Not yet in the engine although specified: pinyin search, media, minimum quantity,
market and open price.

Not built: payments of any kind, discounts, split checks, transfers, tabs, cash drawer and close-out, tips, the
kitchen display mode, the customer display, time clock, reports, customers. Normal for the first weeks of phase 1.
Payments are the critical path: the Stripe and GoDaddy reader spike is still pending, and every other phase 1
exit criterion sits behind a working card sale.

## 7. Commercial notes

Toast: Point of Sale from $69 a month, 2.49% + 15c card-present on the standard plan (third-party figures; Toast
does not publish custom rates), exclusive processing, approved hardware only, initial terms of one to three
years that renew yearly, early termination equals the remaining software fees. Square for Restaurants: free,
$49 and $149 tiers (third-party figures), 2.6% + 15c, month to month, KDS billed per device, no offline KDS.
Clover: sold through Fiserv and resellers, 36-month bundles common, Trustpilot 1.9 of 5 on lock-in and fees.
Lightspeed: $69, $189, $399 tiers, Lightspeed Payments required where eligible, early termination equals the
remaining fees plus clawback of hardware discounts. TouchBistro: from $69 a month, several processors allowed,
cannot terminate mid-term, no SLA. All five publish no uptime commitment to a restaurant.

## 8. Sources

Toast: https://doc.toasttab.com/doc/platformguide/platformOfflineMode.html ·
https://doc.toasttab.com/doc/platformguide/platformOfflineModeLocalSync.html ·
https://intercom.help/toast-central/en/articles/14725534-use-toast-in-offline-mode ·
https://support.toasttab.com/en/article/Offline-Mode-Processing-Credit-Card-Payments ·
https://support.toasttab.com/en/article/Outages-and-Disruptions-Toast-Online-Ordering ·
https://intercom.help/toast-central/en/articles/9300261-manage-orders-with-toast-pos ·
https://intercom.help/toast-central/en/articles/9306449-configure-modifier-behavior ·
https://intercom.help/toast-central/en/articles/9623805-new-kds-experience-overview ·
https://support.toasttab.com/en/article/Managing-Your-Quote-Time-Strategy ·
https://intercom.help/toast-central/en/articles/14487584-surcharging-overview ·
https://intercom.help/toast-central/en/articles/17176329-toast-dual-pricing-overview ·
https://intercom.help/toast-central/en/articles/15600871-update-your-printer-settings ·
https://intercom.help/toast-central/en/articles/13425960-update-the-language-on-the-toast-printing-hub ·
https://intercom.help/toast-central/en/articles/14728369-update-the-language-setting-on-your-toast-device ·
https://doc.toasttab.com/doc/devguide/devApiAccessUserGuide.html ·
https://d22ee908voahmo.cloudfront.net/payment-processing-terms ·
https://d22ee908voahmo.cloudfront.net/merchant-agreement ·
https://www.nerdwallet.com/business/software/reviews/toast-pos · https://toast.launchnotes.io/ ·
the China Sky Toast admin (module map: Menus, Takeout & delivery, Kitchen, Front of house settings).

Square: https://squareup.com/us/en/point-of-sale/restaurants/pricing ·
https://squareup.com/help/us/en/article/7777-process-card-payments-with-offline-mode ·
https://community.squareup.com/t5/Feedback-Discussions/KDS-Offline-Mode/m-p/813051 ·
https://squareup.com/help/us/en/article/6426-modifiers-and-categories-with-square-for-restaurants ·
https://squareup.com/help/us/en/article/8596-set-up-and-manage-card-surcharges ·
https://squareup.com/help/us/en/article/7745-kitchen-facing-names-with-square-for-restaurants ·
https://squareup.com/us/en/release-notes · https://www.merchantmaverick.com/reviews/square-for-restaurants-pos-review

Clover: https://docs.clover.com/dev/docs/handling-offline-payments · https://docs.clover.com/dev/docs/clover-devices ·
https://docs.clover.com/dev/docs/orders-faqs.md · https://www.clover.com/en-US/help/use-kds-offline ·
https://tech.co/pos-system/clover-pos-pricing · https://www.trustpilot.com/review/clover.com

Lightspeed: https://www.lightspeedhq.com/restaurant/pricing · https://www.lightspeedhq.com/legal/lightspeed-service-agreement/ ·
https://k-series-support.lightspeedhq.com/hc/en-us/articles/53028167251867-Offline-POS-functionality ·
https://k-series-support.lightspeedhq.com/hc/en-us/articles/1260804658089 ·
https://k-series-support.lightspeedhq.com/hc/en-us/articles/22168531609499-Setting-up-the-Kitchen-Display-System-2-0 ·
https://k-series-support.lightspeedhq.com/hc/en-us/articles/12625085075995-Surcharging-with-Lightspeed-Payments ·
https://k-series-support.lightspeedhq.com/hc/en-us/articles/51623634913051-Understanding-modifiers-and-modifier-groups

TouchBistro: https://www.touchbistro.com/pricing/ · https://www.touchbistro.com/terms-of-service/ ·
https://help.touchbistro.com/s/article/using-multiple-ipads-with-touchbistro-pos ·
https://help.touchbistro.com/s/article/What-can-you-do-with-TouchBistro-POS-if-your-Internet-goes-down ·
https://help.touchbistro.com/s/article/printing-chinese-or-other-non-english-characters-on-your-kitchen-tickets ·
https://help.touchbistro.com/s/article/sending-drinks-and-courses-at-separate-times ·
https://help.touchbistro.com/s/article/Key-Difference-Between-the-POS-Based-Platform-and-the-Cloud-Based-POS ·
https://www.trustpilot.com/review/touchbistro.com
