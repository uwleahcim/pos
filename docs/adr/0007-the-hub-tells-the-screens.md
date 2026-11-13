# ADR 7: The hub tells the screens what changed; asking is the fallback

Date: 2026-11-13 · Status: accepted (Mike: "build more modern update method with push from server/hub")

## Decision
A terminal holds one request open to the backend it is using (`GET /live`, server-sent events). The backend
writes a line on it when an order changes (naming the orders), when the menu is saved or a dish 86'd (`menu`)
and when a location setting is written (`settings`), and a heartbeat every second when it has nothing to
say. The terminal then reads what changed with the same calls it always used. It no longer asks every two
seconds while the feed is up.

Asking stays, as the fallback and the safety net:

- While the feed is not up (a hub from before it, a connection that just dropped) every screen polls every
  two seconds, exactly as before.
- While it is up, each screen still asks by itself every thirty seconds (the menu: its revision every
  minute), so a change the feed never told is on the screen within half a minute.
- Three heartbeats missed and the terminal treats the backend as gone: it asks the backends for their
  health at once, which moves it to the standby hub or shows the outage, and opens the feed again on
  whichever backend answers.

## Why
Twenty terminals polling were some twenty requests a second to a hub that mostly answered "nothing new", and
a change still took up to two seconds to show on the next screen (an 86 up to five minutes: it does not move
the menu's revision, which was all the screens asked about). Told, a screen has the change in the time of
one read, and a quiet restaurant costs the hub a small query or two a second and a three-byte heartbeat per
terminal.

Server-sent events rather than a WebSocket: the news only goes one way, it is plain HTTP on the port and
through the client the app already uses, and it needs nothing new on either side. Not Apple's or Google's
push services: those are for waking a locked device (docs/push-relay.md), go through the internet and
promise no delivery time; this has to work on the restaurant's own network with the internet down.

The stream says that something changed and never what it is now. So there is still exactly one way to read
an order, an app that only polls keeps working beside one that listens, and a lost line costs a wait, not a
wrong screen.

The news about orders comes from the log, not from the request that wrote them: a watcher reads what
arrived after the last arrival it told. The API pokes it after each append so the line leaves within
milliseconds; it also looks once a second by itself, which is what tells changes this process did not
write. That covers a second API worker, a menu imported with `hubctl`, and the standby hub, whose database
receives the primary's log (PostgreSQL's own LISTEN/NOTIFY does not run on a standby, which is why this
does not use it).

## Consequences
- Hub first, then the apps: an app built with this against an older hub polls as before and says so in its
  status sheet; an older app against a new hub polls as before.
- Anything new the screens show that another terminal can change must be told on the feed (see
  `backend/README.md`), or it shows only at the safety poll.
- A dead hub is noticed in about three seconds plus one health check, where polling noticed in two to four.
- The backend's server ends the streams when it is told to stop; a hub restart looks to the terminals
  like any other outage and they find it again by themselves.
- Print jobs for a relaying terminal, and calls answered on desk phones, are not on the feed: the first is
  still polled (only on a terminal with the relay switched on), the second has its own held request.
