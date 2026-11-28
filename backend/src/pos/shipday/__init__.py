"""Shipday: the delivery service the restaurant's drivers work with (docs/shipday.md).

The restaurant's delivery orders are dispatched in Shipday: its GloriaFood site hands them over there, a
dispatcher gives each to a driver, and the driver's own app says when it was picked up and delivered. This
package lets the hub read all of that with the restaurant's own Shipday key, so the POS's screens can show
it beside the POS's own orders:

- `client`: Shipday's API as the hub asks it (`Shipday`).
- `read`: what Shipday answers, turned into what the hub tells a screen (`order_of`, `driver_of`).
- `match`: which order on the POS a delivery in Shipday is (`matched`).
- `board`: the asking, every few seconds while somebody looks, and the picture it keeps (`ShipdayBoard`).

Nothing of the POS is sent to Shipday by this package: the key in a header, and the number of an order
Shipday itself handed over when the hub asks what became of it. Nothing Shipday says is stored: the picture
is kept in memory, and read again after a restart.
"""
