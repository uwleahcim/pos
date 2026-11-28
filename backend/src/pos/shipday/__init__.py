"""Shipday: the delivery service the restaurant's drivers work with (docs/shipday.md).

The restaurant's delivery orders are dispatched in Shipday: its GloriaFood site hands them over there, a
dispatcher gives each to a driver, and the driver's own app says when it was picked up and delivered. This
package lets the hub read all of that with the restaurant's own Shipday key, so the POS's screens can show
it beside the POS's own orders, and lets a person at a terminal give a delivery to a driver, take it back,
and mark it as it goes:

- `client`: Shipday's API as the hub asks it (`Shipday`).
- `read`: what Shipday answers, turned into what the hub tells a screen (`order_of`, `driver_of`).
- `match`: which order on the POS a delivery in Shipday is (`matched`).
- `board`: the asking, every few seconds while somebody looks, the picture it keeps, and the three changes a
  person can ask for (`ShipdayBoard`).
- `follow`: what Shipday says of a delivery, turned into what the POS writes on its check (`ops_following`):
  picked up there is Out here, delivered there is Delivered here unless money is due.

Nothing of the POS is sent to Shipday by this package: the key in a header, and ids and numbers Shipday
itself handed over. Nothing is changed there by the hub itself: only what a person tapped, a delivery's
driver and how far along it is, and nothing else. The picture Shipday gives is kept in memory, and read
again after a restart. What the hub writes onto a check because Shipday said so (`follow`, the location's
choice and its switch) is in the order's own log, like any tap.
"""
