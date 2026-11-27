# Notes for the shift, and the manager's log

Two places for words, beside the orders:

- **Notes for the shift**: what a manager wants everybody to know before they start. The specials, what is
  out, the party of twelve at seven. Each person sees a note once, after signing in.
- **The manager's log**: the managers' own book. What happened in a shift that the next manager should
  know, each entry under a subject.

Since 16 November 2026 (the Toast comparison, row 20). Hub and app; nothing to turn on. Neither touches a
check or a sale.

## Notes for the shift

### What the staff see

A note that somebody has not seen yet comes up by itself, in a box over the floor map or the list of
checks, the next time they are there after signing in: by PIN, by tag, by face, or on a screen that was
locked. It says the note, who wrote it and when. There is one button, **Got it**. A tap beside the box does
not close it.

- **Once.** After "Got it" the hub knows that person has seen it, on every screen. It is not shown to them
  again, here or on another device.
- **Several notes** come up together in one box, the newest first.
- **Never over an open check.** While a check, a form or another screen is open, the note waits. It comes up
  when the person is back at the floor or the list.
- **In the middle of service** a new note reaches the people already signed in within seconds, the same
  way: over the floor or the list.
- **To read them again:** while at least one note is up, the orders screen has **Notes** under **More**
  (`home-screen.md`), and the tile says how many are up. With no note up there is no such entry.

### Writing a note (a manager)

Either way leads to the same screen:

- Orders screen › **Location** (manager PIN) › **Notes for the shift**, or
- **Notes** under **More** on the orders screen, when a note is up, then **Write or change notes** and the PIN.

**Write a note** asks for the words (500 letters at most, lines kept) and how long it is up:

- **For tonight**: it comes down by itself when the night is over, at 4 AM. A note written after midnight
  belongs to the night that is ending.
- **Until taken down**: it stays up until a manager takes it down.

The manager who writes a note is counted as having seen it. Twelve notes can be up at once.

Under each note the screen says **Seen by 3 of 8 · not yet: Ben, Holly**. A tap lists who has seen it and
when, and who has not.

- **Change**: new words show the note to everybody again, once (not to the manager who changed it). Changing
  only how long it is up shows it to nobody again.
- **Take down**: after a question. Nobody is shown it any more. Nothing is deleted: the notes that came down
  in the last 14 days are listed under the ones that are up, each with when it came down, who took it down,
  and how many people had seen it.

## The manager's log

Orders screen › **Location** (manager PIN) › **Manager's log**. Only a manager reads or writes it.

- **Write in the log**: pick what it is about, then type (2,000 letters at most). The subjects are
  **Guests, Staff, Kitchen, Bar, Repairs, Deliveries, Money, Other**. The hub stamps who wrote it and when.
- **Reading it**: the newest entry first, under the day it was written in. An entry written after midnight
  is under the night before, until 4 AM.
- **By subject**: a chip for each subject that has entries, with how many. A tap narrows the log to it;
  **All** shows every entry again.
- **Finding**: the box finds the entries holding every word typed, in the entry or in the name of who wrote
  it, in the whole log.
- **Older entries**: the log is read 50 entries at a time; the button at the foot reads the 50 before.
- **Nothing is changed or deleted.** A mistaken entry is **struck out** (the crossed icon beside it, after a
  question): it stays in its place, crossed out and readable, with who struck it and when. It is no longer
  counted on its subject's chip. To correct an entry, strike it out and write a new one.

## Good to know

- Both need the hub or the cloud. With nothing answering, no note comes up and the screens say the hub is
  not answering.
- If the hub could not be told about a "Got it" (a bad moment on the network), the screen tells it again
  later and does not show the note twice.
- A screen that changes hands while a note is up (it locked, and somebody else signed in) marks nobody: the
  person who tapped the button gets the note as their own, and the first person gets it at their next
  sign-in.
- "Who has not seen it yet" is everybody on the staff list, so it names people who are off today too.
- A note is for everybody. It cannot be aimed at the servers or the bar alone.
- An app that is not rebuilt shows no notes and has no log. A hub that is not updated: the app shows
  nothing new, and Location's two rows say the hub is older.

## Not built

- A note for one role or one person only.
- A note that starts on a later day, or one that repeats every week.
- Putting a note that came down back up (write it again).
- Printing the notes or the log, and sending the log by email.
- Subjects of your own in the log, and pictures on an entry.
- Writing in the log from a screen that is not behind the manager's PIN.

## For developers

- Rules and stores: `backend/src/pos/notes.py`. `ShiftNotes` over a `NoteStore` (memory) or `PgNoteStore`
  (tables `shift_note`, `shift_note_seen`, `manager_log`; created when the database is not a standby).
  `create_app(notes=...)` takes one; `app.state.notes` holds it.
- Calls: `backend/src/pos/api/notes.py` (`add_shift_notes`).
  - `GET /notes?staff_id=`: the notes that are up, each with `seen` for that person, and `unseen`. No
    token: staff have none, as for their display settings. 404 `unknown_staff`.
  - `POST /notes/seen` `{staff_id, note_ids}`.
  - Manager token: `GET /notes/board` (each note with `seen` and `waiting`, and `earlier`), `POST /notes`
    `{text, lasts}` (`tonight` or `stays`; 409 `too_many`), `PUT /notes/{id}` (409 `ended`),
    `DELETE /notes/{id}`.
  - Manager token: `GET /logbook?subject=&q=&before=&limit=` (`subjects` with counts, `entries`, `more`),
    `POST /logbook` `{subject, text, device}`, `POST /logbook/{id}/strike`.
- A change to the notes tells the screens on the change feed with the topic `notes`
  (`LiveChange.notes` in the app); a hub without the feed is asked every two minutes.
- App: `lib/shift_notes.dart` (the answers and their words); `ShiftNotesDialog` and `NoteWords`
  (`lib/screens/shift_notes_dialog.dart`); `ShiftNotesScreen` and `NoteFormDialog`; `LogbookScreen` and
  `LogEntryDialog`; `_readNotes` in the orders screen, which shows the box only while that screen is in
  front and only for the person the notes were read for.
- Tests: `backend/tests/test_notes.py`, `apps/pos_app/test/shift_notes_test.dart`.
