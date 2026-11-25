# The guest list

Every customer who ordered with a phone number in the last 12 months, on one screen: how often they came,
what they spent, when they were last here and what they order most. Three lists are picked out of it: the
**regulars**, the guests who **stopped coming**, and the **new** ones. It is for a manager. It reads the
orders and changes none of them; the two things written here are a guest's **tags** and their **note**.

Since 16 November 2026 (the Toast comparison, row 30). Since 23 November 2026 the tags are put on here
and shown where that guest's call and order are taken, and the note is written here too; the tags also show
on the call while it rings, in the reservation book and on the waitlist, and a guest can be tagged from
their reservation or their line of the waitlist as well. Since 24 November 2026 a guest tagged that way
who has not ordered yet is in the list too, after the others, and a party seated from the book or the
waitlist is named on the check of its table, on the floor map and in the list of checks, where the search
finds the check by that name. And such a party is a guest of this list: it came in and ordered, so it has
the visit, and so has every other guest of its check ([Every guest of a check](#every-guest-of-a-check)).
A check of several guests that nobody was said to have paid waits here, and a manager says who paid it
afterwards ([Who paid, said afterwards](#who-paid-said-afterwards)).
Since 25 November 2026, where the owner set a rate, the list says each guest's **points** too: what the
guest who pays a check earns on it (`points.md`). Until a rate is set the list says nothing about points.
It grows out of the customers the to-go form already remembers by their number (`customers.md`): nothing
is typed in for the list itself.

## Opening it

Orders screen › **Location** (manager PIN) › **Guests**, under Dishes sold.

It reads the 365 days of service that end with the one running. The round arrow at the top reads them
again.

## The list

At the top: how many guests there are, how many of them are regulars, stopped coming or new, and what all
of them spent, over how many visits and how much a visit.

When checks wait for who paid, a coloured line under that says how many and what they come to
(**3 checks wait for who paid**). A tap on it opens them
([Who paid, said afterwards](#who-paid-said-afterwards)). With no check waiting there is no line.

Then every guest, one line each, numbered from the top:

- their **name** (the one on their latest order that has a name; a number nobody ever gave a name for is
  called by the number), **how many visits** and **what they spent**;
- under the name, their number, the day of their last visit, and **regular** in green, **stopped coming**
  in red, or **new**;
- under that, the **tags** they carry, each a small label ("VIP").

After them come the **tagged guests with no order**: somebody tagged from their reservation or the waitlist
before their first order. Their line says **no order yet** where the others say their last visit, and has
no visits and no money ([A tagged guest who has not ordered yet](#a-tagged-guest-who-has-not-ordered-yet)).

What stands above the list changes it:

| Control | What it does |
| --- | --- |
| **All / Regulars / Stopped coming / New** | every guest, or one of the three lists; each button says how many are on it |
| **Spent / Visits / Latest** | ranks by what they spent, by how often they came, or by who was here last |
| **A tag** ("VIP 2") | only the guests who carry it; the button says how many do. A second tap shows everybody again |
| **Find a name or a number** | any words of the name in any order, or any digits of the number ("0142") |

The tags are one line of buttons that slides sideways, the one most guests carry first. The line is there
once a guest carries a tag. A tag works together with the rest: "Regulars" and "VIP" is the regulars who
are VIPs.

## The three lists

- **Regulars** came 3 times or more in the last 90 days.
- **Stopped coming**: 3 visits or more in the year, and none for 60 days. These are the ones worth a call
  or a card. A guest on this list is not counted as a regular as well.
- **New** placed their first order ever in the last 30 days. A new guest who has already come three times
  is a regular too, and the line says both.

The line over the list says what the picked list means, and the small print at the foot of the screen says
all of it, in the hub's own numbers.

## Under a guest

A tap opens a guest:

- **Their tags** and **the note** the restaurant keeps about them ("Peanut allergy, side door"), each with
  who wrote it and when, and the button **Add a tag or a note** (**Change tags and note** once there is
  one). See below.
- **A guest since** the day of the first order they ever placed, and how many orders in all. These two look
  past the 12 months, and say what the to-go form says of a caller.
- What they spend a visit, and their visits in the last 90 days. A guest who was at a table that another
  guest paid says how many of their visits they paid themselves (**paid 3 of 5**).
- **Favourite dishes**: the ten they ordered most in the year, with how many.
- **Latest visits**: the last ten, each with its day, whether it was to go, delivery or a table (the
  table by its name, "Table A7"), what it came to and its dishes. A table that another guest paid says **another guest paid** in place of the
  money. **A tap on a visit opens that check's history** (`check-history.md`). Under a visit at a table
  of several guests is the button **Who paid** (**Say who paid** while its check waits):
  [Who paid, said afterwards](#who-paid-said-afterwards).

Any number of guests can be open at once.

## Every guest of a check

A check used to have one guest for this list: the phone number typed on it. But a party the host seats
**from its reservation or from the waitlist** left a number too, and it came in and ordered. And when two
tables are put together, two tables' guests sit at one check. So a check can have several guests, and the
list counts them this way:

- **Everybody who came in and ordered has the visit.**
- **The money of a check counts for one guest: the one who pays.**

Nothing is done for it and nothing is turned on. The host seats the party as always (**Seat**, then the
table), and the hub notes whose check it is.

**Who is a guest of a check**

- The **number typed on the check**, as always.
- Every **party seated on it** from the book or the waitlist **that left a phone number**: the party the
  check was opened for, and any that joined the table. It is listed under the name on the reservation or
  on the line of the waitlist.
- When two tables are put together: the guests of **both** tables are guests of the check that is kept.
  That goes for a number typed on the emptied check too. That check is closed with no dish left on it, so
  it is nobody's visit any more; its customer is a guest of the joined check.
- The same number twice at one check is one guest.
- A party that left **no number** cannot be in this list: a guest here is a phone number. A **walk-in**
  seated straight from the floor map has no party behind it; type their number on the check
  ([A walk-in's number](#a-walk-ins-number)).

**The visit**

- It counts once the check has a dish on it, on the day Sales counts the check. A check voided whole is no
  visit. **Put back** (the party goes back in the book or on the list) takes the visit away again.
- **Favourite dishes**: every guest of a check is counted the dishes of that check. The POS does not know
  who at the table ate what.
- "Orders in all" counts a table a guest was seated at as one more.

**Who pays**

- **One guest on the check** (one party seated, no number typed): that guest pays. Nothing to do.
- **Several guests** (two parties at a table, two tables put together): each has the visit, and the money
  counts for **nobody** until somebody says who pays. The check asks: its strip says
  **Who pays? Tap a name.**
- **Say it with a tap on the check.** In the strip under the app bar, the name of each party that left a
  number has a small arrow. Tap the name and then the one line of the menu, **Linda P. pays**. A red
  **Pays** label stands beside that name from then on, on every screen that has the check open.
  - **One guest pays a check.** Tap another name and the label moves.
  - **Taken back the same way**: tap the name that pays, and its ticked line. The check asks again.
  - Anybody signed in who has the check open can say it, as anybody can ring a dish in. The hub keeps who
    said it, and this list says it ("said by Amy").
  - It can be said at any time while the party sits on the check, before the dishes or after the bill.
    When nobody did, a manager says it from this list
    ([Who paid, said afterwards](#who-paid-said-afterwards)).
  - A party that left **no number** has no arrow: this list cannot count it. With one party that left a
    number and one that did not, the one with the number is the check's only guest and pays without a
    word.
  - **It takes no money.** It says who the money counts for in this list, and nothing else: the check,
    the bill, the kitchen and Sales never hear of it.
- **A number typed on the check** pays when nobody was tapped, whoever else sits there, as it always did.
  **A tap wins over it**: the tap says "pays" in so many words.
- **Put back** (the party goes back in the book or on the list) takes its word along. **Two tables put
  together**: the word of the check that is kept stands. A word said of the emptied check does not go
  over, so if the kept check had none, the joined check asks again.
- A visit that somebody else paid is in the guest's **Latest visits** with **another guest paid** where
  its money would stand; one whose check still waits for the word says **nobody said who paid**. Both
  count as a visit for **regular**, **stopped coming** and the day of their last visit, and not in what
  they spent. "A visit" (what they spend a visit) is reckoned over the visits they paid, and a guest who
  did not pay them all says so: **paid 3 of 5**.
- At the top of the list, **what all of them spent** counts every check once, never once for each guest.

**What is kept for it, and where**

- **On the hub**, beside the checks: for each seated party that left a number, which check it sits on,
  under which name and number, and since when. **Nothing is written onto the check itself**: no name and
  no number. So no bill, no kitchen ticket, no sale and no report other than this list changes.
- **For 400 days**: the year this list reads and a month to spare. The reservation book forgets a name
  and number 30 days after the day, and the waitlist the night after. This list reads a year, so what it
  counts a seated party's visit from is kept that long, and then let go.
- **Who pays** is kept there too, beside the party it was said of, with who said it.
- The names and numbers are read by this list alone, behind the manager's PIN. The check is told who
  pays and whether a party left a number, and never the number. The floor map and the list of checks are
  told what they were told. Nothing sends any of it out of the hub.
- **From the update on.** The tables seated today and yesterday when the hub is updated count; a party
  seated before that does not.

### Who paid, said afterwards

The tap on the check is for the party while it sits there. When nobody tapped, the check **waits**:
everybody at the table has the visit and the money counts for nobody. A manager says who paid here,
afterwards. Since 24 November 2026.

- **The line at the top of the list.** While checks wait, a coloured line under "They spent" says how
  many, and what they come to: the money that counts for no guest yet.
- **Tap it** for the screen **Who paid?**: every check of the year that waits, the newest first. Each has
  its day and its table, the time it was opened, its number and what it comes to before tax, and under
  that **its guests, each a button**.
- **Tap the guest who paid.** The name is ticked, and the line under the names says
  **Linda Chen paid, said by Mike.** The check's money counts for that guest from then on. It is the
  word a tap on the check says, kept the same way.
  - **A wrong tap is put right on the spot**: tap another name and the tick moves; tap the ticked name
    and the word is taken back. A check you said stays on the screen until you read again (the round
    arrow at the top), so that it can be.
  - Back on the list the figures are read again: that guest's money, and how many checks still wait.
- **From a guest's visit.** Under a guest, a visit at a table of several guests has the button
  **Who paid** (**Say who paid** while its check waits). It opens that one check with the same buttons:
  to say it, or to say otherwise when the wrong name was tapped at the table.
- **Who the buttons are**: every guest of the check
  ([Who is a guest of a check](#every-guest-of-a-check)). The parties seated on it from the book or the
  waitlist that left a number, each under its name; the **number typed on the check**; and the number
  typed on a check that **was merged into it**. A guest who gave no name is a button with their number.
- **The number typed on the check** pays for want of a word, and is ticked without one ("their number
  is on the check"). Tap another guest to say that they paid instead; take that back and the number on
  the check pays again.
- **For as long as the list reads the visit**: a year. The reservation book forgets a party 30 days
  after the day and the waitlist the night after, and the strip on the check is gone with them. This
  screen does not ask them: it reads what the hub noted of who sat on the check, which is kept 400 days.
- **Who may say it**: whoever may open this list, with the manager's PIN. The hub keeps the name behind
  the PIN with the word, and the check's line says it. A word said with a tap on the check says the name
  of whoever tapped.
- **It takes no money, and nothing is written on the check.** No bill, no kitchen ticket, no sale and no
  figure of Sales or The day changes. It says who a check's money counts for in this list, and nothing
  else.
- A check with **one guest** never waits, and neither does one with a number typed on it: they are not
  on the screen. A table whose parties left **no number** has no guest in this list, so there is nothing
  to say of it.
- A device that is not rebuilt shows the list as it was, with no line and no button. So does a rebuilt
  one with a hub that is not updated.

### A walk-in's number

A party that walks in and is seated straight from the floor map left no number with the host, so the
list could not count it. Since 25 November 2026 whoever serves the table types the number on the check.
That makes the check this guest's visit, and where a rate is set they earn points on it (`points.md`).

- **Guest**, on the check of a table: under **Allergy**, in front of the courses, so the seats keep
  their whole line. On a phone it is the small sign of a person with a plus, beside **Allergy**. A bar
  tab has it too. A to-go order has none: its number is typed on its form.
- **The box** asks for the phone number and, at a table, a name "if they give one". Seven digits or more
  make a number; with fewer the box says so and **Save** stays grey. Written any way: `781 555 0142`,
  `(781) 555-0142`.
- **As the number is typed the hub says who it is**, the way the to-go form does: how often they
  ordered and when last, their points ("They have 240 points", "No points yet"; nothing where no rate
  was ever set), and their tags. The name it knows them by fills the name box, unless one was typed.
  A number the hub knows nothing of is kept all the same, and so is one typed while no hub answers.
- **Save**, and the strip under the app bar says the guest: the name (**Guest** for none), their
  points, their tags and the customer's one-line note. The sign on the button is filled in. The number
  itself is not on the screen; it is in the box when the box is opened.
- **Change it or take it off**: tap the guest in the strip, or **Guest** again. **Take off** leaves the
  check with no number and no name, and the visit is nobody's again.
- **One number a check**: the guest who pays. A table of friends who each want points is not built.
- **Who pays**: the number typed pays, for want of another word. At a table where the host also seated
  a party that left a number, both have the visit; the typed number pays, and the strip does not ask.
  A tap on the seated party's name, **Linda P. pays**, says otherwise, as ever.
- **A bar tab** takes the number alone and keeps the name it is called by. The box and the strip say the
  name the hub knows the number by. A tab's name ("Blue jacket") is not taken for the guest's name in
  this list or on the to-go form, unless no other order of theirs has one.
- **While the check is open.** A closed check says its guest and has no button: reopen it to type the
  number or change it. The points follow at once either way, as they are read off the checks.
- **Anybody who has the check open** can type it, as anybody can ring a dish in. The check's history
  says who typed it and when, and who changed it or took it off.
- **It goes on the check itself**, the way a to-go order carries its number. So it is kept with no hub
  in reach and goes over with the rest, and it follows the check when the table is moved or two tables
  are put together.
- **What it does not do.**
  - It moves no money: no sale, no bill and no report changes. Only this list and the points count it.
  - It prints nowhere: the bill of a table says the table, and the kitchen ticket too.
  - **No text is ever sent to it.** Texts go to to-go orders. A table's check and a bar tab send none,
    whatever is on them.
  - When that number phones later the same day, the to-go form opens for a new order, never the
    table's check. Their name, note and tags are on the form as for any caller.
- On the to-go form, "12 orders since Mar 2025" counts the checks that carry the number, so a table
  with their number typed is one more, and it is among their latest orders with **Same again**.
- A device that is not rebuilt has no button, and shows a number typed elsewhere as it did before:
  the tags and the note, with no name and no points.

## Tags and the note

A **tag** is a word or two put on a guest to pick them out by: "VIP", "Friend of the house", "Catering
client", "Regular at the bar". The **note** is the one line the to-go form has always shown to whoever
takes their call. Both are kept by the guest's phone number.

Open a guest and tap **Add a tag or a note**. A box opens with their name on it:

- **Tags** are buttons. A tap puts one on, a second tap takes it off. The buttons are every tag some guest
  carries, and two that are always offered: **VIP** and **Friend of the house**.
- **Another tag**: type one that is no button yet and tap **+** (or Enter). It goes on this guest, and it
  is a button for every guest from then on. A tag typed and not added is still saved with **Save**.
- **Note**: the one line, 120 letters at most. Emptying it takes the note away.
- **Save** keeps both; **Cancel** keeps nothing.

Good to know about tags:

- **There is no list of tags to look after.** A tag exists while some guest carries it. Take it off the
  last guest and its list is gone, and its button too the next time the guest list is read (VIP and Friend
  of the house stay).
- **A tag is spelt one way.** Typing "vip" where "VIP" is in use puts "VIP" on. To spell a tag another way,
  take it off everybody who carries it and type it again.
- A guest carries **6 tags** at most, each **24 letters** at most. With six on, the other buttons wait
  until one is taken off.
- The hub writes down **who** put the tags on and **when**, and the same for the note, each by itself:
  changing the tags does not put your name on a note someone else wrote. The name is the one of whoever
  opened the guest list with their PIN.
- Another device that has the guest list open shows the change the next time it reads the list (the round
  arrow).
- **Find** looks at names and numbers, not at tags: use the tag's button.

Who may write them: whoever may see the guest list, so a manager and an owner, and anybody the owner hands
"See the guest list" to (`roles.md`). The same people tag a guest from a reservation or the waitlist, with
their PIN ([From a reservation or the waitlist](#from-a-reservation-or-the-waitlist)). The note can still
be written on the to-go form by whoever takes the call, as before.

### Where the tags show

- **Here**, under the guest's name and as a list of its own.
- **On the to-go form**, the moment that guest's call is answered or their number is typed: small labels
  under the line that says how often they ordered, over the note (`customers.md`, "On the to-go form").
- **On their order**, in the slim strip under the app bar, before the note, for whoever rings the dishes
  in (`customers.md`, "On the order").
- **On their call while it still rings**, under the number and the phone company's name, on every screen
  where somebody is signed in. So whoever picks up knows it is a VIP before saying hello. The sign-in pad
  and a locked screen show the number alone, as before.
- **On their reservation**, in the book: small labels on the row, after the time and the table and before
  the note, and under the number when the reservation is opened (`reservations.md`, "Reading the book").
- **On their line of the waitlist**, the same way: on the row before the note, and under the number when
  the party is opened (`waitlist.md`, "Reading the list").
- **On the check of their table**, once the host seated them from their reservation or the waitlist, in
  the same slim strip under the app bar, after their name and before the reservation's note:
  [At the table](#at-the-table).
- **On the floor map, as a star.** The table of a party seated that way says the party's name, with a
  small star before it when that guest carries a tag. The star says that there is a tag, not which; the
  list of your tables beside the map says them by name: [On the floor map](#on-the-floor-map).

The book and the waitlist know a guest by the **phone number** written on the reservation or the party: a
table booked or a party added without a number shows no tag, whoever they are. The tags are the number's,
not the reservation's: nothing is copied into the book, so a tag put on today shows on a table booked last
week, and a tag taken off is gone from it.

In all of these places they are only read, by anyone who takes the call, the order or the door. So **keep
a tag to what the staff may read**: "VIP" and "Catering client" are good tags, and an opinion of a guest
is not. A tag is never printed, on no kitchen ticket and no bill, and nothing sends it out of the hub.

A screen asks for a customer once, when the form looks the number up or the order is opened: a tag put on
while an order is open shows the next time that order is opened. A call asks once, when it starts to ring.
The book and the waitlist are told when a guest's tags change, and show it at once on every screen that
has them open. So are the floor map and the check of a table whose party was seated from one of them.

### At the table

What the host knows about a party helps most where the party sits. So when a party is **seated from its
reservation or from the waitlist**, the check of that table says whose table it is: the name, the tags
that guest carries, and the note written on the reservation or the party. It is in the slim strip under
the app bar, the same strip a to-go order has. Whoever opens the check to ring the dishes in reads
**Linda P.** `VIP` Window table, birthday before they walk over.

- Nothing is done for it. The host seats the party as always (**Seat**, then the table), and the check
  that opens knows whose it is.
- **The name** is the one on the reservation or on the line of the waitlist. **The note** is the one
  written there too, whole (a reservation's is at most 80 letters, a party's 60). It is not the one line
  the restaurant keeps about a customer (`customers.md`): that still shows only on an order with their
  number.
- **The tags** are the ones the party's phone number carries in this list. A party that left no number
  shows its name and its note, and no tag.
- **The phone number is not shown, and nothing is written onto the check**: not the name, not the number,
  not the note and no tag. They stay in the book or on the waitlist and are read from there. So the check
  is what it always was: the same on the bill, in the kitchen and in Sales. In this list the party is a
  guest of that check, by what the hub notes beside the check
  ([Every guest of a check](#every-guest-of-a-check)).
- **A party that joins a table** (the host taps a seated table and **Join**) has a line of its own under
  the first party, with its own name, tags and note. So it can be read who carries which tag.
- A check that has a number of its own (typed on it) shows that guest first, by name with their points,
  tags and note, then the parties seated on it.
- **The strip stays slim.** It is one line where that fits; on a phone the note goes under the name and
  the labels. It is never more than a quarter of the screen's height, so the check and the menu keep
  their room: two parties with many tags and long notes on a small phone are a scroll away inside the
  strip, and a bar at its side says that there is more.
- **A note is words, not an allergy mark.** "No shellfish" in a reservation's note shows on this strip
  and tells the kitchen nothing. The kitchen is told by the **Allergy** chip on the check, as always
  (`allergies.md`).
- It follows the check: move the table to another one and the strip is still on it, and a check that is
  split is still that check. Two tables made one check: the parties of both are on the check that is kept
  ([When two tables are put together](#when-two-tables-are-put-together)).
- **It is read each time, not copied.** A tag a manager puts on or takes off while the party eats shows
  on the open check at once, and a party that sits down on a check somebody already has open is named
  there at once. Without the hub's live updates it takes up to half a minute.
- Put the party back in the book or on the list (**Put back**) and it leaves the check.
- **With two or more parties that left a number**, the strip also says who pays, and takes the word: a
  tap on a name, then **Linda P. pays**. A check with one party has none of that and looks as it did
  ([Every guest of a check](#every-guest-of-a-check), "Who pays").
- A **walk-in** seated straight from the floor map has no reservation and no party behind it, so its
  check has no strip until their number is typed on it ([A walk-in's number](#a-walk-ins-number)).
- As everywhere, none of it prints, on no kitchen ticket and no bill, and nothing sends it out of the
  hub. Every server who opens the check reads it, so the advice above holds for a note too: write in a
  reservation what the staff may read.

### On the floor map

A manager who looks over the room wants to know where the VIPs sit without opening forty checks. So a
table whose party was **seated from its reservation or from the waitlist** says on the floor map whose
table it is: the party's name on a small line of its own, under the server's name tag and over the party's
size and what the table has run up. A small **star** stands before the name when a guest seated there
carries a tag in this list.

- Nothing is done for it. The host seats the party as always (**Seat**, then the table).
- **The name** is the one on the reservation or on the line of the waitlist. A table has little room, so
  a name of more than nine letters is cut short ("Papadopo…"). The check says it whole.
- **The star says that there is a tag, not which.** It is one star whatever the tags and however many.
  Open the check and its strip says them by name, with the note ([At the table](#at-the-table)).
- **Two parties at one table**: the table says the first to sit and "+1" ("Omar +1"). The star is there
  when either of them carries a tag.
- A party that left **no phone number** has its name on the table and no star.
- **A walk-in** seated straight from the map has no reservation and no party behind it: its table reads
  as it always did.
- **Beside the map, in the list of your tables** (the chip **Mine**, on a tablet on its side or a Mac;
  `table-servers.md`), each of your tables has a line with the names of all its parties, whole, each
  followed by its tags as labels: **Linda P.** `Catering client` `VIP`.
- **It is one of the table's small words.** The name is as small as the party's size and the total under
  it, and on a phone that is small: spread two fingers to make the map larger, or open the check. It is
  drawn smaller sooner than it makes the table's own name smaller. A table that says whose it is has five
  lines in place of four, so its other small words are drawn a little smaller than on a walk-in's table.
- It stands in the middle of the table, where a round table and one turned on its corner are widest.
- A table that is seated and **booked again** later still says the time of that booking under the rest
  (`reservations.md`, "On the floor map"). A table that is booked and still free says the booking's name
  as before, and no star.
- **It follows the check.** Move the check to another table and the name is on that table. Close the
  check and it is gone. **Put back** (the party goes back in the book or on the list) takes it off.
- **It is read each time, not copied.** A tag a manager puts on or takes off while the party eats shows
  on the map at once, on every screen. Without the hub's live updates it takes as long as the map takes
  to read again.
- **What the map is told**: for each open check, its parties by name, each with the tags its number
  carries. Never the phone number and never the note. Everybody who is signed in and sees the floor map
  reads the name and the star, as everybody who opens the check reads its strip. So the advice above
  holds here too: keep a tag to what the staff may read.
- **Nothing is written onto the check**, as at the table: no name, no number and no tag. So no bill, no
  kitchen ticket and no figure changes.
- **The list of checks** (the other half of the Orders screen) says the party's name after the table
  too, "Table A7 · Chen", and its search box finds the check by it. It says no star and no tag
  (`finding-checks.md`, "Whose table it is").

### When two tables are put together

Two tables are pushed together and their checks made one (**One check**; `moves.md`, "Merging two checks
into one"): the dishes go over to the check of the table the other landed on, and the emptied check is
closed. **The party goes over with its dishes.** From then on the check that is kept says whose it is:
the name, the tags and the note in its strip, the name and the star on its table on the floor map, and
the name on its row in the list of checks. Before, the party stayed behind on the emptied check, and the
joined table said nobody. Nothing to turn on, and no app to rebuild: the hub does it.

- Nothing is done for it. Put the tables together as always.
- **The parties of both tables** are on the check that is kept, the first to sit first, each on a line of
  its own in the strip: the Chens of A7 and the Wus of B5 are both named on B5's check.
- **The emptied check says nobody.** It is closed with nothing on it, and its row among the closed checks
  says the table alone.
- **Put together again**, with a third table: the parties go on to that check.
- **Put back** takes a party off the check that was kept, as off any check.
- **The hub writes one thing for it**: which check the party sits on, in the book or on the waitlist. It
  is what **Seat** wrote there, changed to the check that was kept. The table the party first sat down at
  stays as the book or the list has it ("seated at A7"), as it does when a check is moved to another
  table. **Nothing is written onto any check**: no name, no number, no note and no tag. So no bill, no
  kitchen ticket and no sale changes.
- **In this list** the guests of both tables are guests of the check that was kept: each has the visit,
  and its money counts for the one who pays. The joined check asks who that is, unless it was said of
  the kept check before ([Every guest of a check](#every-guest-of-a-check)).
- **Tables put together before the hub was updated** are not looked at again: a party whose check was
  merged earlier stays on the emptied check. Put it back and seat it again at the joined table if the
  check should say it. Every merge after the update is followed.
- **Dishes moved one by one** to another table's check (hold a dish, **Move**) take nobody along: the
  party stays on its own check, which is still open.
- Tables put together **while no hub answers** are followed when the hub hears of it.

### From a reservation or the waitlist

This list holds the numbers that **ordered**. Somebody who only ever books a table, or waits for one, is
not in it. They are tagged where they stand:

1. Open their reservation in the book, or their party on the waitlist, with a tap on the row.
2. Tap **Tags**, the last of the buttons. It is there when the reservation or the party has a phone
   number: the tags are kept by the number, so without one there is nothing to keep them by.
3. Type the **PIN** of somebody who may see the guest list: a manager's or an owner's, and that of anybody
   the owner handed "See the guest list" to. The host's own PIN is not taken unless hosts were handed it.
   The PIN is asked every time: the host stand is nobody's back office.
4. The box of tag buttons opens with the guest's name on it, the same box as here, with the tags they
   carry already on. Tap tags on or off, or type **Another tag**, and **Save**.

The bar at the bottom says what was kept ("Novak is tagged VIP"), and the tag is on the row at once, on
every screen. From then on it shows wherever that number turns up: on their next reservation, their next
wait, their call while it rings and their first order.

- The box has **the tags alone**. The note of a reservation is the reservation's own ("Window table"), and
  the one line the restaurant keeps about a customer is written here or on the to-go form.
- It works for a guest who is in this list too: it is the same tags either way.
- A guest tagged this way who has never ordered **is in this list from then on**, after the guests who
  ordered, under the name on the reservation or the party (below). Their tags are changed from here or
  from a reservation or a party of theirs, whichever is at hand.
- The reservation and the party are not touched: no time, table, place in the line or wait changes.

### A tagged guest who has not ordered yet

The list reads orders, and somebody who only ever booked a table has none. So that every VIP is in one
place, a number that **carries a tag** is listed even with no order in the 12 months:

- They stand **after the guests who ordered**, whichever way the list is ranked, by name.
- Their line has their name, their number and **no order yet**, and their tags. There are no visits and
  no money on it. A guest whose orders are all older than the 12 months says **no visit in the last 12
  months** instead.
- **The name** is the one on the reservation or the party they were tagged from: the hub keeps it with
  their tags, because there is no order to read a name from. Tagged again from a reservation under another
  name, they are called by the newer one. A party that gave no name is called by the number.
- They are counted in **All**, in the line "Guests" (which says how many of them have no order) and on the
  list of each tag they carry. They are on none of the three lists, and nothing of theirs is in "They
  spent" or the visits.
- **Open one** and it says their tags with who put them on, their note, and that there is no order yet.
  **Change tags and note** works as for anybody.
- **Take their last tag off and they leave the list**: there is nothing left to list them for. The bar at
  the bottom says so. The name kept with the tags goes with them; a note stays with the number, and shows
  on the to-go form if they ever call.
- **Once they order**, they are a guest like the others, with their tags on, under the name on their
  order.
- A guest who was tagged before the hub kept names (before 24 November 2026) is called by their number,
  until they are tagged again from a reservation or a party: open it, tap **Tags**, type the PIN and tap
  **Save**. Nothing about their tags changes by it.

## Good to know

- **A guest is a phone number that ordered.** Calls, to-go and delivery orders carry one; a table has one
  when someone typed it on the check, or when its party was seated from the book or the waitlist and left
  one ([Every guest of a check](#every-guest-of-a-check)). A table with neither is not in the list, so the
  list is not all of the sales: the line "They spent" is the sales of the checks that have a guest who
  pays. Numbers match by their digits, and one of fewer than seven digits is nobody's.
- **A visit** is an order with at least one dish on it. It counts on the day Sales counts it on: the day it
  was opened, or the day it is for when that is later, and only once that day has come (an order placed
  today for Saturday is not a visit yet). A check voided whole is no visit; a dish voided or taken off is
  not among the favourites.
- **What a guest spent** is what the checks they paid came to before tax, charges and tips, less comps
  and discounts: the net sales of Sales. A table that split its check is still one visit.
- **Favourite dishes** are counted by how many were sold, under the name the menu gives the dish today. An
  off-menu dish is counted under the name that was typed for it.
- "Orders in all" can be more than the visits even within the year: it counts every order the number
  placed, as the to-go form does, and so one that was opened and left empty as well.
- Two people who share a number are one guest, and one person with two numbers is two.
- Every sale stays in Sales and The day whether or not it has a number. This screen leaves nothing out of
  them and changes nothing.
- The list holds names, numbers and what people spent, so it is behind the manager's PIN like the other
  reports. The to-go form shows a caller to whoever takes the order, as before.
- A tag or a note changes no order, no sale and no figure: not on this screen and not on any report. It
  changes no reservation and no party on the waitlist either: they only show it.
- Seeing a party's name, tags and note on the check of its table changes nothing either: no dish, no
  price, no payment, no reservation and no party. A device that is not rebuilt shows what it showed
  before. A rebuilt device with a hub that only knows the tags at the table shows the tags alone, and
  with an older hub a table's check has no strip.
- The name and the star on the floor map change nothing either. A device that is not rebuilt, and a
  rebuilt one with a hub that is not updated, show the map as it was.
- Neither does the name in the list of checks: it is read from the book and the waitlist with the list,
  and is on no check.
- Counting a seated party as a guest changes this list and nothing else: no order, no check, no bill and
  no figure of Sales or The day. It needs the hub updated and no app rebuilt.
- With a hub older than the tags, the list is what it was: it reads, and there is no button to write.
  With a hub older than listing tagged guests with no order, the list holds the guests who ordered, as
  before. A device that is not rebuilt shows that list too, whatever the hub.
- The name kept with a guest's tags is on the hub only, behind the manager's PIN like the rest of the
  list. It is kept for as long as the number carries a tag, shown only here and only while the number has
  no order in the 12 months, and never printed or sent anywhere.
- The first reading after the hub starts takes it some seconds, as it reads a year of orders; after that
  it is quick until the hub is restarted. A year of 30,000 orders with a number adds up in a quarter of a
  second.

## Not built

- Sending the list out of the POS (a file, a print, an e-mail).
- Typing or correcting the name of a tagged guest with no order from this list: it is the name on the
  reservation or the party they were last tagged from.
- A number with a note and no tag, and no order in the 12 months, in this list: it is the tag that lists
  them.
- Tags from a reservation that ended (cancelled, no-show, seated) or a party that left: the button is on
  the ones still standing. A reservation or a party with no phone number cannot be tagged.
- Writing the customer's one-line note from a reservation or the waitlist.
- The tags on the strip of a call once it is answered (the to-go form that opens shows them), on the
  iPhone's own call screen, on a table held on the floor map, on the waitlist's row of booked tables, and
  in the list of to-go orders.
- On the floor map: the tags by name on the table itself (a star says there is one), a colour or a mark
  of its own for each tag, the note, the second party's name on the table (it says "+1"), showing the
  tagged tables alone, and the list of your tables beside the map on a phone (a phone keeps the whole
  width for the map).
- In the list of checks: the star and the tags (a row says the party's name alone), and the name on a
  check of another day than today's and yesterday's.
- At the table: how many the party was booked as and whether it came from the book or the waitlist (the
  check counts its own guests); the customer's one-line note of a seated guest; writing or changing
  the note from the check.
- For a walk-in's number: more than one typed number on a check; typing it on a closed check without
  reopening it; typing it from the floor map or the list of checks; a tab's guest under a name of
  their own.
- For the guests of a check: sharing a check's money out between its guests; who at the table ate what;
  spending a guest's points (earning and showing them is `points.md`); counting
  a party that was seated before the hub was updated, other than today's and yesterday's; a party's visit
  in what the to-go form says of a caller ("12 orders since Mar 2025" still counts the orders that carry
  the number).
- For who pays: saying that none of a check's guests paid (such a check stays among the ones that
  wait); saying it from a check's history, or on the check itself once the book or the waitlist has
  forgotten the party (it is said from this list then); a tap on the check for a guest whose number was
  typed on a check that was merged in (that guest is not named on the joined check: say it from this
  list); finding one check among the ones that wait by a name or a day (they are listed the newest
  first); when the word was said (the hub keeps who said it, and this list says that).
- When two tables are put together: going back over the tables put together before the hub was updated;
  changing the table the book says the party was seated at; taking a party along with dishes that are
  moved one by one.
- The restaurant's own name for a caller on the ringing strip: it still says the phone company's.
- Renaming a tag for everybody who carries it in one go, or a colour for a tag.
- Tagging many guests at once. Putting a first tag, from this list, on a number with no order in the
  last 12 months: such a guest is tagged from their reservation or their party.
- More notes than the one line.
- Messages or offers to guests, birthdays.
- A guest without a phone number, or joining two numbers into one guest.
- Changing what "regular", "stopped coming" and "new" mean from the app. They are five numbers in the hub
  (below).

## For developers

- Figures: `backend/src/pos/orders/guests.py`. `visit_of(state, taxes, rules)` turns one order into a
  `Visit` (phone, day, net, name, kind, dishes) or None; it reads the order's `Sale`
  (`pos/orders/sales.py`), so a visit's day and money are the sales report's. `guests_report(visits,
  entries, notes, defs=, now_ms=, tags=, names=)` is the list and `guest_report(phone, ...)` one guest. The numbers:
  `LOOK_BACK_DAYS = 365`, `REGULAR_VISITS = 3`, `REGULAR_DAYS = 90`, `LAPSED_DAYS = 60`, `NEW_DAYS = 30`,
  `FAVOURITES = 3` in the list and `MORE_FAVOURITES = 10` for one guest, `LATEST = 10`.
- Memory: `VisitMemo` remembers each order's `Visit` while its log stays as it was, as `SaleMemo` does for
  the sales (both are an `OrderMemo` now). It is a memo of its own so that a year of visits does not push
  the remembered sales out.
- Which orders: `store.with_phone()` (every index entry that carries a number; `orders.phone <> ''` in
  PostgreSQL) gives "since" and "orders in all" without replaying anything; `in_window` keeps the ones that
  can count in the year, and only those are replayed. Notes: `CustomerNotes.all()`.
- Tags: `backend/src/pos/guest_tags.py`. `GuestTags` (memory) and `PgGuestTags` (table `guest_tag`: `phone`,
  `tags` as JSON, `updated_by`, `updated_ms`), on `app.state.guest_tags` (`app.state.tags` is the sign-in
  tags of `face-signin.md`, another thing). `clean_tags(tags, known)` is the one place a tag is tidied: one
  line, each once whatever its capitals, spelt as `known` spells it, by the alphabet, `TAG_MAX = 24`,
  `TAGS_MOST = 6`. `offered(carried, listed)` is the tags on offer with how many of the listed numbers
  carry each; `STANDARD` is the two always offered. A standby reads and does not write (`ReadOnlyError`).
- A tagged number with no order: `guests_report` answers `tagged` beside `guests`: every number of
  `GuestTags.all()` with no visit in the window, as a row of a guest's shape with `visits` 0, `spent`
  "0.00", `per_visit`, `last` and `first` null, `since_ms` and `orders_ever` of its older orders (null and
  0 with none), the flags false and no favourites, by name and the nameless by number after them.
  `guests`, `totals` and each tag's `guests` are as they were (of the numbers with a visit), so an app
  that does not know `tagged` is not touched. The name is kept with the tags: column `name` of `guest_tag`
  (added by `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`), `clean_name` (one line, `NAME_MAX = 40`),
  `GuestTags.put(..., name=)` (no name said keeps the one it had; no tags, no name), `rename` (the name
  alone, for a number that carries a tag) and `names()`. `PUT /reports/guests/{phone}` takes `name?` (at
  most 200 letters, tidied; with unchanged tags it is `rename`, so who put the tags on stays) and answers
  as before. `GET /reports/guests/{phone}` answers a tagged number with no visit as 200 with its row and
  an empty `latest`; 404 `no_guest` is for a number with neither a visit nor a tag. App:
  `GuestsReport.tagged` and `everyone`, `Guest.ordered`; each `GuestTag.guests` is counted over both
  lists as the answer is read; `withKept` drops a tagged guest left with no tag; `PosApi.keepGuest(name:)`
  and `GuestEditDialog.tags(name:)`, which `tagGuestHere` hands the name of the reservation or the party.
- Wire (`backend/src/pos/api/guests.py`), all with the token of a session that holds `guests`:
  `GET /reports/guests` answers `{first, last, days, regular_visits, regular_days, lapsed_days, new_days,
  note_max, tag_max, tags_most, now_ms, guests, totals, tags}`, each guest `{phone, name, note, tags,
  visits, spent, per_visit, last, first, since_ms, orders_ever, lately, regular, lapsed, new, favourites}`,
  the one who spent most first, and `tags` a list of `{tag, guests}` (and `tagged`, below).
  `GET /reports/guests/{phone}` answers `{guest, note_by, note_ms, tags_by, tags_ms, latest}`, or 404
  `no_guest` for a number with no visit in the year and no tag. `PUT /reports/guests/{phone}` takes
  `{note?, tags?, name?}` (what is left out stays as it is) and
  answers `{phone, note, note_by, note_ms, tags, tags_by, tags_ms}`; it writes only what changed, under
  the session's name; 422 `bad_value` for a tag too long, too many tags or no phone number (nothing is
  written then), 503 `read_only` on a standby. Tags that changed tell the change feed `reservations` and
  `waitlist` (the screens that show them read again); a note alone tells nobody.
- App: `lib/guests_report.dart` (`GuestsReport`, `Guest`, `GuestDetail`, `GuestVisit`, `GuestList`,
  `guestsOf`, `GuestSort`, `sortedGuests`, `guestsNamed`; for the tags `GuestTag`, `GuestKept`,
  `guestsTagged`, `tidyTags`, `GuestsReport.keeps` and `withKept`), `lib/screens/guests_screen.dart`
  (`GuestsScreen`), `lib/screens/guest_edit_dialog.dart` (`GuestEditDialog`), `PosApi.guestsReport` (which
  waits 90 seconds), `PosApi.guestDetail` and `PosApi.keepGuest`. The lists, the order and the search are
  worked out in the app from the one answer; a guest is read closely when opened; what was saved is put
  into the list on the screen without reading the year again. `keeps` is false with a hub that sends no
  `tags`, and then nothing offers to write.
- Where the order is taken: `customer_card` (`backend/src/pos/customers.py`) reads the number's tags from
  the same store for `GET /customers/lookup`, the words alone; the app's `CustomerCard.tags`
  (`lib/customers.dart`) shows them with `GuestTagMark` (`lib/screens/guest_tag_mark.dart`) on the to-go
  form and in the order screen's strip. That call has no token, as it never had, and it writes nothing.
- At the host stand: `with_tags(rows, carried)` (`guest_tags.py`) answers each row with the `tags` its
  `phone` carries, compared by `phone_digits`, from one reading of `GuestTags.all()`. `tagged()` in
  `backend/src/pos/api/reservations.py` and in `backend/src/pos/api/waitlist.py` puts them on every
  reservation (`booked`, `earlier`, `booking`, and `booked` of `GET /reservations/caller`) and every party
  (`waiting`, `earlier`, `party`) as the answer is made; nothing is stored with either, and the floor's
  `holds` carry none. App: `Booking.tags` and `WaitParty.tags` (empty from an older hub), shown with
  `GuestTagMark` by `_BookingCard`, `_BookingSheet`, `_PartyCard` and `_PartySheet`.
- Tagging from the host stand: `GET /reports/guests/tags?phone=` (the same token; declared before
  `/reports/guests/{phone}`, which would take "tags" for a number) answers `{tags, tag_max, tags_most,
  phone, carried, tags_by, tags_ms}`: the tags on offer counted over every number that carries one, and
  what this number carries now. It reads no order, and the number need not have ordered; 422 `bad_value`
  for a `phone` that is no number. The save is `PUT /reports/guests/{phone}` with `tags` alone, as from the
  list. App: `TagBox` (`lib/guests_report.dart`), `PosApi.tagBox` (null from an older hub, which answers
  404); `lib/screens/tag_guest.dart` (`tagGuestHere`: `ManagerPinDialog` with the power `guests`, then
  `GuestEditDialog.tags`, the box without the note; `canTagGuest`, `tagsSavedWords`); `_Do.tags` in
  `reservations_screen.dart` and `waitlist_screen.dart`, which take the `device` the PIN is asked with and
  read again after a save.
- At the table: `GET /orders/{order_id}/seated` (`backend/src/pos/api/guests.py`, no token, like
  `GET /reservations` and `GET /waitlist`) answers `{order_id, parties, tags}`: every reservation and
  every waitlist party that was seated with this check's id, the first to sit first, each as
  `{from: "reservation" | "waitlist", name, size, note, tags}` with the tags its own number carries, and
  `tags`, all of them together, each once, by the alphabet (`tags_together` in `guest_tags.py`). The
  phone number is not in the answer. `GET /orders/{order_id}/tags` answers `{order_id, tags}` alone, as
  before, and names nobody. Seating already keeps the id (`POST /reservations/{id}/seat` and
  `POST /waitlist/{id}/seat` take `order_id`; a party that joins a table is seated with that table's
  check); `Reservations.seated_on(order_id)` and `Waitlist.seated_on(order_id)` find them among today's
  and yesterday's, so a check still open after the night is found. Both calls read no order, write
  nothing and answer nobody for an id they do not know. App: `TableGuests` and `SeatedParty`
  (`lib/seated.dart`); `PosApi.tableGuests` (from a hub with no `/seated`, which answers 404, it asks
  `tableTags` and answers the tags alone; null when nothing answers, so the screen keeps what it has);
  `_OrderScreenState._readTable` asks for a check with a table when it opens or is first read, when the
  change feed says `reservations` or `waitlist` (seating and a tag change both tell them), and every 30
  seconds; `_CustomerStrip` shows the check's own customer first (`_guestTags`, the note), then a line
  for each party (`seated-party:<n>`, `seated-name:<n>`, `seated-tag:<n>:<tag>`, `seated-note:<n>`), in
  a scroll view no taller than a quarter of the screen.
- On the floor map: `seated` of `GET /floor` (`seated_by_check` in `backend/src/pos/api/guests.py`,
  called by `floor` in `api/app.py`): under the id of each open check that a party was seated on, its
  parties, the first to sit first, each as `{name, tags}`; a check nobody was seated on is not in it, and
  neither a phone number nor a note is. It is made from `Reservations.seated()` and `Waitlist.seated()`
  (every party seated on a check among today's and yesterday's, which `seated_on` now filters) and one
  reading of `GuestTags.all()`, and only when there are open checks. Like `holds` it is part of the
  floor's answer, so the map asks no call of its own and the answer stays the same (304) until something
  changes. App: `FloorPlan.seated`, `guestsAt(tableId)` and `guestsOf(checks)` in `lib/floor.dart`
  (empty from an older hub); `_GuestMark`, `guestsInWords` and `taggedIcon` in
  `lib/screens/floor_view.dart` (keys `table-guest:<table>`, `table-guest-tagged:<table>`), the line
  `my-table-guests:<table>` of `_MyTableRow`; the map reads again on `LiveChange.waitlist` as well as
  `reservations`. The tests' hub answers it from the seated reservations and parties it holds
  (`floorSeated`; `seatedOnFloor = false` makes it an older hub).
- In the list of checks: `seated` on a check of `GET /orders?brief=true`, the names alone
  (`names_by_check`, beside `seated_by_check`); `finding-checks.md`, "On the wire", has the rest.
- Two tables put together: a merge is `set_field {merged_into}` and `close` on the emptied check
  (`moves.md`). When `POST /orders/{id}/ops` has taken operations, `follow_merges(state, accepted)`
  (`backend/src/pos/api/guests.py`, called in `append_ops` before the feed is poked) looks for a
  `set_field` that says `merged_into`, asks `kept_check(store, emptied)` where the log says that check
  went (its `merged_into`, and that check's in its turn, at most `MERGES_FOLLOWED = 20` times; None for
  no merge, a check the hub never heard of, or a ring), and calls `Reservations.follow(emptied, kept)` and
  `Waitlist.follow(emptied, kept)`: every party seated on the emptied check (among today's and
  yesterday's, as `seated_on` finds them) is put again with `order_id` the kept check. `seated_table` and
  `seated_label` stay. The feed is told `reservations` or `waitlist` when a party of that kind went over,
  and nothing otherwise. So every lookup above answers for the kept check with no change of its own, and
  still reads no order. The same merge taken twice moves nobody the second time; a merge of merges that
  arrives the later one first ends at the same check, since the end is read from the log each time. A
  book that cannot be written is logged (no guest is named) and left: the operations were taken. It is
  hub only: the screens read again on the feed as they did. Tests:
  `backend/tests/orders/test_guests_merged.py`.
- Every guest of a check: `backend/src/pos/check_guests.py` keeps who sat on which check, apart from the
  number typed on it. `CheckGuest` is `(source, source_id, order_id, phone, name, at_ms)`, one row for
  each `(source, source_id)`: `reservation` and `waitlist` by the booking's or the party's id, `check` by
  the id of a check that was merged in (its typed number). `CheckGuests` (memory) and `PgCheckGuests`
  (table `check_guest`) on `app.state.check_guests`: `put` (noted, or moved when it was noted before;
  rows older than `KEEP_DAYS = 400` are let go), `drop`, `follow(emptied, kept)`, `on(order_ids)`,
  `of_phone(phone)`, `since(at_ms)`. It is written in three places, all in
  `backend/src/pos/api/guests.py`: `note_guest(state, source, row)`, which the `done` of
  `api/reservations.py` and of `api/waitlist.py` call after every change (seated on a check with a number
  of seven digits or more: `put`; anything else: `drop`); `note_seated(state)`, once when the hub starts
  (every party `seated()` of today and yesterday); and `follow_merges`, which moves the rows of the
  emptied check and notes its typed number as a `check` guest of the kept one. A failure there is logged
  with no guest named and never stops the host's change or the merge.
- Reckoning (`backend/src/pos/orders/guests.py`): `check_of` is `visit_of` for a check with or without a
  number (`phone` empty without), remembered in `CheckMemo`; `shared_out(typed, checks, seated)` hands
  every guest of a check the visit, a number once, the typed number first and the others as they sat, and
  marks one of them `paid` (`payer_of`: the typed number; else the only guest; else nobody). `Visit.paid`
  and `Visit.seated` are new; a visit of an order nobody was seated on comes out the same object, so a
  list with no seated guest is the list it was. `spent` adds the paid visits, `per_visit` is over them
  (`paid` in each row and in `totals` says how many), `orders_ever` adds the seated visits to the orders
  that carry the number. `GET /reports/guests` reads `check_guests.since(...)` and the index rows of
  those checks in one call (`store.entries(order_ids)`, new on both stores); `GET /reports/guests/{phone}`
  reads `of_phone` and then everybody `on` those checks. Each `latest` visit says `paid`, and `net` is
  "0.00" when somebody else paid. Tests: `backend/tests/orders/test_check_guests.py`.
- Who pays: `CheckGuest.pays` and `pays_by` (columns added to `check_guest` with
  `ADD COLUMN IF NOT EXISTS`; a standby whose primary lacks them reads nobody as paying).
  `CheckGuests.pay(source, source_id, pays, by=)` puts the word on one row and takes it from the others
  of that check; `put` keeps it while the row stays on its check; `follow` takes it off the rows it
  moves. `payer_of(typed, guests, said)`: the guest somebody said, when that is a guest of the check;
  else as before. `Visit.waits` and `waits` on each `latest` visit: several guests and nobody pays yet.
  `GET /orders/{id}/seated` gains, on each party, `key` (`reservation:<id>` or `waitlist:<id>`),
  `listed` (it left a number of seven digits or more) and `pays`, and `payer: true` at the top (this hub
  takes the word); no number is in it. `POST /orders/{id}/payer` `{staff_id, party, pays}` (no token, as
  the host stand's calls): 404 `unknown_staff`, 404 `unknown_party` (not on this check), 409 `no_number`,
  503 `read_only` or `not_kept`; it notes the party afresh (`note_guest`), says `pay`, tells the feed
  (`reservations` or `waitlist`, which the open check re-reads on) and answers as the `seated` call. App:
  `SeatedParty.key`, `listed`, `pays`; `TableGuests.takesPayer`, `payers`, `asksPayer` (two or more
  could pay); `PosApi.sayPayer`; `_OrderScreenState._sayPayer`; `_CustomerStrip.onPays`, `asksWho` and
  `_payer` (a `PopupMenuButton` of one ticked line) in `lib/screens/order_screen.dart`;
  `GuestVisit.paid`, `waits`, `unpaidWords`; `Guest.paid`, `paidWords`. Tests:
  `backend/tests/orders/test_who_pays.py`, `apps/pos_app/test/who_pays_test.dart`.
- Who paid, said afterwards: three calls in `backend/src/pos/api/guests.py`, with the token of a session
  that holds `guests`, declared before `/reports/guests/{phone}` (which would take "payers" for a
  number). `GET /reports/guests/payers` answers `{first, last, now_ms, checks}`: every check of the
  window that waits, the newest first. `GET /reports/guests/payers/{order_id}` answers one check whether
  it waits or not, or 404 `no_check` (no visit of the year, or no guest noted on it). A check is
  `{order_id, order_no, table, day, opened_ms, kind, net, guests, waits, said_by}` and a guest
  `{key, name, phone, typed, pays}`: `key` is `typed` for the number on the check and else
  `<source>:<source_id>` of its `check_guest` row; a number is listed once, the typed one first.
  `POST /reports/guests/payers/{order_id}` takes `{guest, pays}` and answers the check as it stands:
  for a noted guest it is `CheckGuests.pay(..., by=<the session's name>)`, the word the tap says; for
  `typed` it takes the word from whoever had it; `pays: false` takes it from every paying note of that
  number on the check. 404 `unknown_guest`, 422 `bad_value` (`typed` with `pays: false`: it has no word
  to take back), 503 `read_only` or `not_kept`. It tells the feed `reservations` or `waitlist` when the
  check has notes from them (an open check reads its strip again), logs the check and the staff id and
  no guest, and reads and writes no order. Reckoning: `paid_by(check, seated)` and
  `checks_paid_by(checks, seated, now_ms)` in `backend/src/pos/orders/guests.py`, on `payer_of`;
  `guests_report` answers `waiting: {checks, net}` (each waiting check once), and each `latest` visit
  says `guests` (how many sat on its check) and `table`. App: `lib/paid_checks.dart` (`PaidCheck`,
  `PaidGuest`), `PosApi.waitingChecks`, `paidCheck` and `sayPaid`, `lib/screens/who_paid.dart`
  (`WhoPaidCard`, `WhoPaidScreen`, `showWhoPaid`), `GuestsReport.saysPaid`, `waiting` and `waitingNet`
  (no `waiting` from an older hub: no line and no button), `GuestVisit.guests`, `table` and `shared`;
  keys `guests-waiting`, `who-paid:<check>`, `who-paid-guest:<check>:<key>`,
  `who-paid-standing:<check>`, `guest-visit-paid:<phone>:<check>`. Tests:
  `backend/tests/orders/test_who_paid_after.py`, `apps/pos_app/test/who_paid_test.dart`.
- A walk-in's number: nothing new on the hub's API. The app writes the order's own `phone` (and, at a
  table, `customer_name`) with a `set_field` op, as a to-go order carries them (`by` and `by_id` say
  who), and takes them off with `null`; `visit_of`, `payer_of`, the orders index, points and
  `/customers/lookup` already read them. Two guards came with it, both on `order_type` `dine_in`:
  `last_order` (`backend/src/pos/orders/callers.py`) skips a table's check and a tab, so
  `GET /orders/last` never opens one for a caller, and `Notifier._change` (`backend/src/pos/messaging.py`)
  sends no text for one. A tab's `customer_name` is what the bar calls it: `_called` (the guest list's
  row) and `customer_card` (`backend/src/pos/customers.py`) take it for the guest's name only where no
  other visit has one. App: `lib/screens/guest_number_dialog.dart` (`GuestNumberDialog`, `GuestNumber`,
  `guestNumberOff`), `OrderScreen._guestNumber`, `_hasGuestNumber`, `_GuestChip` and the strip's
  `guest`, `guestPoints` and `onGuest`; keys `guest-chip`, `guest-number-why`, `guest-number-phone`,
  `guest-number-name`, `guest-number-known`, `guest-number-summary`, `guest-number-points`,
  `guest-number-tag:<tag>`, `guest-number-off`, `guest-number-save`, `check-guest`, `check-guest-name`,
  `check-guest-points`. Tests: `backend/tests/orders/test_walk_in_number.py`,
  `apps/pos_app/test/walk_in_number_test.dart`.
- A call that rings: `GET /customers/tags?phone=` answers `{phone, tags}` and nothing else of the customer
  (no name, no note, no orders), with no token, like the lookup. App: `PosApi.customerTags` (empty for a
  short number, no answer or an older hub); `PhoneBar.tagsOf`, which `lib/main.dart` hands over only while
  somebody is signed in; `_PhoneBarState._askTags` asks once for a ringing number and drops an answer that
  comes after the call moved on; `_RingingBanner.tags`.
- Tests: `backend/tests/orders/test_guests.py`, `backend/tests/orders/test_guest_tags.py`,
  `apps/pos_app/test/guests_report_test.dart`, `apps/pos_app/test/guest_tags_test.dart`,
  `apps/pos_app/test/customers_test.dart` (the form and the strip),
  `apps/pos_app/test/guest_tags_host_test.dart` (the call, the book and the waitlist),
  `apps/pos_app/test/tag_guest_test.dart` (tagging from a reservation or the waitlist),
  `apps/pos_app/test/guests_tagged_test.dart` (tagged guests with no order, in the list),
  `apps/pos_app/test/table_tags_test.dart` (the name, the tags and the note on the check of a table),
  `apps/pos_app/test/floor_guests_test.dart` (the name and the star on the floor map),
  `apps/pos_app/test/check_by_guest_test.dart` (the name in the list of checks and the search by it).
