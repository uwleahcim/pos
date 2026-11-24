# The time clock

Staff clock in and out and take breaks at any screen, with their own PIN. The hub keeps every punch with
its own clock, closes a shift nobody ended when the night ends, and gives a manager the hours: who is on
now, what each person worked today or this pay week, and every shift with its log. A manager can correct a
shift, take one off or write one in, each with a reason the log keeps.

Since 16 November 2026 (the Toast comparison, row 8). **Off until a manager turns it on.**

## Turning it on

Orders screen › **Location** (manager PIN) › **Time clock**:

- **Time clock**: on or off. Off, nobody is asked to clock in and no screen shows the clock.
- **Breaks count as time worked**: off to start, so a break is taken out of the hours. On, a break stays in
  them. It is one rule for every break; see "Good to know" for meal breaks and short breaks.
- **The pay week starts on**: Monday to start, or Sunday. It is what "This week" and "Last week" mean in
  the hours.
- **Hours**: the manager's screen, below.

Each saves as it is changed, and every screen follows within seconds.

## Clocking in and out

**At the sign-in screen** (nobody has to sign in):

1. Tap **Time clock** in the bar (a clock icon on a phone). The pad says the PIN is for the time clock.
2. Tap your PIN. Your card takes the pad's place: your name, and where you stand.
3. Tap what fits:
   - off the clock: **Clock in**
   - on the clock: **Clock out**, or **Start break**
   - on a break: **End break**, or **Clock out** (which ends the break too)
4. The card says what was recorded and at what time, and for a clock-out what the shift came to. **Done**
   goes back to the sign-in pad. After clocking in, **Go to orders** signs you in with the same PIN.

**On a locked screen** it is the same: the Time clock button is on the locked pad, and the screen stays
locked for whoever was on it.

**Signed in already**: the orders screen's menu has **Time clock**. It asks for your PIN again, so nobody
can punch for the person who left a screen signed in. It works for anybody, not only the person signed in.

The card closes itself after 30 seconds untouched. **Back to sign in** leaves the clock without a PIN.

## The time is the hub's

- A punch is stamped by the hub when it arrives. No screen sends a time, so a device with a wrong clock
  cannot move a punch.
- A punch that got no answer (a bad moment on the network) can be tapped again: it is the same punch and
  counts once.
- A punch that does not fit is refused and the card says why ("Amy is already on the clock"), then shows
  where the person stands now. One person has one shift running at a time.
- Clocking needs the hub. With no hub answering, the card says so and nothing is recorded: write the time
  down and have a manager write the shift in.

## A shift nobody clocked out of

At 4 AM, when the night ends, the hub closes every shift still running, at 4 AM, with a break left running
ended there too. Such a shift is **marked "not clocked out"** until a manager corrects it:

- its hours run to 4 AM, which is more than was worked, so the hours screen says so in red and counts how
  many there are;
- the person is told the next time they are at the clock ("Nobody clocked you out on Fri, Nov 13. Tell a
  manager when you left");
- a manager opens it and puts the real clock-out on it, with a reason.

Somebody who clocks in within three hours of 4 AM (a baker, a cleaner) is on the next night: their shift
is closed at the 4 AM after.

## The hours (managers)

Location › Time clock › **Hours**:

- **Today**, **This week**, **Last week**, or **Other days** for any two dates. A day of the clock runs
  from 4 AM to 4 AM, so a bartender who closes at 1 AM is still on yesterday; a shift belongs to the day
  it began.
- **On the clock now**: everyone clocked in at this moment, since when, and who is on a break.
- **Hours**: each person with what they worked, as `38 h 15 min` and as `38.25 hours` for payroll, how many
  shifts, their breaks, and how many shifts were not clocked out. The total is at the top.
- **Each shift**, the latest first: the times, the breaks and what it came to. A tap opens it with its
  whole log: every punch with its time and screen, and every change by a manager with the reason and the
  times before and after.

Times are to the minute as punched, with no rounding.

### Correcting a shift

Open the shift › **Correct**. Change the day, the clock-in, the clock-out or a break, say **why**, and
**Save**:

- The clock-out and the breaks are times of day after the clock-in, so a shift that runs past midnight
  needs no second date (the clock-out then says "the next day").
- The **×** beside the clock-out puts the person back on the clock (somebody clocked out by mistake).
- A time that is not touched keeps the second it was punched at.
- A reason is required. The log keeps it with who changed the shift, when, and the times as they were:
  nothing is overwritten without a trace.
- The hub refuses what cannot be: a clock-out before the clock-in, a time in the future, a shift over 24
  hours, a break outside the shift, two shifts of one person over the same time. It says which.

### Taking a shift off, writing one in

- **Take off** (a punch made by mistake) asks why. The shift stays in the list, marked "taken off", with
  its log, and counts for no hours. It cannot be changed again.
- **Add a shift** writes one in for somebody who never clocked in: who, the day, the clock-in, the
  clock-out (or none: they are then on the clock and clock out themselves), any breaks, and why. It is
  marked "written in".

## Good to know

- **The staff are the same people who sign in**: a manager adds a person under Location › Staff and PINs
  (`staff.md`).
- **One job per person**: a shift is worked as the person's role. Choosing between two jobs (and two pay
  rates) at clock-in is not built.
- **One rule for every break.** The clock cannot tell a 30-minute meal break from a 10-minute rest. Where
  short rests are paid and meal breaks are not, have staff punch the meal break only, or ask for a rule
  ("breaks under 20 minutes count"). Check with whoever does the payroll which breaks have to be paid.
- **The PIN only.** A tag or a face signs in as always; the time clock asks for the PIN.
- Nobody has to be clocked in to use the POS, and a manager or owner need not clock in at all.
- **The turn for a table follows the clock.** A server who clocks in is in tonight's turn for a table at
  the host stand, and whoever clocks out is out of it ([table-servers.md](table-servers.md#whose-turn-it-is)).
  A host can still take somebody out or put them in by hand. The turn changes nothing in the hours.
- Not built: wages, overtime, tips, a schedule, a file for the payroll company, a photo with each punch, a
  reminder at sign-in for somebody not clocked in.
- Turning the clock off keeps the hours: the Hours screen still reads and corrects them.
- Not tried on the real devices from here.

## For developers

- Hub rules: `backend/src/pos/timeclock.py`. `TimeClock.punch`, `state`, `sweep` (closes shifts past
  `night_cutoff_ms`, called before every read, so nothing has to be awake at 4 AM), `add`, `edit`,
  `remove`, `report`. A `Shift` has `in_ms`, `out_ms`, `breaks`, `closed_by` (`self`, `manager`, `system`),
  `edited`, `removed`; an `Entry` of the log has the action (`in`, `out`, `break_start`, `break_end`,
  `auto_out`, `add`, `edit`, `remove`), who, the device, the reason and the times before and after.
- Storage: `ClockStore` in memory, `PgClockStore` on PostgreSQL (`clock_shift`, with one open shift per
  person by a partial unique index, and `clock_log`, append-only, `entry_id` unique so a punch sent twice
  is written once).
- Wire (`backend/src/pos/api/timeclock.py`): `POST /timeclock/punch` `{device, pin | tag_uid, action,
  punch_id}` with `action` `state | in | out | break_start | break_end` (409 `off`, `already_in`, `not_in`,
  `on_break`, `not_on_break`; the answer has `staff` in the shape of `POST /signin`);
  `GET /timeclock/report?since=&until=`, `POST /timeclock/shifts`, `PUT` and `DELETE
  /timeclock/shifts/{id}` with a manager's token; `GET` / `PUT /settings/time_clock`
  `{enabled, breaks_paid, week_starts}`.
- App: `lib/timeclock.dart` (models, `clockDay`, `clockWeek`, `hoursMinutes`, `decimalHours`),
  `lib/screens/time_clock_card.dart` (`TimeClockCard` drawn in place on the sign-in pad, since a locked
  pad has no navigator; `TimeClockDialog` inside the POS), `lib/screens/time_clock_screen.dart`
  (`TimeClockScreen`, `ShiftEditDialog`), the card in `lib/screens/location_settings_screen.dart`, the
  pad's mode in `lib/screens/signin_screen.dart`.
- Tests: `backend/tests/test_timeclock.py`, `apps/pos_app/test/time_clock_test.dart`.
