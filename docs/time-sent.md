# When a dish was sent

A guest asks where the food is. The check answers: it says when the kitchen got each course, and how long
ago that was.

## What the check shows

- **Each course's header says when it went**, beside the course's name: "Appetizers  sent 18:42, 23 min
  ago". The state stays in its corner (fired, 1 to fire, held). With coursing off the one header, "Items",
  says it.
- **The time is when the first dishes of the course went**, which is the longest anybody at the table has
  waited for it.
- **A dish that went later says its own time** under its name: "sent 18:55, 10 min ago". That is a dish
  added after its course was sent, or one sent a minute or more after the others. A dish that went with
  its course says nothing more than it did.
- **How long ago** counts whole minutes on the clock: sent at 18:42 and read at 19:05 is 23 minutes. Within
  the first minute it says "just now"; past two hours it counts hours ("2 h 5 min ago"). It moves on by
  itself while the check is open.
- **A closed check says the time alone** ("sent 18:42"): how long ago means nothing there.
- **A dish that came over from another table** (see `moves.md`) keeps the time it was sent at its old
  table. The guests have waited since then.
- A voided dish says nothing about when it went.

The time is on the clock the rest of the app uses (24 hours, like the to-go times). It is the time of the
screen that sent the dishes, and "how long ago" is counted on the clock of the screen that shows it, the
one in the corner of the device. Screens whose clocks are a minute apart can differ by that minute.

Where the check is too narrow for the name and the time on one line (a small phone, a long course name,
large type), the time goes under the name, whole and in the same type.

## What it does not do

- Nothing prints and nothing is asked. No setting turns it on or off.
- By itself it does not say when a dish was cooked or carried out. Where a kitchen screen marks the dishes
  (`kitchen-screens.md`, "What the servers see"), the dish says "ready 18:50" or "went out 18:52" under its
  name, and "how long ago" stops counting for it.
- The bill does not show it.
- The floor map's ring already shows how long a table has waited since it was last sent to the kitchen
  (`location-settings.md`, table timers); the check now says it course by course.

## Installing

Hub and app: `sudo hubctl update` first, then rebuild the apps on every device. No menu import. An app that
is rebuilt before its hub shows the check as it was: the time comes from the hub.

## For developers

- Hub: every line in an order's snapshot (`GET /orders/{id}`, `GET /orders`) has `sent_ms`, the wall time
  of the fire that sent it (`Line.fired_at`), or null while it is not sent. A dish carried from another
  check already sent keeps that check's stamp. The time is the sending terminal's own clock, as every
  operation's stamp is.
- App: `Line.sentMs` (`lib/api.dart`); a `fire` still in the outbox stamps the lines it sends with its own
  time (`withLocalOps`). `lib/check_order.dart` has `sentOf` (a header's time: the first sent among the
  dishes still on the check), `sentApart` (a minute or more after the header) and `sentWords`. A header is
  a `CourseRow` with `sentMs`; a `LineRow` has `sentMs` only when it says its own time.
- The order screen's check keeps the minute it is in a `ValueNotifier`, looked at every five seconds; only
  the words that say "ago" listen, so the check is not rebuilt as time passes. `OrderScreen.now` names
  the clock in a test.
- Tests: `backend/tests/test_line_order.py`, `backend/tests/orders/test_moves.py`,
  `apps/pos_app/test/time_sent_test.dart`.
