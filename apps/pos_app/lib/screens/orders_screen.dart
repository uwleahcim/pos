import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../address_list.dart';
import '../api.dart';
import '../camera.dart';
import '../coursing.dart';
import '../customers.dart';
import '../deliveries.dart';
import '../delivery_fee.dart';
import '../desk_phone_watcher.dart';
import '../floor.dart';
import '../kitchen_bell.dart';
import '../live.dart';
import '../local_order.dart';
import '../moves.dart';
import '../online_orders.dart';
import '../outbox.dart';
import '../phone.dart';
import '../points.dart';
import '../photos.dart';
import '../powers.dart';
import '../print_relay.dart';
import '../roster.dart';
import '../session.dart';
import '../shift_notes.dart';
import '../switching.dart';
import '../tags.dart';
import '../settings.dart';
import '../check_search.dart';
import '../takeout.dart';
import '../to_go_stages.dart';
import '../reservations.dart';
import '../waitlist.dart';
import 'booked_mark.dart';
import 'booked_table_dialog.dart';
import 'booking_dialog.dart';
import 'check_search_bar.dart';
import 'compact.dart';
import 'contests_screen.dart';
import 'deliveries_screen.dart';
import 'display_dialog.dart';
import 'driver_picker.dart';
import 'event_fields.dart';
import 'fee_lookup.dart';
import 'floor_view.dart';
import 'guest_tag_mark.dart';
import 'hand_over.dart';
import 'location_settings_screen.dart';
import 'menu_editor.dart';
import 'online_orders_screen.dart';
import 'order_screen.dart';
import 'orders_ahead_screen.dart';
import 'phone_bar.dart' show callStripRoom;
import 'rush.dart';
import 'server_picker.dart';
import 'shift_notes_dialog.dart';
import 'shift_notes_screen.dart';
import 'settings_screen.dart';
import 'status_bar.dart';
import 'tab_dialog.dart';
import 'table_moves.dart';
import 'theme.dart';
import 'time_clock_card.dart';
import 'today_screen.dart';
import 'turn_dialog.dart';
import 'waste_screen.dart';
import 'to_go_chips.dart';
import 'reservations_screen.dart';
import 'waitlist_screen.dart';

/// The home screen: the floor map (tap a table to seat it or open its check), or the list of open checks.
/// Both refresh every two seconds; a later slice replaces polling with a push.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.settings,
    required this.session,
    required this.camera,
    required this.photos,
    this.relay,
    this.phone,
    this.deskPhones,
    this.tags,
    this.bell,
  });

  final PosApi api;
  final Outbox outbox;
  final Settings settings;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay? relay;

  /// A kitchen screen's chime, for the device's Settings to play.
  final KitchenBell? bell;

  /// This terminal's tag reader, which a manager enrolls tags with in Location settings.
  final TagReader? tags;

  /// The terminal's phone, when it is one: a caller on the line, or just off it, goes into a to-go order.
  final PhoneClient? phone;

  /// The desk phones linked to this device: a call taken on one opens the caller's order here, as if this
  /// terminal had picked up.
  final DeskPhoneWatcher? deskPhones;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = const [];
  bool _showClosed = false;
  // The floor map or the list of checks. It starts on what the device opens on (Settings.opensOn) with
  // each sign-in, and goes back to that when another person takes the screen over or the device's choice
  // changes. The button in the bar switches between the two.
  bool _floor = true;
  String _opensOn = Settings.floorMap;
  String? _staffId; // who was last signed in on this screen
  final _floorKey = GlobalKey<FloorViewState>();
  Timer? _timer;
  // The hub tells this screen when an order changed; the timer only asks while it cannot, and now and then.
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(seconds: 1), _read);
  StreamSubscription<LiveChange>? _live;
  // The counts as they stood when this screen came up, so only what happens from now on opens anything (set
  // here, not lazily: the first notification may be the one that moves a count).
  int _orderRequests = 0;
  int _answers = 0;
  int _deskCalls = 0;
  bool _ordering = false; // the to-go form is open
  bool _inFront = true; // no check, screen or dialog is open over this one
  // The quote times as the hub last gave them: a rush shows above the checks, for everyone taking orders.
  Quotes? _quotes;
  bool _quotesStale = true; // the hub said a setting changed, or nothing was read yet
  // Whether the location uses the time clock: read with the quotes, for the Time clock entry of the menu.
  bool _clockOn = false;
  // Notes for the shift (docs/shift-notes.md): what the person at the screen has not seen yet comes up once,
  // over the floor or the list, never over an open check. They are read at each sign-in, when the hub says
  // the notes changed, and now and then while it cannot say.
  bool _notesStale = true;
  DateTime _notesRead = DateTime.fromMillisecondsSinceEpoch(0);
  String? _notesFor; // who is signed in, as the notes last heard; null while nobody is
  bool _notesBusy = false; // a reading is out, or the notes are on the screen
  int _notesUp = 0; // how many are up: the menu then offers them to read again
  // How many contests are on the staff's screens (docs/contests.md): the menu then offers their boards. Read
  // with the quotes: when the hub says a setting changed, and now and then, which is also how a contest
  // comes off the menu a week after it ended.
  int _contestsShown = 0;
  // What "Got it" was tapped on here, until the hub has kept it: shown once even when the hub was slow to hear.
  final _notesGot = <String>{};
  DateTime _quotesRead = DateTime.fromMillisecondsSinceEpoch(0);
  // The waitlist (docs/waitlist.md) as the hub last gave it: how many parties wait shows on its button, red
  // when one is past the time it was told. Null until it was read, and from a hub older than the list. Read
  // when the hub says the list changed, and now and then while it cannot say.
  Waitlist? _wait;
  bool _waitStale = true;
  DateTime _waitRead = DateTime.fromMillisecondsSinceEpoch(0);
  // Today's reservation book (docs/reservations.md) as the hub last gave it: the booked tables still to sit
  // down are counted on the waitlist's button, amber when one is near its time and red when one is past
  // it. Null until it was read, and from a hub older than the book. Read like the waitlist.
  Book? _book;
  bool _bookStale = true;
  DateTime _bookRead = DateTime.fromMillisecondsSinceEpoch(0);
  // How the online orders are doing (docs/online-orders.md), for a manager's alert: read only while a
  // manager or an owner is signed in, when the hub says there is something to look at, and now and then (that
  // the website stopped answering is nothing the hub announces). Null until it was read, and from an older hub.
  OnlineStatus? _online;
  bool _onlineStale = true;
  int _onlineTicks = 0; // of this screen's two-second timer since it was last due by itself
  // Rings once, at the next moment the clock alone changes what this screen shows: an order for later
  // nears its start, or the rush runs out. Nothing here redraws by the second.
  Timer? _clock;
  // The chip the list of checks is narrowed to (Later, Cooking, Ready, Unpaid); null lists every check.
  ToGoChip? _chip;
  // The list of checks is narrowed to the bar's open tabs, by the name on each (the Tabs chip).
  bool _tabsOnly = false;
  // Finding a check: the search box is open in the chips' row, the list holds closed checks too and is
  // narrowed to what is typed. A manager can list another day's checks ([_findDay]; null is now).
  bool _finding = false;
  final _find = TextEditingController();
  final _findFocus = FocusNode(debugLabel: 'find a check');
  DateTime? _findDay;
  // The staff as the hub last listed them: who a table can be given to, and who gives tables out.
  Roster _roster = Roster.none;
  bool _rosterAsked = false; // the staff list was asked for, whatever came of it
  late Future<void> _rosterRead;

  @override
  void initState() {
    super.initState();
    _opensOn = widget.settings.opensOn;
    _floor = widget.settings.opensOnFloor;
    _staffId = widget.session.staff?.staffId;
    _notesFor = _staffId;
    _rosterRead = _readRoster();
    _orderRequests = widget.phone?.orderRequests ?? 0;
    _answers = widget.phone?.answers ?? 0;
    _deskCalls = widget.deskPhones?.calls ?? 0;
    // Under an open check nobody sees the list: it stops asking, and reads again the moment it is back.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      // the online orders are read again every half minute, told or not
      if (++_onlineTicks >= 15) {
        _onlineTicks = 0;
        _onlineStale = true;
        if (_inFront) unawaited(_readOnline());
      }
      if (_inFront && _poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.settings || change.everything) _quotesStale = true;
      if (change.notes || change.everything) _notesStale = true;
      if (change.waitlist || change.everything) _waitStale = true;
      if (change.reservations || change.everything) _bookStale = true;
      if (change.online || change.everything) _onlineStale = true;
      // a party seated from the book or the waitlist, or put back: its check says whose it is
      if (_inFront && (change.anyOrder || change.reservations || change.waitlist)) _reader();
      if (_inFront && change.notes) unawaited(_readNotes());
      if (_inFront && change.waitlist) unawaited(_readWait());
      if (_inFront && change.reservations) unawaited(_readBook());
      if (_inFront && change.online) unawaited(_readOnline());
    });
    widget.outbox.addListener(_onOutbox);
    widget.settings.addListener(_onOpensOn);
    widget.session.addListener(_onOpensOn);
    widget.session.addListener(_onNotesSession);
    widget.phone?.addListener(_onPhone);
    widget.deskPhones?.addListener(_onDeskPhone);
    // A desk phone picked up just before someone signed in: its call is still waiting, if it is fresh.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeDeskCall());
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inFront = ModalRoute.isCurrentOf(context) ?? true;
    if (inFront && !_inFront) _refresh();
    _inFront = inFront;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock?.cancel();
    _find.dispose();
    _findFocus.dispose();
    unawaited(_live?.cancel());
    _reader.cancel();
    widget.outbox.removeListener(_onOutbox);
    widget.settings.removeListener(_onOpensOn);
    widget.session.removeListener(_onOpensOn);
    widget.session.removeListener(_onNotesSession);
    widget.phone?.removeListener(_onPhone);
    widget.deskPhones?.removeListener(_onDeskPhone);
    super.dispose();
  }

  void _onOutbox() {
    if (mounted) setState(() {});
  }

  /// The device was given another screen to open on, or another person took this screen over (a hands-free
  /// switch, or signing in on a locked screen): it shows what the device opens on. The same person coming
  /// back to a locked screen finds it as they left it, and a lock by itself changes nothing.
  void _onOpensOn() {
    if (!mounted) return;
    final opensOn = widget.settings.opensOn;
    final staffId = widget.session.staff?.staffId;
    final another = staffId != null && staffId != _staffId;
    if (staffId != null) _staffId = staffId;
    if (opensOn == _opensOn && !another) return;
    _opensOn = opensOn;
    final floor = widget.settings.opensOnFloor;
    if (floor == _floor) return;
    setState(() {
      _floor = floor;
      _moving = null; // a table is moved on the map: leaving it leaves the move
      _seating = null; // and so is a tab seated there
      _seatingParty = null; // and a party off the waitlist or out of the reservation book
    });
  }

  /// The caller changed, a call was picked up, or To go was tapped on the call strip: the caller's order
  /// opens, or the form opens for the caller, once.
  void _onPhone() {
    if (!mounted) return;
    final phone = widget.phone!;
    if (phone.answers != _answers) {
      _answers = phone.answers;
      unawaited(_callAnswered(phone.caller));
    }
    if (phone.orderRequests != _orderRequests) {
      _orderRequests = phone.orderRequests;
      if (!_ordering) unawaited(_newOrder());
    }
    setState(() {});
  }

  /// A call taken on a desk phone linked to this device: the same as picking up here. A call this terminal's
  /// own phone took is left to it, so one call opens one thing.
  void _onDeskPhone() {
    if (!mounted) return;
    final desk = widget.deskPhones!;
    if (desk.calls == _deskCalls) return;
    _deskCalls = desk.calls;
    _takeDeskCall();
  }

  void _takeDeskCall() {
    if (!mounted) return;
    final call = widget.deskPhones?.take();
    if (call == null) return;
    final own = widget.settings.phone;
    if (own.active && own.extension == call.extension) return;
    unawaited(_callAnswered(call.caller));
  }

  /// A call picked up on this terminal, or on a desk phone linked to it: the last order the number opened
  /// today comes up, so a customer calling back lands on their order; with none (or no number, or no hub
  /// answering) the to-go form opens for the caller instead. Whatever screen was open stays underneath for
  /// afterwards.
  Future<void> _callAnswered(Caller? caller) async {
    final number = caller?.number?.trim() ?? '';
    Order? order;
    if (number.isNotEmpty) {
      try {
        order = await widget.api.lastOrder(phone: number);
      } on ApiException {
        order = null; // nothing answers, or the hub refused: a new order is the next best thing
      }
    }
    if (!mounted) return;
    if (order != null) return _open(order.orderId);
    if (!_ordering) await _newOrder(caller: caller);
  }

  /// How far back "Show closed" lists: a day of checks, not every check the restaurant ever took.
  static const _closedWithin = Duration(hours: 24);

  Future<void> _refresh() => _reader.now();

  Future<void> _read() async {
    _poll.asked();
    unawaited(_readQuotes());
    unawaited(_readNotes());
    unawaited(_readWait());
    unawaited(_readBook());
    unawaited(_readOnline());
    try {
      // Finding a check looks through the closed ones too: the last day's, or the day a manager picked.
      final finding = _finding;
      final day = finding ? _findDay : null;
      final closedToo = finding || _showClosed;
      final orders = await widget.api.listOrders(
        status: closedToo ? null : 'open',
        within: closedToo ? _closedWithin : null,
        day: day,
      );
      // An answer to what the screen no longer asks (the search was closed, another day picked) is dropped.
      if (finding != _finding || day != (_finding ? _findDay : null)) return;
      // A backend with nothing new hands back the list it gave last time: nothing to redraw then.
      if (mounted && !identical(orders, _orders)) {
        setState(() => _orders = orders);
        _armClock();
      }
    } on ApiException {
      // The status bar already shows the outage; the list keeps its last picture.
    }
  }

  /// The quote times, for the rush strip: read when the hub says a setting changed, and now and then while
  /// it cannot say (twice a minute at most). The answer is the one already held unless something changed.
  Future<void> _readQuotes() async {
    final now = DateTime.now();
    if (!_quotesStale && now.difference(_quotesRead) < const Duration(seconds: 30)) return;
    _quotesStale = false;
    _quotesRead = now;
    unawaited(_readClockSetting());
    unawaited(_readContests());
    unawaited(_readPowers());
    // The staff are a manager's to change in the app (docs/staff.md): somebody added takes tables at once.
    unawaited(_readRoster());
    try {
      final quotes = await widget.api.quotes();
      if (!mounted || identical(quotes, _quotes)) return;
      setState(() => _quotes = quotes);
      _armClock();
    } on ApiException {
      // nothing answers, or a hub with no quotes: the strip keeps what it showed
    }
  }

  /// Who may do what (docs/roles.md), for the entries of the menu: read with the quote times, when the hub
  /// says a setting changed and now and then. When the table changed, so may have who takes tables and who
  /// gives them out, and the staff list is read again.
  Future<void> _readPowers() async {
    final before = widget.api.powers.value;
    final now = await widget.api.readPowers();
    if (!mounted || now == before) return;
    setState(() {});
    unawaited(_readRoster());
  }

  /// The waitlist, for the count on its button: read when the hub says the list changed, and now and then
  /// while it cannot say (twice a minute at most). The answer is the one already held unless it changed.
  Future<void> _readWait() async {
    final now = DateTime.now();
    if (!_waitStale && now.difference(_waitRead) < const Duration(seconds: 30)) return;
    _waitStale = false;
    _waitRead = now;
    try {
      final list = await widget.api.waitlist();
      if (!mounted || identical(list, _wait)) return;
      setState(() => _wait = list);
      _armClock();
    } on ApiException {
      // nothing answers and nothing was read before: the button keeps what it showed
    }
  }

  /// Today's reservation book, for the count of booked tables on the waitlist's button: read when the hub
  /// says the book changed, and now and then while it cannot say (twice a minute at most), which is also
  /// how the count starts over when the night ends. The answer is the one already held unless it changed.
  Future<void> _readBook() async {
    final now = DateTime.now();
    if (!_bookStale && now.difference(_bookRead) < const Duration(seconds: 30)) return;
    _bookStale = false;
    _bookRead = now;
    try {
      final book = await widget.api.reservations();
      if (!mounted || identical(book, _book)) return;
      setState(() => _book = book);
      _armClock();
    } on ApiException {
      // nothing answers: the button keeps what it showed
    }
  }

  /// How the online orders are doing, for the alert above the checks: read for a manager or an owner only,
  /// when the hub says there is something new to look at, and every half minute by this screen's own timer
  /// (that the website stopped answering, or answers again, is nothing the hub announces). The answer is the
  /// one already held unless something changed.
  Future<void> _readOnline() async {
    if (!_onlineStale || !alwaysRoles.contains(widget.session.staff?.role)) return;
    _onlineStale = false;
    try {
      final online = await widget.api.onlineStatus();
      if (!mounted || identical(online, _online)) return;
      setState(() => _online = online);
    } on ApiException {
      // nothing answers: the alert keeps what it said, and the status bar shows the outage
    }
  }

  /// How the online orders are doing, on a screen of its own: opening it is the looking, so the alert is over
  /// on every screen. A row there that is a check on the POS opens that check.
  Future<void> _onlineOrders() async {
    final orderId = await Navigator.of(context).push<Object?>(
      PosPageRoute(
        builder: (_) => OnlineOrdersScreen(
          api: widget.api,
          by: widget.session.staff?.name ?? '',
          status: _online,
          opensChecks: true,
        ),
      ),
    );
    if (!mounted) return;
    _onlineStale = true;
    unawaited(_readOnline());
    if (orderId is String && orderId.isNotEmpty) await _open(orderId);
  }

  /// The book was changed from here, or may have been on a screen that was just left: it is read again now.
  void _bookChanged() {
    _bookStale = true;
    unawaited(_readBook());
  }

  /// The waitlist: who is waiting for a table. **Seat** on a party there brings the floor map up, and the
  /// next table tapped is theirs ([_seatPartyAt]).
  Future<void> _waitlist() async {
    final staff = widget.session.staff;
    if (staff == null) return;
    final left = await Navigator.of(context).push<Object?>(
      PosPageRoute(
        builder: (_) => WaitlistScreen(
          api: widget.api,
          staffId: staff.staffId,
          list: _wait,
          book: _book,
          device: widget.settings.device,
        ),
      ),
    );
    if (!mounted) return;
    if (left is SeatParty) {
      setState(() {
        _seatingParty = left.party;
        _seating = null;
        _moving = null;
        _floor = true;
      });
    }
    _waitStale = true;
    unawaited(_readWait());
    _bookChanged(); // a booked party may have been marked from there, by another screen
    if (left is OpenReservations) unawaited(_reservations());
  }

  /// The reservation book (docs/reservations.md): the tables booked for today and the days ahead. **Seat**
  /// on a reservation of today brings the floor map up, and the next table tapped is theirs
  /// ([_seatPartyAt]), as for a party off the waitlist.
  ///
  /// With [day] the book opens at that day, and with [open] at that reservation of it: the one somebody is
  /// calling about.
  Future<void> _reservations({String? day, String? open}) async {
    final staff = widget.session.staff;
    if (staff == null) return;
    final left = await Navigator.of(context).push<Object?>(
      PosPageRoute(
        builder: (_) => ReservationsScreen(
          api: widget.api,
          staffId: staff.staffId,
          waitlist: _wait != null,
          day: day,
          open: open,
          device: widget.settings.device,
        ),
      ),
    );
    if (!mounted) return;
    _bookChanged(); // what was booked, changed or called off there is on the waitlist's button at once
    if (left is SeatBooking) {
      setState(() {
        _seatingParty = left.booking;
        _seating = null;
        _moving = null;
        _floor = true;
      });
    }
    if (left is OpenWaitlist) unawaited(_waitlist());
  }

  Future<void> _readClockSetting() async {
    try {
      final on = (await widget.api.clockSetting())?.enabled ?? false;
      if (mounted && on != _clockOn) setState(() => _clockOn = on);
    } on ApiException {
      // nothing answers: the menu keeps the entry it had
    }
  }

  Future<void> _readContests() async {
    try {
      final shown = (await widget.api.contestList())?.shown ?? 0;
      if (mounted && shown != _contestsShown) setState(() => _contestsShown = shown);
    } on ApiException {
      // nothing answers: the menu keeps the entry it had
    }
  }

  /// The contests for the staff: each with where the person signed in stands, and who is in front.
  Future<void> _contests() => Navigator.of(context).push(
    PosPageRoute<void>(
      builder: (_) => ContestsScreen(api: widget.api, device: widget.settings.device, staff: widget.session.staff),
    ),
  );

  /// Somebody else took the screen (a sign-in on a locked screen, a hands-free switch), or the same person
  /// came back to it: their notes are read at the next chance.
  void _onNotesSession() {
    final id = widget.session.staff?.staffId;
    if (id == _notesFor) return;
    _notesFor = id;
    if (id == null) return;
    _notesStale = true;
    _onlineStale = true; // a manager who has just signed in is alerted now, not within the half minute
    if (mounted && _inFront) {
      unawaited(_readNotes());
      unawaited(_readOnline());
    }
  }

  static String _noteKey(String staffId, ShiftNote note) => '$staffId/${note.id}/${note.editedMs ?? note.atMs}';

  /// The notes for the shift, for whoever is signed in: the ones they have not seen come up once, with one
  /// button, and the hub is told they have seen them. Only while the floor or the list is in front: an open
  /// check or a form is not interrupted, and the notes wait until this screen is back. A hub older than the
  /// notes, or one that does not answer, shows nothing.
  Future<void> _readNotes() async {
    final staff = widget.session.staff;
    if (staff == null || _notesBusy) return;
    final now = DateTime.now();
    if (!_notesStale && now.difference(_notesRead) < const Duration(minutes: 2)) return;
    _notesStale = false;
    _notesRead = now;
    _notesBusy = true;
    try {
      final mine = await widget.api.shiftNotes(staff.staffId);
      if (!mounted) return;
      final up = mine?.notes.length ?? 0;
      if (up != _notesUp) setState(() => _notesUp = up);
      final unseen = mine?.unseen ?? const <ShiftNote>[];
      final fresh = [
        for (final note in unseen)
          if (!_notesGot.contains(_noteKey(staff.staffId, note))) note,
      ];
      if (fresh.isNotEmpty) {
        // whoever took the screen meanwhile gets their own notes at the next reading
        if (!_inFront || widget.session.staff?.staffId != staff.staffId) {
          _notesStale = true;
          return;
        }
        final got = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ShiftNotesDialog(notes: fresh),
        );
        if (!mounted) return;
        // the screen locked under the notes and somebody else tapped the button: this person has not seen them
        if (got != true || widget.session.staff?.staffId != staff.staffId) {
          _notesStale = true;
          return;
        }
        _notesGot.addAll([for (final note in fresh) _noteKey(staff.staffId, note)]);
      }
      final tell = [
        for (final note in unseen)
          if (_notesGot.contains(_noteKey(staff.staffId, note))) note.id,
      ];
      if (tell.isEmpty) return;
      await widget.api.notesSeen(staff.staffId, tell);
      _notesGot.removeWhere((key) => key.startsWith('${staff.staffId}/'));
    } on ApiException {
      // nothing answers, or the hub could not keep it: asked again in a while, not at once
    } finally {
      _notesBusy = false;
    }
  }

  /// The notes that are up, to read again. A manager writes and changes them from there, with their PIN.
  Future<void> _notes() {
    _notesStale = true; // read again on the way back: a manager may have changed them
    return Navigator.of(context).push(
      PosPageRoute<void>(
        builder: (_) => ShiftNotesScreen(api: widget.api, device: widget.settings.device, staff: widget.session.staff),
      ),
    );
  }

  /// The time clock for whoever is at the screen: it asks for their own PIN, signed in or not.
  Future<void> _timeClock() => showDialog<void>(
    context: context,
    builder: (_) => TimeClockDialog(api: widget.api, device: widget.settings.device),
  );

  /// The waste log (docs/waste-log.md): anybody signed in writes down what was made and not sold.
  Future<void> _waste() => Navigator.of(context).push(
    PosPageRoute<void>(
      builder: (_) =>
          WasteScreen(api: widget.api, staffId: widget.session.staff?.staffId ?? '', device: widget.settings.device),
    ),
  );

  /// Sets [_clock] for the next moment the clock alone changes this screen: the rush running out, or an
  /// order for later nearing or reaching its time to start.
  void _armClock() {
    _clock?.cancel();
    final now = DateTime.now();
    DateTime? next;
    void consider(DateTime? at) {
      if (at != null && at.isAfter(now) && (next == null || at.isBefore(next!))) next = at;
    }

    final rush = _quotes?.rush;
    if (rush != null) consider(DateTime.fromMillisecondsSinceEpoch(rush.until));
    for (final order in _orders) {
      final promised = order.promisedAt;
      if (order.isTakeout && order.isOpen && order.forLater && promised != null) {
        consider(laterStageChanges(promisedAt: promised, quotedMinutes: order.quotedMinutes, now: now));
      }
    }
    // the count of parties waiting turns amber, then red, with the one that has waited longest for its time
    final hubNow = widget.api.nowMs();
    final turns = _wait?.nextLevelChange(hubNow);
    if (turns != null) consider(now.add(Duration(milliseconds: turns - hubNow)));
    // and the count of booked tables with the reservation that is next near its time, or past it
    final due = _book?.nextChange(hubNow);
    if (due != null) consider(now.add(Duration(milliseconds: due - hubNow)));
    final at = next;
    if (at == null) return;
    _clock = Timer(at.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {});
      _armClock();
    });
  }

  /// A manager says the kitchen is behind, or that it has caught up: minutes on every new quote, on every
  /// screen, until the night is over. The hub takes it from the PIN of a manager, or of someone the
  /// location handed the rush to.
  Future<void> _rush() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.settings.device,
        action: 'Set the rush',
        what: 'add minutes to the quotes',
        power: 'rush',
      ),
    );
    if (token == null || !mounted) return;
    final current = _quotes?.rushAt(DateTime.now()) ?? 0;
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => RushSheet(current: current),
    );
    if (minutes == null || minutes == current || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await widget.api.saveRush(token, minutes);
      if (!mounted) return;
      setState(() => _quotes = saved);
      _armClock();
      messenger.showSnackBar(
        SnackBar(
          key: const ValueKey('rush-said'),
          content: Text(
            minutes == 0
                ? 'The rush is off. New orders get the usual quote.'
                : 'New to-go orders are quoted $minutes minutes longer on every screen, until closing.',
          ),
        ),
      );
    } on ApiException catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('The rush was not changed: ${err.message}')));
    }
  }

  /// The checks to list: the backend's, and before them the ones opened on this screen that no backend has
  /// heard of yet (their create is still queued), so a check taken offline can be reopened. Another day's
  /// checks are the backend's alone: what is queued here is today's.
  List<(Order, bool)> get _listed {
    if (_finding && _findDay != null) {
      // A hub from before days answers with the last day's checks whatever day was asked: those say no
      // opening time, and are not that day's.
      return [
        for (final o in _orders)
          if (o.openedMs != null) (o, false),
      ];
    }
    final queued = queuedOrders(widget.outbox).where((q) => !_orders.any((o) => o.orderId == q.orderId));
    return [for (final q in queued) (q, true), for (final o in _orders) (o, false)];
  }

  /// Opens the search box in the chips' row: the list takes in the closed checks of the last day.
  void _startFinding() {
    setState(() {
      _finding = true;
      _chip = null;
      _tabsOnly = false;
    });
    unawaited(_refresh());
  }

  /// Closes the search: the list is the open checks again (and the closed ones, if they were shown).
  void _stopFinding() {
    if (!_finding) return;
    setState(() {
      _finding = false;
      _findDay = null;
      _find.clear();
    });
    unawaited(_refresh());
  }

  /// A manager looks through another day's checks: the calendar goes back a year and never forward.
  Future<void> _pickFindDay() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _findDay ?? today,
      firstDate: today.subtract(const Duration(days: 366)),
      lastDate: today,
      helpText: 'Checks opened on',
    );
    if (picked == null || !mounted) return;
    setState(() => _findDay = DateTime(picked.year, picked.month, picked.day));
    unawaited(_refresh());
  }

  void _clearFindDay() {
    setState(() => _findDay = null);
    unawaited(_refresh());
  }

  /// Counter mode (architecture section 12): name and phone first, the channel, when it is for. The hub
  /// numbers the order when the create arrives; the quote comes from the hub's settings per channel. With a
  /// caller on the phone, or just off it, or [caller] from a desk phone, the form starts with the number,
  /// the channel and the caller-ID name.
  Future<void> _newOrder({Caller? caller}) async {
    if (_ordering) return;
    _ordering = true;
    try {
      Quotes quotes;
      try {
        quotes = await widget.api.quotes();
      } on ApiException {
        quotes = _quotes ?? const Quotes(); // as last read, or the hub's own defaults, until it answers
      }
      if (!mounted) return;
      final who = caller ?? widget.phone?.callerForOrder;
      final asked = await showDialog<Object>(
        context: context,
        builder: (context) => _TakeoutDialog(
          quotes: quotes,
          api: widget.api,
          caller: who,
          by: widget.session.staff?.name,
          underCall: widget.phone?.onCall ?? false,
        ),
      );
      if (!mounted) return;
      // The call was about a table and not about food: the reservation form, or the reservation they have.
      switch (asked) {
        case TakeoutRequest request:
          await _startOrder(request, quotes);
        case _BookForCaller wanted:
          await _bookForCaller(wanted);
        case Booking theirs:
          // the book is a screen of its own: a call picked up while it is open still gets its form
          unawaited(_reservations(day: theirs.day, open: theirs.id));
      }
    } finally {
      _ordering = false;
    }
  }

  /// **Book a table** on the to-go form (docs/reservations.md): the reservation form comes up with the
  /// name and the number the to-go form had, so somebody who calls for a table is booked without a word
  /// typed twice. The book says the day it is and what it takes; with no hub answering it is said so, since
  /// the book is kept there.
  Future<void> _bookForCaller(_BookForCaller who) async {
    final staff = widget.session.staff;
    if (staff == null) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String words, {SnackBarAction? action}) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: const ValueKey('call-booking'), content: Text(words), action: action));
    final Book? book;
    try {
      book = await widget.api.reservations();
    } on ApiException {
      return say('The hub cannot be reached, and the reservation book is kept there. Try again in a moment.');
    }
    if (book == null) return say('This hub is older than reservations. Update the hub for them.');
    if (!mounted) return;
    final after = await showDialog<Book>(
      context: context,
      builder: (_) => BookingDialog(
        api: widget.api,
        staffId: staff.staffId,
        book: book!,
        name: who.name,
        phone: who.phone,
        underCall: widget.phone?.onCall ?? false,
      ),
    );
    final made = after?.booking;
    if (after == null || made == null || !mounted) return;
    _bookChanged(); // a table booked for today is one more to come
    final day = bookDayWords(made.day, after.today);
    final on = day == 'Today' || day == 'Tomorrow' ? day.toLowerCase() : day;
    say(
      '${made.name} is booked for $on at ${made.time}',
      action: SnackBarAction(
        label: 'The book',
        onPressed: () => unawaited(_reservations(day: made.day)),
      ),
    );
  }

  /// Opens the to-go order the form asked for. A note about the customer changed on the form is kept first,
  /// so the order's screen reads the new one. For "Same again" the past order's dishes go on as the menu
  /// sells them today, each to the course a dish rung in by hand would go to; the operator is told which
  /// prices moved and which dishes were left off, while the customer is still on the call.
  Future<void> _startOrder(TakeoutRequest request, Quotes quotes) async {
    // The quote is the channel's minutes and tonight's rush. A time the customer named stays theirs: the
    // quote then says how long before it the kitchen starts. A delivery for now where live traffic is on
    // is promised by the drive the form was told: the order keeps the promise, never the drive.
    final now = DateTime.now();
    final minutes = quotes.minutesFor(
      request.channel,
      at: now,
      promised: request.promisedAt,
      delivery: request.event?.delivered ?? false, // brought to them: the cooking and the drive
      drive: request.driveNow,
    );
    final promised = request.promisedAt ?? now.add(Duration(minutes: minutes));
    final staff = widget.session.staff;
    final messenger = ScaffoldMessenger.of(context);
    final note = request.note;
    if (note != null) {
      try {
        await widget.api.saveCustomerNote(request.phone, note, by: staff?.name);
      } on ApiException {
        messenger.showSnackBar(const SnackBar(content: Text('The note about the customer was not saved.')));
      }
    }
    final lines = <(String, Map<String, dynamic>)>[];
    final past = request.again;
    if (past != null) {
      String said;
      var long = true;
      try {
        final again = await widget.api.again(past);
        Coursing coursing;
        try {
          coursing = await widget.api.coursing();
        } on ApiException {
          coursing = Coursing.defaults;
        }
        final course = coursing.enabled ? coursing.defaultCourse : null;
        for (final line in again.lines) {
          lines.add((
            'add_line',
            {
              'line_id': widget.outbox.newId(),
              'item': line.item,
              'qty': line.qty,
              'course': ?course,
              if (staff != null) 'by': staff.name,
              if (staff != null) 'by_id': staff.staffId,
              if (line.note.isNotEmpty) 'note': line.note,
              'request': line.request,
            },
          ));
        }
        said = again.said;
        long = again.needsTelling || again.lines.isEmpty;
      } on ApiException {
        said = 'The past order could not be read. Nothing was added.';
      }
      messenger.showSnackBar(
        SnackBar(
          key: const ValueKey('again-said'),
          duration: Duration(seconds: long ? 10 : 4),
          content: Text(said),
        ),
      );
    }
    if (!mounted) return;
    await _create({
      'order_type': 'takeout',
      'channel': request.channel,
      'customer_name': request.name,
      if (request.phone.isNotEmpty) 'phone': request.phone,
      'locale': request.locale,
      'quoted_minutes': minutes,
      'promised_at': promised.millisecondsSinceEpoch,
      if (request.promisedAt != null) 'for_later': true,
      'stage': 'new',
      // what a catering order's event needs, and where a delivery goes: only what was filled in
      for (final MapEntry(:key, :value) in (request.event?.toFields() ?? const <String, dynamic>{}).entries)
        if (value != null && value != '') key: value,
      // what the delivery costs: the band alone, and the hub fills in the amount
      if (request.fee case final fee? when request.event?.delivered ?? false)
        'delivery_fee': FeePick.field(fee, measured: request.measured),
    }, lines: lines);
  }

  /// A bar tab: a check with a name and no table, rung in and sent like a table's. It is found again in the
  /// list of checks (the Tabs chip, or its name in the search) and is on no floor map until the party sits
  /// down and it is given a table ([_seatAt]).
  Future<void> _newTab() async {
    final name = await showDialog<String>(context: context, builder: (_) => const TabDialog());
    if (name == null || !mounted) return;
    await _create({'order_type': 'dine_in', 'tab': true, 'customer_name': name});
  }

  /// Ready sends the customer their text (the hub does, once); picked up closes the check. An order a
  /// deposit was taken on is asked for the rest as it is handed over (docs/catering.md): cash or paid
  /// elsewhere, or not now, which closes the check with the rest still due, as an order nothing was paid on
  /// always closed.
  Future<void> _setStage(Order order, String stage) =>
      setToGoStage(context, outbox: widget.outbox, order: order, stage: stage, by: widget.session.staff?.name);

  /// A delivery leaves (docs/delivery.md): asks which driver takes it, and says so on the order. Nothing
  /// is written when nobody is picked.
  Future<void> _sendOut(Order order) async {
    final driver = await DriverPicker.ask(
      context,
      drivers: _roster.drivers,
      deliveries: deliveriesOf(_orders, DateTime.now()),
    );
    if (driver == null || !mounted) return;
    await widget.outbox.addAll(order.orderId, [
      (
        'set_field',
        {
          ...outFields(driver, DateTime.now().millisecondsSinceEpoch),
          'by': ?widget.session.staff?.name,
          'by_id': ?widget.session.staff?.staffId,
        },
      ),
    ]);
  }

  /// The deliveries on a screen of their own: what waits to leave, and what each driver has out.
  Future<void> _deliveries() async {
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => DeliveriesScreen(
          api: widget.api,
          outbox: widget.outbox,
          session: widget.session,
          roster: _roster,
          onOpen: _open,
        ),
      ),
    );
    if (mounted) unawaited(_refresh());
  }

  /// The orders ahead (docs/catering.md): what was promised for a later time, by the day it is for, with
  /// the money on each. A tap on one opens it.
  Future<void> _ahead() async {
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => OrdersAheadScreen(api: widget.api, onOpen: _open),
      ),
    );
    if (mounted) unawaited(_refresh());
  }

  /// The night as it stands on one screen (docs/today.md), behind the PIN of whoever may see the reports.
  Future<void> _today() async {
    Set<String>? holds;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.settings.device,
        action: 'Open Today',
        what: "see today's figures",
        power: 'reports',
        onPowers: (powers) => holds = powers,
      ),
    );
    if (token == null || !mounted) return;
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => TodayScreen(
          api: widget.api,
          token: token,
          holds: holds,
          by: widget.session.staff?.name,
          device: widget.settings.device,
        ),
      ),
    );
  }

  /// What a manager sets for the whole location (coursing, quote times) and reads of it (the day, the
  /// sales), behind a PIN. The screen shows what the PIN's owner may open (docs/roles.md): everything to a
  /// manager, and to anyone else what the location handed their role.
  Future<void> _location() async {
    Set<String>? holds;
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.settings.device,
        action: 'Open location settings',
        what: 'change location settings',
        power: null,
        onPowers: (powers) => holds = powers,
      ),
    );
    if (token == null || !mounted) return;
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => LocationSettingsScreen(
          api: widget.api,
          token: token,
          holds: holds,
          staffId: widget.session.staff?.staffId,
          by: widget.session.staff?.name,
          device: widget.settings.device,
          camera: widget.camera,
          tags: widget.tags,
        ),
      ),
    );
  }

  /// Opens a new check with these fields, stamped with its server, and shows it. The server is whoever is
  /// signed in, unless a host or manager sat the party [for_] someone else: then the check is that person's,
  /// the log keeps who sat it, and the screen stays on the floor for the next party. [lines] are operations
  /// the check starts with (the dishes of "Same again"), queued right behind its create.
  Future<void> _create(
    Map<String, dynamic> fields, {
    StaffMember? for_,
    String? label,
    String? orderId,
    List<(String, Map<String, dynamic>)> lines = const [],
  }) async {
    final staff = widget.session.staff;
    final given = for_ != null && for_.staffId != staff?.staffId;
    orderId ??= widget.outbox.newId();
    final opId = await widget.outbox.add(orderId, 'create', {
      ...fields,
      if (given) ...{
        'server': for_.name,
        'server_id': for_.staffId,
        if (staff != null) 'by': staff.name,
        if (staff != null) 'by_id': staff.staffId,
      } else if (staff != null) ...{
        'server': staff.name,
        'server_id': staff.staffId,
      },
    });
    if (lines.isNotEmpty) await widget.outbox.addAll(orderId, lines);
    unawaited(widget.photos.capture('create', opId: opId));
    if (!mounted) return;
    if (!given) return _open(orderId);
    _floorKey.currentState?.refresh();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${label ?? fields['table'] ?? 'The table'} is ${for_.name}\'s')));
  }

  /// The staff as the hub lists them now, or as this device last read them. A hub older than the list has
  /// none: everyone seats their own tables there.
  Future<void> _readRoster() async {
    try {
      final roster = await widget.api.staff();
      if (mounted) _roster = roster;
    } on ApiException {
      // keeps what it has
    }
    // The floor map offers "Mine" by what the list says of the person signed in.
    if (mounted && !_rosterAsked) setState(() => _rosterAsked = true);
  }

  /// Who "Mine" on the floor map is offered to: the person signed in, when a table can be theirs. The hub's
  /// staff list says so; a hub with no list leaves it to everyone. Nobody until the list was asked for, so the
  /// chip does not show and go for a host; someone who has it on keeps it from the first frame.
  StaffMember? get _me {
    final staff = widget.session.staff;
    if (staff == null) return null;
    final listed = _roster.byId(staff.staffId);
    if (!widget.session.prefs.myTables && !(_rosterAsked && (listed?.takesTables ?? true))) return null;
    return listed ?? StaffMember(staffId: staff.staffId, name: staff.name, role: staff.role, takesTables: true);
  }

  /// "Mine" was tapped: kept with the person's own settings, so it is on at the next device they sign in on.
  /// A hub that cannot keep it leaves it on here until they sign out.
  void _setMine(bool on) {
    unawaited(widget.session.savePrefs(widget.session.prefs.copyWith(myTables: on)));
    if (mounted) setState(() {});
  }

  /// The staff list for seating a party: read at start; asked for again when that came to nothing and a hub
  /// answers now, and each time the person signed in gives tables out (the list may have changed).
  Future<Roster> _rosterNow() async {
    await _rosterRead;
    final asks = _roster.assigns(widget.session.staff?.staffId);
    if (asks || (_roster.staff.isEmpty && widget.api.connection.value.isOnline)) {
      _rosterRead = _readRoster();
      await _rosterRead;
    }
    return _roster;
  }

  /// How whoever is signed in says who is in tonight's turn for a table (docs/table-servers.md); null for
  /// somebody who gives no tables out.
  SayTurn? _sayTurn(Roster roster) {
    final me = widget.session.staff;
    if (me == null || !roster.assigns(me.staffId)) return null;
    return (server, on) => widget.api.sayTurn(me.staffId, server.staffId, on: on);
  }

  /// The table whose checks are being moved: the next table tapped is where they go.
  TableSpot? _moving;

  /// A seated table was held down. Whoever it is can move it to another table; a host or manager can also
  /// hand it to another server, alone or with every other table its server has (a shift change). Every
  /// check on the table goes, since the table is the server's; the log keeps who handed it over.
  Future<void> _onTableHeld(FloorPlan plan, TableSpot table) async {
    final staff = widget.session.staff;
    final checks = plan.checksAt(table.id);
    if (checks.isEmpty) return;
    final roster = await _rosterNow();
    if (!mounted) return;
    if (!roster.assigns(staff?.staffId)) {
      // a server has one thing to do with a table held down: move it
      if (plan.moves) setState(() => _moving = table);
      return;
    }
    final current = roster.servers.where(checks.first.isServedBy).firstOrNull;
    final held = await showModalBottomSheet<Held>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          HeldSheet(table: table, plan: plan, servers: roster.servers, current: current, moves: plan.moves),
    );
    if (held == null || !mounted) return;
    final picked = held.server;
    if (picked == null) return setState(() => _moving = table);
    if (picked.staffId == current?.staffId) return;
    // every table of the server who has this one, when asked: their checks wherever they are on the floor
    final going = held.all && current != null
        ? [for (final here in plan.status.values) ...here.where((check) => check.isServedBy(current))]
        : checks;
    for (final check in going) {
      await widget.outbox.add(check.orderId, 'set_field', {
        'server': picked.name,
        'server_id': picked.staffId,
        if (staff != null) 'by': staff.name,
        if (staff != null) 'by_id': staff.staffId,
      });
    }
    if (!mounted) return;
    _floorKey.currentState?.refresh();
    final tables = {for (final check in going) plan.tableOf[check.orderId]}.length;
    final what = held.all && current != null && tables > 1
        ? '${current.name}\'s $tables tables are ${picked.name}\'s now'
        : '${table.label} is ${picked.name}\'s now';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(what)));
  }

  /// The table being moved was given a place: [to]. A free table takes its checks as they are. A seated one
  /// asks whether the two become one check or stay two checks at one table.
  Future<void> _moveTo(FloorPlan plan, TableSpot to) async {
    final from = _moving;
    if (from == null) return;
    final checks = plan.checksAt(from.id);
    if (to.id == from.id || checks.isEmpty) return setState(() => _moving = null);
    final staff = widget.session.staff;
    final there = plan.checksAt(to.id);
    var queue = moveTableOps(checks.map((check) => check.orderId), to.id, by: staff);
    var merged = false;
    if (there.isEmpty) {
      final go = await _bookedOk(plan, to, go: 'Move ${from.label} here');
      if (go != true || !mounted) return; // still moving: another table can be tapped
    }
    if (there.isNotEmpty) {
      // both sides as they stand, with what this screen has yet to send: one check means every dish moves
      Future<Order> read(String id) async => withLocalOps(await widget.api.order(id), widget.outbox.localOps(id));
      List<Order>? moving;
      Order? onto;
      try {
        moving = [for (final check in checks) await read(check.orderId)];
        onto = await read(there.first.orderId);
      } on ApiException {
        // nothing to read them from: they can still sit at one table as two checks
      }
      if (!mounted) return;
      final blocked = moving == null
          ? 'The hub cannot be reached right now, so the two checks cannot be put together.'
          : moving.map(cannotMerge).nonNulls.map((why) => '${from.label}\'s check $why.').firstOrNull;
      final landing = await showDialog<Landing>(
        context: context,
        builder: (_) => LandingDialog(
          from: from,
          to: to,
          blocked: blocked,
          note: moving != null && moving.any(hasCheckDiscount)
              ? 'The discount on ${from.label}\'s whole check stays behind. '
                    'Put it on ${to.label}\'s check again if it should count.'
              : null,
        ),
      );
      if (landing == null || !mounted) return; // still moving: another table can be tapped
      if (landing == Landing.merge && moving != null && onto != null) {
        merged = true;
        queue = [];
        for (final check in moving) {
          final ops = mergeOps(from: check, onto: onto!, newId: widget.outbox.newId, by: staff);
          queue.addAll(ops);
          // the next check that joins sits after the guests this one brought
          final taken = ops.where((entry) => entry.$1 == onto!.orderId).expand((entry) => entry.$2);
          onto = withLocalOps(onto, [
            for (final (kind, data) in taken) {'kind': kind, 'data': data},
          ]);
        }
      }
    }
    for (final (orderId, ops) in queue) {
      await widget.outbox.addAll(orderId, ops);
    }
    if (!mounted) return;
    setState(() => _moving = null);
    _floorKey.currentState?.refresh();
    final what = merged ? '${from.label} is on ${to.label}\'s check now' : '${from.label} moved to ${to.label}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(what)));
  }

  /// The location's coursing as the hub has it now, or as last read; with nothing read yet, the standard
  /// courses.
  Future<Coursing> _coursingNow() async {
    try {
      return await widget.api.coursing();
    } on ApiException {
      return Coursing.defaults;
    }
  }

  /// Whether a table has seats here, as the hub has it now or as last read; with nothing read yet it has,
  /// as every table had before a location could say.
  Future<bool> _seatsNow() async {
    try {
      return await widget.api.seats();
    } on ApiException {
      return true;
    }
  }

  Future<void> _open(String orderId) async {
    // How the location takes a table's order (its courses, and whether it has seats), asked together: a
    // manager's change reaches every terminal on the next order it opens.
    final (coursing, seats) = await (_coursingNow(), _seatsNow()).wait;
    if (!mounted) return;
    final left = await Navigator.of(context).push<Object?>(
      PosPageRoute(
        settings: const RouteSettings(name: SessionWatcher.orderRoute),
        builder: (_) => OrderScreen(
          api: widget.api,
          outbox: widget.outbox,
          photos: widget.photos,
          orderId: orderId,
          coursing: coursing,
          seats: seats,
          session: widget.session,
          phone: widget.phone,
        ),
      ),
    );
    // "Seat at a table" on a bar tab: the floor map comes up, and the next table tapped is the party's.
    if (left is SeatTab && mounted) {
      setState(() {
        _seating = left;
        _moving = null;
        _floor = true;
      });
    }
    _refresh();
    _floorKey.currentState?.refresh();
  }

  /// The bar tab being seated: the next table tapped on the floor map is where the party sits down.
  SeatTab? _seating;

  /// Seating the tab is over: it sat down, or the person thought better of it. On a device that goes back
  /// to sign-in after sending, whoever sent drinks from the tab and left it to seat it is signed out now.
  void _endSeating() {
    if (_seatingParty != null) setState(() => _seatingParty = null);
    final seating = _seating;
    if (seating == null) return;
    setState(() => _seating = null);
    if (seating.thenSignOut) unawaited(Future.microtask(widget.session.signOut));
  }

  /// The party being seated, off the waitlist or out of the reservation book: the next table tapped on the
  /// floor map is where it sits down.
  ArrivingParty? _seatingParty;

  /// The party being seated was given a place: [to]. A free table takes it like a party walking in, with
  /// its size filled in: how many guests, and for a host or manager whose table it is; a server who seats
  /// it takes the check. A table that is seated asks whether the party joins it: its guests are added to that
  /// table's check, and no new check is opened. Either way the list is told where the party sat.
  ///
  /// A free table that is booked for somebody else asks first ([_bookedOk]); with [warned], it has asked
  /// already.
  Future<void> _seatPartyAt(FloorPlan plan, TableSpot to, {bool warned = false}) async {
    final party = _seatingParty;
    if (party == null) return;
    final staff = widget.session.staff;
    final there = plan.checksAt(to.id);
    if (there.isEmpty) {
      if (!warned) {
        final go = await _bookedOk(plan, to, go: 'Seat ${party.name} here', but: party is Booking ? party.id : null);
        if (go != true || !mounted) return; // still seating: another table can be tapped
      }
      final roster = await _rosterNow();
      if (!mounted) return;
      final assigns = roster.assigns(staff?.staffId);
      final asked = await showDialog<Seating>(
        context: context,
        builder: (_) => _GuestsDialog(
          table: to,
          plan: plan,
          servers: assigns ? roster.servers : const [],
          me: roster.byId(staff?.staffId),
          onSayTurn: _sayTurn(roster),
          title: 'Seat ${party.name} at ${to.label}',
          guests: party.size,
        ),
      );
      if (asked == null || !mounted) return; // still seating: another table can be tapped
      final orderId = widget.outbox.newId();
      setState(() => _seatingParty = null);
      unawaited(_partySeated(party, to, orderId));
      await _create(
        {'table': to.id, 'guests': asked.guests, 'order_type': 'dine_in'},
        for_: asked.server,
        label: to.label,
        orderId: orderId,
      );
      return;
    }
    final first = there.first;
    final guests = (first.guests ?? 0) + party.size;
    final join = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${to.label} is seated'),
        content: Text(
          'Does ${party.label} join the table? Its check then counts ${guestWords(guests)}. '
          'For a table of their own, tap a free one.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('party-join'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Join ${to.label}'),
          ),
        ],
      ),
    );
    if (join != true || !mounted) return; // still seating: another table can be tapped
    await widget.outbox.add(first.orderId, 'set_field', {
      'guests': guests,
      if (staff != null) 'by': staff.name,
      if (staff != null) 'by_id': staff.staffId,
    });
    if (!mounted) return;
    setState(() => _seatingParty = null);
    _floorKey.currentState?.refresh();
    await _partySeated(party, to, first.orderId, done: '${party.name} joined ${to.label}');
  }

  /// A free table that is booked asks before somebody sits down there or a check is moved to it
  /// (docs/reservations.md): who it is kept for and for when. It warns, and refuses nothing. [go] is what
  /// going on is called; [but] is the reservation of the party being seated, whose own table needs no
  /// question. Answers `true` to go on, which a table nobody is waiting for answers without asking; a
  /// [TableHold] to seat that reservation's party instead (offered with [seats]); null to leave the table
  /// alone.
  Future<Object?> _bookedOk(
    FloorPlan plan,
    TableSpot table, {
    required String go,
    bool seats = false,
    String? but,
  }) async {
    final now = widget.api.nowMs();
    final holds = [
      for (final hold in plan.keptAt(table.id, now))
        if (hold.id != but) hold,
    ];
    if (holds.isEmpty) return true;
    return showDialog<Object>(
      context: context,
      builder: (_) => BookedTableDialog(table: table, holds: holds, nowMs: now, go: go, seats: seats),
    );
  }

  /// Tells the list that [party] sat down at [at], on the check [orderId]. The check is opened whatever the
  /// list answers: the guests are at the table. A list that cannot be told keeps the party, and says so.
  /// [done] is what to say when all went well; nothing when the screen shows it anyway (the check opens, or
  /// the table is said to be its server's).
  Future<void> _partySeated(ArrivingParty party, TableSpot at, String orderId, {String? done}) async {
    final staff = widget.session.staff;
    if (staff == null) return;
    final messenger = ScaffoldMessenger.of(context);
    String? words;
    try {
      if (party is Booking) {
        final book = await widget.api.seatBooking(staff.staffId, party.id, table: at.id, orderId: orderId);
        unawaited(_floorKey.currentState?.refresh()); // the table is no longer kept for them
        _bookChanged(); // and they are no longer to come
        final sat = book.booking;
        // another screen sat them first: the book keeps where that screen put them
        words = sat != null && sat.seatedTable.isNotEmpty && sat.seatedTable != at.id
            ? '${party.name} was already seated at ${sat.seatedLabel}. The book keeps that table.'
            : done;
      } else {
        final list = await widget.api.seatParty(staff.staffId, party.id, table: at.id, orderId: orderId);
        if (mounted) setState(() => _wait = list);
        final sat = list.party;
        // another screen sat them first: the list keeps where that screen put them
        words = sat != null && sat.table.isNotEmpty && sat.table != at.id
            ? '${party.name} was already seated at ${sat.tableLabel}. The list keeps that table.'
            : done;
      }
    } on ApiException {
      words = party is Booking
          ? '${party.name} is at ${at.label}, but the reservation book could not be told. '
                'Take the reservation out of the book when the hub is back.'
          : '${party.name} is at ${at.label}, but the waitlist could not be told. '
                'Take them off the list when the hub is back.';
    }
    if (mounted) _armClock();
    if (words != null) messenger.showSnackBar(SnackBar(key: const ValueKey('party-seated'), content: Text(words)));
  }

  /// The tab being seated was given a place: [to]. A free table takes it like a party walking in: how many
  /// guests, and for a host or manager whose table it is; anyone else who seats it takes the check, as
  /// with a table they open. Every dish keeps saying who rang it in. A seated table asks whether the tab
  /// joins that table's check or stays a check of its own there; either way it is that table's server's.
  Future<void> _seatAt(FloorPlan plan, TableSpot to) async {
    final seating = _seating;
    if (seating == null) return;
    final tab = seating.order;
    final staff = widget.session.staff;
    final who = {if (staff != null) 'by': staff.name, if (staff != null) 'by_id': staff.staffId};
    final there = plan.checksAt(to.id);
    List<OrderOps> queue;
    var merged = false;
    if (there.isEmpty) {
      final go = await _bookedOk(plan, to, go: 'Seat ${tab.tabLabel} here');
      if (go != true || !mounted) return; // still seating: another table can be tapped
      final roster = await _rosterNow();
      if (!mounted) return;
      final assigns = roster.assigns(staff?.staffId);
      final asked = await showDialog<Seating>(
        context: context,
        builder: (_) => _GuestsDialog(
          table: to,
          plan: plan,
          servers: assigns ? roster.servers : const [],
          me: roster.byId(staff?.staffId),
          onSayTurn: _sayTurn(roster),
          title: 'Seat ${tab.tabLabel} at ${to.label}',
        ),
      );
      if (asked == null || !mounted) return; // still seating: another table can be tapped
      final server = asked.server;
      queue = [
        (
          tab.orderId,
          [
            (
              'set_field',
              {
                'table': to.id,
                'guests': asked.guests,
                if (server != null) ...{
                  'server': server.name,
                  'server_id': server.staffId,
                } else if (staff != null) ...{
                  'server': staff.name,
                  'server_id': staff.staffId,
                },
                ...who,
              },
            ),
          ],
        ),
      ];
    } else {
      // both as they stand, with what this screen has yet to send: one check means every dish goes over
      Future<Order> read(String id) async => withLocalOps(await widget.api.order(id), widget.outbox.localOps(id));
      Order? moving, onto;
      try {
        moving = await read(tab.orderId);
        onto = await read(there.first.orderId);
      } on ApiException {
        // nothing to read them from: the tab can still sit at that table as a check of its own
      }
      if (!mounted) return;
      final why = moving == null ? null : cannotMerge(moving);
      final blocked = moving == null || onto == null
          ? 'The hub cannot be reached right now, so the two checks cannot be put together.'
          : !plan.moves
          ? 'This hub is older than putting two checks together. Update the hub for that.'
          : why == null
          ? null
          : '${tab.tabLabel} $why.';
      final landing = await showDialog<Landing>(
        context: context,
        builder: (_) => LandingDialog.tab(
          tab.tabLabel,
          to: to,
          blocked: blocked,
          note: moving != null && hasCheckDiscount(moving)
              ? 'The discount on the whole tab stays behind. '
                    'Put it on ${to.label}\'s check again if it should count.'
              : null,
        ),
      );
      if (landing == null || !mounted) return; // still seating: another table can be tapped
      if (landing == Landing.merge && blocked == null && moving != null && onto != null) {
        merged = true;
        queue = mergeOps(from: moving, onto: onto, newId: widget.outbox.newId, by: staff);
      } else {
        // a check of its own at that table: the table is its server's, so this check is too
        final first = there.first;
        queue = [
          (
            tab.orderId,
            [
              (
                'set_field',
                {
                  'table': to.id,
                  if (first.server != null && first.serverId != null) ...{
                    'server': first.server,
                    'server_id': first.serverId,
                  },
                  ...who,
                },
              ),
            ],
          ),
        ];
      }
    }
    for (final (orderId, ops) in queue) {
      await widget.outbox.addAll(orderId, ops);
    }
    if (!mounted) return;
    _endSeating();
    _floorKey.currentState?.refresh();
    unawaited(_refresh());
    final what = merged ? '${tab.tabLabel} is on ${to.label}\'s check now' : '${tab.tabLabel} sat down at ${to.label}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(key: const ValueKey('tab-seated'), content: Text(what)));
  }

  /// A free table seats a party; a busy one opens its check, or asks which one when it has several.
  Future<void> _onTable(FloorPlan plan, TableSpot table) async {
    if (_seatingParty != null) return _seatPartyAt(plan, table);
    if (_seating != null) return _seatAt(plan, table);
    if (_moving != null) return _moveTo(plan, table);
    final checks = plan.checksAt(table.id);
    if (checks.length == 1) return _open(checks.single.orderId);
    if (checks.length > 1) {
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in checks)
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: CircleAvatar(child: Text(table.label)),
                    title: Text('${table.label} · ${c.guests ?? '?'} guests · ${c.server ?? ''}'),
                    subtitle: Text('${c.items} items · ${c.total ?? ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pop(c.orderId),
                  ),
                const Divider(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('New check at this table'),
                  onTap: () => Navigator.of(context).pop(''),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      if (picked.isNotEmpty) return _open(picked);
    }
    if (checks.isEmpty) {
      // A table kept for a reservation asks first; the party walking in may be the one it is booked for.
      final go = await _bookedOk(plan, table, go: 'Seat a walk-in', seats: true);
      if (go == null || !mounted) return;
      if (go is TableHold) {
        setState(() => _seatingParty = Booking.ofHold(go, table));
        return _seatPartyAt(plan, table, warned: true);
      }
    }
    // A server takes a table by opening it. A host or manager says whose it is as they seat the party.
    final roster = await _rosterNow();
    if (!mounted) return;
    final me = widget.session.staff;
    final assigns = roster.assigns(me?.staffId);
    final seating = await showDialog<Seating>(
      context: context,
      builder: (_) => _GuestsDialog(
        table: table,
        plan: plan,
        servers: assigns ? roster.servers : const [],
        me: roster.byId(me?.staffId),
        onSayTurn: _sayTurn(roster),
      ),
    );
    if (seating == null || !mounted) return;
    await _create(
      {'table': table.id, 'guests': seating.guests, 'order_type': 'dine_in'},
      for_: seating.server,
      label: table.label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final small = compact(context);
    final now = DateTime.now();
    // Every check, and above them the to-go orders by stage: a chip narrows the list to its orders, the
    // one due first at the top. The row shows once there is a to-go order to sort.
    // While a check is being looked for, the row is the search box and the list is what the words find.
    final checks = _listed;
    final finding = _finding;
    final tabsOnly = !finding && _tabsOnly;
    final chip = finding || tabsOnly ? null : _chip;
    final counts = chipCounts(checks.map((row) => row.$1), now);
    // The bar's open tabs: Tabs stands first in the row while there is one, and lists them by name.
    final tabs = [
      for (final row in checks)
        if (row.$1.isTab && row.$1.isOpen) row,
    ];
    final listed = finding
        ? [
            for (final row in checks)
              if (checkMatches(row.$1, _find.text)) row,
          ]
        : tabsOnly
        ? tabsByName(tabs, (row) => row.$1)
        : chip == null
        ? checks
        : dueFirst(checks.where((row) => inChip(chip, row.$1, now)), (row) => row.$1);
    final sorts = chip != null || checks.any((row) => row.$1.isTakeout && row.$1.isOpen);
    final showsTabs = tabsOnly || tabs.isNotEmpty;
    // What the menu offers follows what the person signed in may do (docs/roles.md).
    final powers = widget.api.powers.value;
    final role = widget.session.staff?.role;
    final manages = alwaysRoles.contains(role); // a manager finds a check of any day
    final rush = _quotes?.rush;
    // The waitlist: its button stands in the bar wherever there is room, and on a phone while a party is
    // waiting or for whoever gives tables out; everybody else on a phone finds it in the menu.
    final wait = _wait;
    final waiting = wait?.waiting.length ?? 0;
    final waitInBar = wait != null && (!small || waiting > 0 || _roster.assigns(widget.session.staff?.staffId));
    final waitLevel = wait?.levelAt(widget.api.nowMs()) ?? TimerLevel.ok;
    // The booked tables of today still to sit down are counted on the same button, under the parties
    // waiting: whoever gives tables out sees both at a glance. A phone's menu says the count on its row.
    final toCome = _book?.toCome.length ?? 0;
    final bookLevel = _book?.levelAt(widget.api.nowMs()) ?? TimerLevel.ok;
    final more = <(String, IconData, VoidCallback)>[
      ('Sign out', Icons.logout, widget.session.signOut),
      if (wait != null && !waitInBar) ('Waitlist', Icons.groups_2_outlined, _waitlist),
      // The reservation book: in a phone's menu; where the bar has every button out it is one tap past the
      // waitlist's, which leads to it, so the bar keeps its room.
      if (small)
        (
          toCome == 0 ? 'Reservations' : 'Reservations · $toCome to come',
          Icons.event_available_outlined,
          _reservations,
        ),
      (
        _showClosed ? 'Hide closed' : 'Show closed',
        _showClosed ? Icons.visibility_off : Icons.visibility,
        () => setState(() {
          _showClosed = !_showClosed;
          _refresh();
        }),
      ),
      ('Orders ahead', Icons.event_note_outlined, _ahead),
      // where the hub says who takes deliveries out (docs/delivery.md)
      if (_roster.drivers.isNotEmpty) ('Deliveries', Icons.delivery_dining_outlined, _deliveries),
      if (_notesUp > 0) ('Notes', Icons.sticky_note_2_outlined, _notes),
      if (_contestsShown > 0) ('Contests', Icons.emoji_events_outlined, _contests),
      if (_clockOn) ('Time clock', Icons.punch_clock_outlined, _timeClock),
      ('Waste', Icons.delete_sweep_outlined, _waste),
      if (powers.holds(role, 'rush') && (_quotes?.takesRush ?? false))
        ('Kitchen rush', Icons.local_fire_department_outlined, _rush),
      // where the hub takes orders from the website: how they are doing, and the ones to look at
      if (manages && (_online?.isOn ?? false)) ('Online orders', Icons.language, _onlineOrders),
      if (powers.holds(role, 'reports')) ('Today', Icons.today_outlined, _today),
      if (powers.opensLocation(role)) ('Location', Icons.storefront_outlined, _location),
      if (powers.holds(role, 'menu'))
        (
          'Menu editor',
          Icons.edit_note,
          () => Navigator.of(context).push(
            PosPageRoute(
              builder: (_) => MenuEditorScreen(api: widget.api, settings: widget.settings),
            ),
          ),
        ),
      (
        'Display',
        Icons.text_fields,
        () => showDialog<void>(
          context: context,
          builder: (_) => DisplayDialog(session: widget.session),
        ),
      ),
      (
        'Settings',
        Icons.settings,
        () => Navigator.of(context).push(
          PosPageRoute(
            builder: (_) => SettingsScreen(
              settings: widget.settings,
              api: widget.api,
              relay: widget.relay,
              phone: widget.phone,
              camera: widget.camera,
              bell: widget.bell,
            ),
          ),
        ),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          small
              ? widget.session.staff?.name ?? 'Orders'
              : 'Orders · ${widget.session.staff?.name ?? ''} · ${widget.settings.device}',
        ),
        actions: [
          StatusIcon(api: widget.api, outbox: widget.outbox, phone: widget.phone),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Container(
              width: small ? 40 : 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(7), child: widget.camera.preview()),
            ),
          ),
          if (waitInBar)
            IconButton(
              key: const ValueKey('waitlist-open'),
              tooltip: [
                waiting == 0 ? 'Waitlist' : 'Waitlist: $waiting waiting',
                if (toCome > 0) bookedToComeWords(toCome),
              ].join(' · '),
              onPressed: _waitlist,
              icon: Badge(
                key: ValueKey('waitlist-badge:${waitLevel.name}'),
                isLabelVisible: waiting > 0,
                label: Text('$waiting'),
                backgroundColor: switch (waitLevel) {
                  TimerLevel.ok => scheme.primary,
                  TimerLevel.warn => posColors.timerWarn,
                  TimerLevel.late => posColors.timerLate,
                },
                textColor: switch (waitLevel) {
                  TimerLevel.ok => scheme.onPrimary,
                  TimerLevel.warn => posColors.timerWarnText,
                  TimerLevel.late => posColors.timerLateText,
                },
                child: toCome == 0
                    ? const Icon(Icons.groups_2_outlined)
                    : Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.groups_2_outlined),
                          // across the icon from the round badge, so the two numbers never meet, large type
                          // or not
                          Positioned(
                            left: -10,
                            bottom: -10,
                            child: BookedMark(
                              key: ValueKey('waitlist-booked:${bookLevel.name}'),
                              count: toCome,
                              level: bookLevel,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          IconButton(
            tooltip: _floor ? 'List of checks' : 'Floor map',
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(_floor ? Icons.list_alt_rounded : Icons.table_restaurant_rounded, key: ValueKey(_floor)),
            ),
            onPressed: () {
              setState(() {
                _floor = !_floor;
                _moving = null; // a table is moved on the map: leaving it leaves the move
              });
              _endSeating(); // and so is a tab seated there
            },
          ),
          if (small)
            // a phone: the rest go in one menu, so the title still fits
            PopupMenuButton<VoidCallback>(
              tooltip: 'More',
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                for (final (label, icon, action) in more)
                  PopupMenuItem(
                    value: action,
                    child: ListTile(leading: Icon(icon), title: Text(label), contentPadding: EdgeInsets.zero),
                  ),
              ],
            )
          else
            for (final (label, icon, action) in more) IconButton(tooltip: label, icon: Icon(icon), onPressed: action),
        ],
      ),
      body: Column(
        children: [
          CaptureBanner(api: widget.api, outbox: widget.outbox),
          if (manages && OnlineAlertStrip.shows(_online))
            OnlineAlertStrip(key: const ValueKey('online-alert'), status: _online!, onTap: _onlineOrders),
          if (rush != null && rush.runsAt(now)) RushStrip(key: const ValueKey('rush-strip'), rush: rush, onTap: _rush),
          // One row over the list: the way into the search and the to-go orders by stage; the search box
          // takes the whole of it while a check is being looked for.
          if (!_floor)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: finding
                  ? CheckSearchBar(
                      controller: _find,
                      focusNode: _findFocus,
                      onChanged: (_) => setState(() {}),
                      onClose: _stopFinding,
                      day: _findDay,
                      onPickDay: manages ? _pickFindDay : null,
                      onClearDay: _clearFindDay,
                    )
                  : Row(
                      children: [
                        FindCheckButton(
                          key: const ValueKey('find-open'),
                          wide: !sorts && !showsTabs,
                          onTap: _startFinding,
                        ),
                        if (sorts || showsTabs) ...[
                          const SizedBox(width: 6),
                          Expanded(
                            child: ToGoChips(
                              key: const ValueKey('to-go-chips'),
                              counts: counts,
                              picked: chip,
                              onPicked: (picked) => setState(() {
                                _chip = picked;
                                _tabsOnly = false;
                              }),
                              toGo: sorts,
                              tabs: showsTabs ? tabs.length : null,
                              tabsPicked: tabsOnly,
                              onTabs: (on) => setState(() {
                                _tabsOnly = on;
                                _chip = null;
                              }),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          if (_floor && _moving != null) MovingBar(table: _moving!, onCancel: () => setState(() => _moving = null)),
          if (_floor && _seating != null)
            MovingBar.words(
              'Seating ${_seating!.order.tabLabel}. Tap their table.',
              key: const ValueKey('seating-bar'),
              onCancel: _endSeating,
            ),
          if (_floor && _seatingParty != null)
            MovingBar.words(
              switch (_seatingParty!) {
                Booking(:final label, :final tableLabel) when tableLabel.isNotEmpty =>
                  'Seating $label. Table $tableLabel is held for them: tap it, or another.',
                final party => 'Seating ${party.label}. Tap their table.',
              },
              key: const ValueKey('seating-party-bar'),
              onCancel: _endSeating,
            ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _floor
                  ? FloorView(
                      key: _floorKey,
                      api: widget.api,
                      outbox: widget.outbox,
                      onTable: _onTable,
                      onTableHeld: _onTableHeld,
                      moving: _moving?.id,
                      me: _me,
                      mine: widget.session.prefs.myTables,
                      onMine: _setMine,
                    )
                  : listed.isEmpty && finding
                  ? Center(
                      key: const ValueKey('empty-find'),
                      child: Text(
                        _find.text.trim().isEmpty
                            ? 'No checks were opened ${_findDay == null ? 'in the last day' : 'that day'}.'
                            : 'No check matches.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : listed.isEmpty && tabsOnly
                  ? Center(
                      key: const ValueKey('empty-chip:tabs'),
                      child: Text('No tabs are open.', style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : listed.isEmpty && chip != null
                  ? Center(
                      key: ValueKey('empty-chip:${chip.name}'),
                      child: Text(chip.none, style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : listed.isEmpty
                  ? Center(
                      key: const ValueKey('empty-orders'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(color: scheme.surfaceContainerLow, shape: BoxShape.circle),
                            child: Icon(Icons.receipt_long_outlined, size: 36, color: scheme.outline),
                          ),
                          const SizedBox(height: 14),
                          const Text('No open orders. Tap + to start one.'),
                        ],
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey('orders-list'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                      itemCount: listed.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final (order, queued) = listed[i];
                        final lines = order.activeLines;
                        final items = lines.fold<int>(0, (n, l) => n + l.qty);
                        final isTakeout = order.isTakeout;
                        final isTab = order.isTab;
                        final stage = order.stage;
                        // An order for later is marked as its time to start cooking nears, and when that
                        // time has come and nobody sent it.
                        final promisedAt = order.promisedAt;
                        // brought to the customer (docs/delivery.md): the row says so and where to, and
                        // its last step is that it was delivered
                        final delivery = order.isDelivery;
                        final address = delivery ? order.event.address : '';
                        final later = !isTakeout || !order.isOpen || stage != 'new'
                            ? LaterStage.none
                            : laterStage(
                                forLater: order.forLater,
                                promisedAt: promisedAt,
                                quotedMinutes: order.quotedMinutes,
                                sent: order.isFired,
                                now: now,
                              );
                        // Counter mode: the number the hub gave it, the name, the channel, when it is for,
                        // whether it is paid, and the next step (Ready texts the customer; Picked up closes).
                        // An order sent ahead for a later time has no step until its ticket prints: the
                        // kitchen has seen nothing of it, and a slip of the thumb would text the customer.
                        final Widget? step =
                            !isTakeout || !order.isOpen || !order.isFired || waitsForItsTime(order, now)
                            ? null
                            : stage == 'new'
                            ? FilledButton.tonal(
                                key: ValueKey('ready-${order.orderId}'),
                                onPressed: () => _setStage(order, 'ready'),
                                child: const Text('Ready'),
                              )
                            // a delivery leaves with a driver before it is delivered, where the hub
                            // says who delivers; a hub older than drivers goes from ready to delivered
                            : stage == 'ready' && delivery && _roster.drivers.isNotEmpty
                            ? FilledButton.tonal(
                                key: ValueKey('out-${order.orderId}'),
                                onPressed: () => _sendOut(order),
                                child: const Text('Out'),
                              )
                            : stage == 'ready' || order.isOut
                            ? FilledButton.tonal(
                                key: ValueKey('picked-up-${order.orderId}'),
                                onPressed: () => _setStage(order, 'picked_up'),
                                child: Text(delivery ? 'Delivered' : 'Picked up'),
                              )
                            : null;
                        return PressableScale(
                          pressedScale: 0.985,
                          child: Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              leading: _marked(
                                CircleAvatar(
                                  backgroundColor: order.isFired ? posColors.fired : scheme.primaryContainer,
                                  foregroundColor: order.isFired ? posColors.firedText : scheme.onPrimaryContainer,
                                  child: isTab
                                      // a tab has no table and no number: a glass, and the name beside it
                                      ? const Icon(Icons.local_bar, size: 20, semanticLabel: 'Bar tab')
                                      : Text(
                                          isTakeout ? '${order.orderNo ?? '…'}' : order.table,
                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                        ),
                                ),
                                order,
                                scheme,
                              ),
                              title: Text(
                                isTakeout
                                    ? [
                                        order.customerName.isEmpty ? 'To go' : order.customerName,
                                        if (order.channel.isNotEmpty) channelLabel(order.channel).toLowerCase(),
                                        if (delivery && order.channel != 'delivery') 'delivery',
                                      ].join(' · ')
                                    : isTab
                                    ? [
                                        if (order.customerName.trim().isNotEmpty) order.customerName.trim(),
                                        'tab',
                                      ].join(' · ')
                                    // whose table it is, where the check or the host says: "Table A7 · Chen"
                                    : ['Table ${order.table}', ?_whose(order)].join(' · '),
                                style: theme.textTheme.titleMedium,
                              ),
                              subtitle: Wrap(
                                spacing: 6,
                                runSpacing: 2,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (promisedAt != null && (later == LaterStage.soon || later == LaterStage.unsent))
                                    LaterMark(
                                      key: ValueKey('later-${order.orderId}'),
                                      stage: later,
                                      sent: order.isFired,
                                      starts: startsAt(promisedAt, order.quotedMinutes),
                                      warn: (posColors.timerWarn, posColors.timerWarnText),
                                      late: (posColors.timerLate, posColors.timerLateText),
                                    ),
                                  Text(
                                    [
                                      // Looked for, a check says when it was opened and whose it is.
                                      if (finding && order.openedMs != null) _opened(order.openedMs!, now),
                                      '$items items',
                                      order.status,
                                      if (order.isFired) 'fired',
                                      // a time the customer named says its day too, when that is not today
                                      if (isTakeout && promisedAt != null)
                                        order.forLater
                                            ? 'for ${whenFor(promisedAt, now)}'
                                            : '${delivery ? 'there' : 'ready'} ${clockTime(promisedAt)}',
                                      // "$45.01 due" once a deposit was taken: not the whole of it
                                      if (isTakeout) moneyWords(order),
                                      if (isTakeout && stageLabel(stage, delivery: delivery).isNotEmpty)
                                        stageLabel(stage, delivery: delivery).toUpperCase(),
                                      // who has it, and since when
                                      if (order.isOut && order.driver.isNotEmpty)
                                        [
                                          order.driver,
                                          if (order.outAt != null) 'since ${clockTime(order.outAt!)}',
                                        ].join(' '),
                                      if (address.isNotEmpty) address,
                                      if (finding && (order.fields['server']?.toString() ?? '').isNotEmpty)
                                        order.fields['server'].toString(),
                                      if (queued) 'waiting to send',
                                    ].join(' · '),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: queued ? scheme.error : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: step ?? const Icon(Icons.chevron_right),
                              onTap: () => _open(order.orderId),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      // Two ways to start a check with no table: a bar tab and a to-go order. With a caller on the phone, or
      // just off it, To go names the caller (the order starts with the number), and on a phone Tab makes
      // room for that by being its glass alone. While a tab is being seated the next tap is a table's, so
      // neither shows. On a phone's floor map the two stand above the words under the map (what the colours
      // of a table say), where the map leaves room anyway.
      floatingActionButton: _seating != null || _seatingParty != null
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: small && _floor ? 44 : 0),
              // The narrowest phone with large type has no room for the two side by side while To go names a
              // caller: they are drawn a little smaller then, and never run off the screen.
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.max(0, MediaQuery.sizeOf(context).width - 32)),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (small && (widget.phone?.callerForOrder?.formatted.isNotEmpty ?? false))
                        FloatingActionButton(
                          key: const ValueKey('new-tab'),
                          heroTag: 'new-tab',
                          tooltip: 'Open a tab',
                          onPressed: _newTab,
                          child: const Icon(Icons.local_bar_outlined),
                        )
                      else
                        FloatingActionButton.extended(
                          key: const ValueKey('new-tab'),
                          heroTag: 'new-tab',
                          tooltip: 'Open a tab',
                          onPressed: _newTab,
                          icon: const Icon(Icons.local_bar_outlined),
                          label: const Text('Tab'),
                        ),
                      const SizedBox(width: 10),
                      FloatingActionButton.extended(
                        key: const ValueKey('to-go'),
                        heroTag: 'to-go',
                        onPressed: () => _newOrder(),
                        icon: const Icon(Icons.shopping_bag_outlined),
                        label: Text(switch (widget.phone?.callerForOrder) {
                          null => 'To go',
                          final caller => caller.formatted.isEmpty ? 'To go' : 'To go · ${caller.formatted}',
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// A row's number in the list of checks, with a small globe on its corner for an order that came from the
/// website by itself (docs/online-orders.md, "On the screens"): found at a glance, and it takes no room
/// from the name or the line under it on a phone. Any other order's number is as it was. An order from the
/// account for testing has its globe white on black, as its tickets print TEST ORDER ("Several accounts").
Widget _marked(Widget number, Order order, ColorScheme scheme) {
  final online = order.online;
  if (online == null) return number;
  return Stack(
    clipBehavior: Clip.none,
    children: [
      number,
      Positioned(
        right: -5,
        bottom: -5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: online.test ? scheme.inverseSurface : scheme.surface,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(1),
            child: Icon(
              Icons.language,
              key: ValueKey('online-${order.orderId}'),
              size: 16,
              color: online.test ? scheme.onInverseSurface : scheme.onSurfaceVariant,
              semanticLabel: online.test ? '$testOrder, ${fromWhere(online)}' : fromWhere(online),
            ),
          ),
        ),
      ),
    ],
  );
}

/// When a check was opened, for the list a check is looked for in: the time, and the day before it when
/// that is not today ("19:42", "yesterday 19:42", "14 Nov 19:42").
String _opened(int ms, DateTime now) {
  final day = dayLabel(ms, now);
  return day == 'today' ? clockTime(ms) : '$day ${clockTime(ms)}';
}

/// Whose table a check is, for its row in the list: the name the check carries (a tab that sat down) and
/// the parties the host seated on it, the first two by name and the rest as a count ("Chen, Wu +1"). Null
/// for a walk-in's check, whose row says the table alone.
String? _whose(Order order) {
  final names = order.tableNames;
  if (names.isEmpty) return null;
  return [names.take(2).join(', '), if (names.length > 2) '+${names.length - 2}'].join(' ');
}

/// The first tap of a to-go order: name and phone, the channel, the language for texts, and whether it is
/// for now (the channel's quote) or a later time today, tomorrow or any day off a calendar. A catering
/// order (docs/catering.md) always names its day and time, and says what its event needs: the guests,
/// pickup or delivery, the address and a note. For a [caller] the number, the phone
/// channel and the caller-ID name are filled in; all of it stays editable.
///
/// The number in the box is looked up as a customer (as the form opens for a caller, and as a number is
/// typed): the name from their orders fills the name box unless one was typed, a line says how often they
/// ordered, the note kept about them can be read and changed, and each of their latest orders has a
/// **Same again** button that starts the new order with those dishes. With no hub answering, or one older
/// than customers, none of that shows and the form is what it was.
///
/// Under the channels the form asks **Pickup** or **Delivery** (docs/delivery.md). A delivery asks where to
/// and has a note for the driver; the address of the customer's last delivery is already in the box, and
/// the order cannot start without one. It is quoted the minutes set for Delivery. (A catering order asks
/// the same among what its event needs. A hub older than deliveries is not asked: it would print the order
/// as one that is picked up.)
///
/// Somebody who calls may want a table and not food. While the order is by phone the form has **Book a
/// table** beside its title, which pops a [_BookForCaller] with the name and the number in the form; and a
/// number that has tables booked, today or ahead, lists them, each with **Open**, which pops that
/// [Booking]. Otherwise it pops the [TakeoutRequest] to start, or nothing.
class _TakeoutDialog extends StatefulWidget {
  const _TakeoutDialog({required this.quotes, required this.api, this.caller, this.by, this.underCall = false});
  final Quotes quotes;
  final PosApi api;
  final Caller? caller;

  /// A call is on at this terminal: its strip lies across the top of the screen, and the form starts under
  /// it, so the title and Book a table are not behind it.
  final bool underCall;

  /// Who is taking the order: kept with a note they write about the customer.
  final String? by;

  @override
  State<_TakeoutDialog> createState() => _TakeoutDialogState();
}

class _TakeoutDialogState extends State<_TakeoutDialog> {
  late final _name = TextEditingController(text: widget.caller?.displayName ?? '');
  late final _phone = TextEditingController(text: widget.caller?.formatted ?? '');
  final _note = TextEditingController();
  late String _channel = widget.caller == null ? 'counter' : 'phone';
  String _locale = 'en';
  bool _later = false;
  DateTime _day = DateTime.now(); // the day a later order is for: its date alone counts
  TimeOfDay? _time;

  // how the order leaves, and where to; what a catering order's event needs, and any other delivery's
  // note for the driver
  final _guests = TextEditingController();
  final _address = TextEditingController();
  final _eventNote = TextEditingController();
  final _driverNote = TextEditingController();
  String _handover = 'pickup';
  DeliveryFees? _fees; // what a delivery costs here; null until the hub answers, and where it charges none
  String? _fee; // the fee picked for this one (a FeePick); null while nobody picked
  final _asker = DistanceAsker(); // how far the address is, where the hub looks that up
  bool _feeByHand = false; // somebody tapped a price: from then on the map says how far and picks nothing
  String _addressFilled = ''; // the address the form itself put in the box: the customer's last delivery
  String _driverNoteFilled = ''; // and what was said for the driver then

  CustomerCard? _customer; // who the hub says is at the number in the box; null: not asked, or no answer
  CallerTables? _tables; // the tables that number has booked, today and ahead; null: not asked, or no answer
  String _filled = ''; // the name the form itself put in the box: a customer's replaces it, a typed one stays
  String _noteWas = ''; // the note as the hub keeps it
  String? _noteProblem;
  bool _keeping = false;
  Timer? _typing;
  int _asked = 0;
  String? _lookedUp; // the digits the hub was last asked about

  @override
  void initState() {
    super.initState();
    _filled = _name.text.trim();
    unawaited(_lookUp());
    unawaited(_readFees());
  }

  /// What a delivery costs here, for the buttons under the address. Nothing answers and nothing was saved:
  /// the form asks no fee, and the order is taken as before.
  Future<void> _readFees() async {
    try {
      final fees = await widget.api.deliveryFees();
      if (!mounted || fees == null) return;
      setState(() => _fees = fees);
      // with the number in the box, so the hub can read the distance off the customer's own earlier order
      _asker.source = fees.looksUp
          ? (address, {fresh = false, now = false}) =>
                widget.api.deliveryDistance(address, phone: _phone.text, fresh: fresh, now: now)
          : null;
      unawaited(_askDistance()); // an address that was there before the prices were
    } on ApiException {
      // no fee is asked
    }
  }

  /// Asks the hub how far the address is, where it looks that up (docs/delivery.md, "Looking the distance
  /// up"), and picks the band it falls in unless somebody picked by hand. Once per address, unless [again];
  /// [fresh] has the hub ask its map service whatever the customer's earlier order says.
  ///
  /// Where live traffic is on, a delivery for now is also told how long the drive is at this minute
  /// ("Live traffic"), and the form promises by it. An order for later is not asked about: the roads now
  /// say nothing of then.
  Future<void> _askDistance({bool again = false, bool fresh = false, bool chosen = false}) async {
    if (!mounted || _handover != 'delivery' || !_asker.can) return;
    // an address chosen off the list is another place to go: a price tapped for the one before it does
    // not stand for it (Mike, 2026-11-26: when an address is selected, the fee for its distance is)
    if (chosen) _feeByHand = false;
    final now = (_fees?.live ?? false) && _delivery && !_named;
    final found = await _asker.ask(_address.text, again: again, fresh: fresh, now: now);
    if (!mounted) return;
    // the time promised may go by the answer too
    setState(() {
      // an address further than every price asks for the custom fee, where the location has one
      final pick = _feeByHand ? null : FeePick.found(found, _fees, _fee);
      if (pick != null) _fee = pick;
    });
  }

  /// Something was typed on the form: what the map said of another address is gone.
  void _addressTyped() => setState(() => _asker.typed(_address.text));

  /// What the letters typed in the address could become, asked of the hub with the number in the box: the
  /// customer's own earlier deliveries lead the list (docs/delivery.md, "A list of addresses while typing").
  Future<AddressSuggestions?> _addresses(String typed) => widget.api.suggestAddresses(typed, phone: _phone.text);

  void _leaves(String way) {
    setState(() => _handover = way);
    unawaited(_askDistance());
  }

  void _pickFee(String pick) => setState(() {
    if (FeePick.byHand(_fee, pick)) _feeByHand = true;
    _fee = pick;
  });

  @override
  void dispose() {
    _typing?.cancel();
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    _guests.dispose();
    _address.dispose();
    _eventNote.dispose();
    _driverNote.dispose();
    _asker.dispose();
    super.dispose();
  }

  /// Asks once the typing pauses, not at every digit.
  void _phoneChanged(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 400), () => unawaited(_lookUp()));
  }

  Future<void> _lookUp() async {
    final digits = phoneDigits(_phone.text);
    if (digits == _lookedUp) return;
    _lookedUp = digits;
    final asked = ++_asked;
    // the tables the number has booked are asked for beside the customer: neither waits for the other
    unawaited(
      widget.api.callerTables(digits).then((tables) {
        if (mounted && asked == _asked) setState(() => _tables = tables);
      }),
    );
    final found = await widget.api.customer(digits);
    if (!mounted || asked != _asked) return; // the number changed while the hub was asked
    setState(() {
      final untouched = _noteText == _noteWas;
      _customer = found;
      final name = found?.name ?? '';
      if (name.isNotEmpty && _name.text.trim() == _filled) {
        _name.text = name;
        _filled = name;
      }
      _noteWas = found?.note ?? '';
      _noteProblem = null;
      if (untouched) _note.text = _noteWas;
      // Where their last delivery went, and what was said for the driver. A box nobody typed in takes
      // them, and loses them again when the number becomes somebody else's: one customer's address never
      // goes on another's order.
      final address = found?.address ?? '';
      if (oneLine(_address.text) == _addressFilled) {
        _address.text = address;
        _addressFilled = address;
      }
      final driverNote = found?.addressNote ?? '';
      if (oneLine(_driverNote.text) == _driverNoteFilled) {
        _driverNote.text = driverNote;
        _driverNoteFilled = driverNote;
      }
      _asker.typed(_address.text);
    });
    unawaited(_askDistance()); // the address of their last delivery, when this one is a delivery too
  }

  /// The note as the hub would keep it: on one line.
  String get _noteText => _note.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  bool get _noteChanged => _customer != null && _noteText != _noteWas;

  /// The tick in the note box: keeps the note now, so it is not lost if no order is started.
  Future<void> _keepNote() async {
    final customer = _customer;
    if (customer == null || _keeping) return;
    setState(() => _keeping = true);
    try {
      final kept = await widget.api.saveCustomerNote(customer.phone, _noteText, by: widget.by);
      if (!mounted) return;
      setState(() {
        _noteWas = kept;
        _note.text = kept;
        _noteProblem = null;
      });
    } on ApiException {
      if (mounted) setState(() => _noteProblem = 'Not saved. Try again.');
    } finally {
      if (mounted) setState(() => _keeping = false);
    }
  }

  bool get _catering => _channel == 'catering';

  /// Brought to the customer, and no catering order: it needs its address, and is quoted as a delivery.
  bool get _delivery => !_catering && widget.quotes.delivers && _handover == 'delivery';

  /// A delivery with nowhere to go yet.
  bool get _nowhere => _delivery && oneLine(_address.text).isEmpty;

  /// A delivery on the custom fee with no amount typed yet (a catering order's too: what would it be sent as).
  bool get _untyped => (_delivery || _catering) && _handover == 'delivery' && FeePick.unfinished(_fee);

  /// A delivery nobody said the fee of, where the location charges one: "No fee" is a pick, and a custom
  /// fee is one once its amount is typed.
  bool get _unpriced => (_delivery && (_fees?.asks ?? false) && _fee == null) || _untyped;

  /// The customer names the time: the switch says so, and a catering order always does.
  bool get _named => _later || _catering;

  /// The drive as the roads are right now to the address on the form, where a delivery for now is
  /// promised by it ("Live traffic"); null where it is not, and while nobody said.
  DriveNow? get _drive => _delivery && !_named ? _asker.driveFor(_address.text) : null;

  DateTime? get _promised {
    final time = _time;
    if (!_named || time == null) return null;
    return WhenPicker.at(_day, time);
  }

  bool get _ready => _name.text.trim().isNotEmpty && (!_named || _time != null) && !_nowhere && !_unpriced;

  /// Start, or Same again on the past order [again].
  void _start({String? again}) => Navigator.of(context).pop(
    TakeoutRequest(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      channel: _channel,
      locale: _locale,
      promisedAt: _promised,
      again: again,
      note: _noteChanged ? _noteText : null,
      event: _catering
          ? EventFields.read(guests: _guests, address: _address, note: _eventNote, handover: _handover)
          : _delivery
          ? EventFields.read(address: _address, note: _driverNote, handover: _handover)
          : null,
      // a fee is a delivery's alone, and a catering order's may be said later
      fee: (_delivery || _catering) && _handover == 'delivery' ? _fee : null,
      measured: _asker.measuredFor(_address.text),
      driveNow: _drive,
    ),
  );

  /// What is known of the customer at the number: how often they ordered, the tags a manager put on them
  /// in the guest list, the note, their latest orders.
  Widget _customerCard(ThemeData theme, CustomerCard customer) {
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final faint = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      key: const ValueKey('customer-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(customer.summary(now), key: const ValueKey('customer-summary'), style: faint),
        // what they have earned (docs/points.md): said only where the owner set a rate
        if (customer.points case final points?)
          Text(
            points > 0 ? 'They have ${pointsWords(points)}' : 'No points yet',
            key: const ValueKey('customer-points'),
            style: faint,
          ),
        // read here, written in the guest list: who they are to the house, before the first word is said
        if (customer.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4), // clear of the note's label below
            child: Wrap(
              key: const ValueKey('customer-tags'),
              spacing: 6,
              runSpacing: 4,
              children: [for (final tag in customer.tags) GuestTagMark(tag)],
            ),
          ),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('customer-note'),
          controller: _note,
          maxLength: customerNoteMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Note about this customer',
            prefixIcon: const Icon(Icons.sticky_note_2_outlined),
            counterText: '',
            errorText: _noteProblem,
            suffixIcon: _noteChanged
                ? IconButton(
                    key: const ValueKey('customer-note-save'),
                    tooltip: 'Save the note now',
                    icon: const Icon(Icons.check),
                    onPressed: _keeping ? null : _keepNote,
                  )
                : null,
          ),
          onChanged: (_) => setState(() => _noteProblem = null),
        ),
        // when and what it came to beside the button, the dishes under them across the whole width: on a
        // phone the form is narrow, and the dishes are what the customer is asked about
        for (final past in customer.recent)
          Padding(
            key: ValueKey('past:${past.orderId}'),
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (past.openedMs != null) _capital(dayLabel(past.openedMs!, now)),
                          if (past.total.isNotEmpty) '\$${past.total}',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(fontFeatures: PosTheme.tabular),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      key: ValueKey('again:${past.orderId}'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: _ready ? () => _start(again: past.orderId) : null,
                      child: const Text('Same again'),
                    ),
                  ],
                ),
                Text(past.dishes, maxLines: 2, overflow: TextOverflow.ellipsis, style: faint),
              ],
            ),
          ),
      ],
    );
  }

  /// The tables the number has booked, each a way to it in the book: the call may be about one. When it is
  /// for, over what it is; whose it is too, when that is not the name in the box above.
  Widget _tablesCard(ThemeData theme, CallerTables tables) {
    final scheme = theme.colorScheme;
    final ink = scheme.onSecondaryContainer;
    return Column(
      key: const ValueKey('caller-tables'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final booking in tables.booked)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('caller-table-open:${booking.id}'),
                onTap: () => Navigator.of(context).pop(booking),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded, size: 20, color: ink),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              callerTableWhen(booking, tables.today),
                              key: ValueKey('caller-table:${booking.id}'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: ink,
                                fontWeight: FontWeight.w700,
                                fontFeatures: PosTheme.tabular,
                              ),
                            ),
                            Text(
                              callerTableWhat(booking, asName: _name.text),
                              key: ValueKey('caller-table-what:${booking.id}'),
                              style: theme.textTheme.bodySmall?.copyWith(color: ink),
                            ),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: 'Open in the reservation book',
                        child: Icon(Icons.chevron_right, color: ink),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _capital(String word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final drive = _drive;
    final minutes = widget.quotes.minutesFor(_channel, at: now, promised: _promised, delivery: _delivery, drive: drive);
    final rush = widget.quotes.rushAt(now, promised: _promised);
    final customer = _customer;
    final tables = _tables;
    // Somebody on the phone may want a table and not food: the way to the reservation form is beside the
    // title, where it costs the form no height. By its name where the form is wide enough for both, and as
    // its calendar alone on a phone. (A dialog sizes itself to what is in it: the screen says how wide.)
    final media = MediaQuery.of(context);
    final named = media.size.width >= 400 && media.textScaler.scale(1) <= 1.15;
    void book() => Navigator.of(context).pop(_BookForCaller(_name.text.trim(), _phone.text.trim()));
    return AlertDialog(
      insetPadding: EdgeInsets.fromLTRB(40, widget.underCall ? callStripRoom : 24, 40, 24),
      title: Row(
        children: [
          const Expanded(child: Text('To-go order', maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (_channel == 'phone' && named)
            TextButton.icon(
              key: const ValueKey('takeout-book'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: book,
              icon: const Icon(Icons.event_available_outlined, size: 18),
              label: const Text('Book a table'),
            )
          else if (_channel == 'phone')
            IconButton.filledTonal(
              key: const ValueKey('takeout-book'),
              visualDensity: VisualDensity.compact,
              tooltip: 'Book a table',
              onPressed: book,
              icon: const Icon(Icons.event_available_outlined),
            ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('takeout-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(Icons.person_outline)),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('takeout-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  // nobody is texted to come for a delivery: the number is for the driver at the door
                  labelText: _delivery ? 'Phone (for the driver to call)' : 'Phone (for the ready text)',
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
                onChanged: _phoneChanged,
              ),
              if (tables != null && tables.booked.isNotEmpty) _tablesCard(theme, tables),
              if (customer != null) _customerCard(theme, customer),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in handChannels)
                    ChoiceChip(
                      key: ValueKey('channel:$c'),
                      label: Text(channelLabel(c)),
                      selected: _channel == c,
                      onSelected: (_) {
                        setState(() => _channel = c);
                        unawaited(_askDistance()); // a delivery that is now for now is told the drive
                      },
                    ),
                  const SizedBox(width: 8),
                  for (final (code, label) in const [('en', 'English'), ('zh', '中文')])
                    ChoiceChip(
                      key: ValueKey('locale:$code'),
                      label: Text(label),
                      selected: _locale == code,
                      onSelected: (_) => setState(() => _locale = code),
                    ),
                ],
              ),
              // How it leaves, asked before the time: a delivery is quoted longer. (A catering order says
              // it among what its event needs, under its time.)
              if (!_catering && widget.quotes.delivers) ...[
                const SizedBox(height: 8),
                EventFields(
                  address: _address,
                  note: _driverNote,
                  handover: _handover,
                  onHandover: _leaves,
                  onChanged: _addressTyped,
                  fees: _fees,
                  fee: _fee,
                  onFee: _pickFee,
                  asker: _asker,
                  onAddressDone: _askDistance,
                  onAddressChosen: () => _askDistance(chosen: true),
                  onLookUp: ({fresh = false}) => _askDistance(again: true, fresh: fresh),
                  addresses: _addresses,
                  wholeAddress: widget.api.wholeAddress,
                ),
                if (_nowhere)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Type the address it goes to.',
                      key: const ValueKey('address-needed'),
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                else if (_unpriced)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _untyped ? 'Type the delivery fee.' : 'Pick the delivery fee.',
                      key: const ValueKey('fee-needed'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              // A catering order is always for a time the customer names: the switch has nothing to ask.
              if (_catering)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    key: const ValueKey('takeout-quote'),
                    'The kitchen gets its ticket $minutes min before its time.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              else
                SwitchListTile(
                  key: const ValueKey('takeout-later'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('For later'),
                  subtitle: Text(
                    key: const ValueKey('takeout-quote'),
                    _later
                        ? 'Prints ahead of its time by the quote${rush > 0 ? ' ($minutes min tonight)' : ''}'
                        : '${_delivery ? 'There' : 'Ready'} in about $minutes min'
                              '${drive != null ? ', with traffic' : ''}'
                              '${rush > 0 ? ' (busy kitchen: +$rush)' : ''}',
                  ),
                  value: _later,
                  onChanged: (on) {
                    setState(() => _later = on);
                    unawaited(_askDistance()); // one that is for now after all is told the drive
                  },
                ),
              if (_named)
                WhenPicker(
                  day: _day,
                  time: _time,
                  onDay: (day) => setState(() => _day = day),
                  onTime: (time) => setState(() => _time = time),
                ),
              if (_named && _time == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Pick the time it is for.', style: theme.textTheme.bodySmall),
                ),
              if (_catering) ...[
                const SizedBox(height: 12),
                EventFields(
                  guests: _guests,
                  address: _address,
                  note: _eventNote,
                  handover: _handover,
                  onHandover: _leaves,
                  onChanged: _addressTyped,
                  fees: _fees,
                  fee: _fee,
                  onFee: _pickFee,
                  asker: _asker,
                  onAddressDone: _askDistance,
                  onAddressChosen: () => _askDistance(chosen: true),
                  onLookUp: ({fresh = false}) => _askDistance(again: true, fresh: fresh),
                  addresses: _addresses,
                  wholeAddress: widget.api.wholeAddress,
                ),
                // its fee may be said later, but not half said
                if (_untyped)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Type the delivery fee.',
                      key: const ValueKey('fee-needed'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('takeout-start'),
          onPressed: _ready ? _start : null,
          child: const Text('Start'),
        ),
      ],
    );
  }
}

/// What the to-go form was left with when the customer wants a table and not food: the name and the number
/// it had, for the reservation form.
class _BookForCaller {
  const _BookForCaller(this.name, this.phone);

  final String name;
  final String phone;
}

/// Seats a party: how many guests and, for a host or manager, whose table it is. A server sees only the
/// guests: the table is theirs by opening it.
class _GuestsDialog extends StatefulWidget {
  const _GuestsDialog({
    required this.table,
    required this.plan,
    this.servers = const [],
    this.me,
    this.title,
    this.guests,
    this.onSayTurn,
  });
  final TableSpot table;
  final FloorPlan plan;

  /// How whoever seats the party says who is in tonight's turn for a table; null for somebody who gives no
  /// tables out. The turn itself comes with the [plan].
  final SayTurn? onSayTurn;

  /// How many the party is, when that is known already (a party off the waitlist); the table's seats when not.
  final int? guests;

  /// What the dialog is headed with when it is not a party walking in ("Seat Linda's tab at A5").
  final String? title;

  /// The people the table can be given to; none when whoever seats it takes it.
  final List<StaffMember> servers;

  /// Who is seating the party, as the staff list has them.
  final StaffMember? me;

  @override
  State<_GuestsDialog> createState() => _GuestsDialogState();
}

class _GuestsDialogState extends State<_GuestsDialog> {
  late int _guests = widget.guests ?? (widget.table.kind == 'counter' ? 1 : widget.table.seats);
  // A manager who serves starts on their own name; a host has to say whose table it is.
  late StaffMember? _server = widget.servers.where((s) => s.staffId == widget.me?.staffId).firstOrNull;
  // Tonight's turn for a table as the floor had it, and then as the hub answers a host who changes it here.
  late List<String> _turn = widget.plan.turn ?? const [];

  void _editTurn(SayTurn say) {
    showDialog<void>(
      context: context,
      builder: (_) => TurnDialog(
        servers: widget.servers,
        turn: _turn,
        onSay: say,
        onChanged: (turn) {
          if (mounted) setState(() => _turn = turn);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sayTurn = widget.plan.turn == null ? null : widget.onSayTurn; // a hub older than the turn keeps none
    return AlertDialog(
      title: Text(widget.title ?? 'Seat ${widget.table.label}'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _guests > 1 ? () => setState(() => _guests--) : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '$_guests guests',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: theme.textTheme.titleLarge?.copyWith(fontFeatures: PosTheme.tabular),
                      ),
                    ),
                  ),
                  IconButton(onPressed: () => setState(() => _guests++), icon: const Icon(Icons.add)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: [
                for (final preset in const [1, 2, 4, 6, 8])
                  ActionChip(
                    label: Text('$preset'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: _guests == preset ? scheme.primaryContainer : null,
                    onPressed: () => setState(() => _guests = preset),
                  ),
              ],
            ),
            if (widget.servers.isNotEmpty) ...[
              SizedBox(height: sayTurn == null ? 16 : 8),
              Row(
                children: [
                  Expanded(
                    child: Text('Server', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  if (sayTurn != null)
                    TextButton(
                      key: const ValueKey('turn-edit'),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => _editTurn(sayTurn),
                      child: const Text("Tonight's turn"),
                    ),
                ],
              ),
              SizedBox(height: sayTurn == null ? 8 : 0),
              Align(
                alignment: Alignment.centerLeft,
                child: ServerPicker(
                  servers: widget.servers,
                  plan: widget.plan,
                  picked: _server,
                  turn: _turn,
                  onPicked: (server) => setState(() => _server = server),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('seat'),
          // a host has to say whose table it is before the party is sat
          onPressed: widget.servers.isNotEmpty && _server == null
              ? null
              : () => Navigator.of(context).pop(Seating(_guests, widget.servers.isEmpty ? null : _server)),
          child: const Text('Seat'),
        ),
      ],
    );
  }
}
