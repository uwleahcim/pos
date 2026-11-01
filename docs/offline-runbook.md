# Offline runbook

One card per failure, for every station. The app shows the card for the state it is in when you tap the
status icon (the cloud at the top right); this page is the same text, to print before go-live and keep by
each screen. The architecture page (section 4, "Staying up") lists every failure; these are the ones staff
see.

The status icon tells you which card applies:

| Icon | Meaning | Card |
|------|---------|------|
| Green cloud | Connected to the usual backend (the hub) | Everything works |
| Amber cloud with arrows | Working through a backup (the standby hub or the cloud) | Both hubs are down |
| Red cloud, red banner across the top | Nothing answers; the screen is taking orders only | Hubs and internet down |
| Red cloud, no banner | Nothing answers and this screen has no saved menu | Not connected |

A number on the icon is how many taps are still waiting to be sent. They go the moment a backend answers;
do not retype them.

## Everything works

- This screen is on its usual backend.
- If the icon turns amber or red, tap it: the card then says what still works.

## Both hubs are down: working through a backup

- Orders, checks and the menu work as usual through the backup.
- Kitchen tickets print through a screen set as print relay (Settings); printing may lag a little.
- Tell the manager so the hubs get looked at.

## Hubs and internet down: taking orders only (ADR 6)

- Take the order as usual: it is kept on this screen and sent the moment a backend answers.
- Prices and tax are estimates from the saved menu; the real check comes when the backend is back.
- Nothing prints: tell the kitchen by hand. Their tickets print, headed LATE, when the backend returns.
- Cash only: write the amount on the check. No cards, no receipts.
- Nothing is shared between screens: keep each table on the screen that took it. The floor map and the
  list show the checks this screen opened, marked "waiting to send".
- If it stays red for more than ten minutes, call the manager on duty.

What the guest hears: "Our system is down for a moment; I will take your order and we can settle in cash
or when it is back up."

## Not connected, and no menu saved on this screen

- This screen has never read the menu, so it cannot take orders until a backend answers.
- Use another screen, or check the addresses in Settings.

## When it comes back

- The queue drains by itself; the backend prices every line and prints every ticket that was due, each
  headed LATE with the time the order was taken. Check with the kitchen before firing anything again.
- Checks taken offline show their real totals once the backend has priced them; the "estimated" mark goes.
- Everything taken offline is flagged in the order log, so it can be listed afterwards.

## Who to call

The manager on duty first; the manager calls support for the hubs or the internet line.
