import 'package:flutter/material.dart';

import '../api.dart';
import '../bag.dart';
import '../camera.dart';
import '../coursing.dart';
import '../desk_phone.dart';
import '../faces.dart';
import '../menu.dart';
import '../printers.dart';
import '../table_timers.dart';
import '../tags.dart';
import '../takeout.dart';
import '../timeclock.dart';
import '../voids.dart';
import 'adjustments_screen.dart';
import 'bag_question_dialog.dart';
import 'bill_dialog.dart';
import 'day_report_screen.dart';
import 'dishes_screen.dart';
import 'eighty_six_board.dart';
import 'face_enroll_dialog.dart';
import 'guests_screen.dart';
import 'logbook_screen.dart';
import 'printers_screen.dart';
import 'quotes_dialog.dart';
import 'sales_screen.dart';
import 'shift_notes_screen.dart';
import 'table_timers_dialog.dart';
import 'tag_enroll_dialog.dart';
import 'theme.dart';
import 'ticket_skips_dialog.dart';
import 'time_clock_screen.dart';
import 'void_rules_dialog.dart';

/// What a manager sets for the whole location, for every terminal: whether dishes are coursed, the courses
/// by name in kitchen order (as many as the kitchen serves) and where a new dish goes, the quote times,
/// the countdown on each table of the floor map, what voiding a sent dish takes (a manager's PIN or not, and
/// the reasons to pick from), the kitchen printers (on their own screen) and what their tickets say about
/// each other ("Ticket 2 of 3", "Also at: Wok 2"), which screen each desk phone is
/// linked to, face sign-in with each staff member's enrollment and tag, the hands-free switching between
/// people, and the time clock: whether the location uses it and how it counts the hours. The hub keeps them;
/// a terminal reads them when it opens an order. The report of voids and comps and the hours of the time
/// clock open from here too. Behind the manager PIN.
class LocationSettingsScreen extends StatefulWidget {
  const LocationSettingsScreen({
    super.key,
    required this.api,
    required this.token,
    this.device,
    this.camera,
    this.tags,
  });

  final PosApi api;
  final String token;

  /// This terminal's device name: first in the list of screens a desk phone can be linked to.
  final String? device;

  /// This terminal's camera, which a face enrollment looks through; without one, enroll from another screen.
  final EventCamera? camera;

  /// This terminal's tag reader, which a tag enrollment listens to; without one, the tag's id is typed.
  final TagReader? tags;

  @override
  State<LocationSettingsScreen> createState() => _LocationSettingsScreenState();
}

/// One course as the screen edits it: its id once the hub has it, a key for the row either way.
class _Row {
  _Row(this.key, {this.id, required String name}) : controller = TextEditingController(text: name);
  final String key;
  final String? id;
  final TextEditingController controller;
  String get name => controller.text.trim();
}

/// One desk phone as the screen edits it: its extension and the device it is linked to, each picked from a
/// list or, after "Other", typed.
class _PhoneRow {
  _PhoneRow(this.key, {required String extension, required String device})
    : extension = TextEditingController(text: extension),
      device = TextEditingController(text: device);
  final String key;
  final TextEditingController extension;
  final TextEditingController device;
  bool extensionTyped = false;
  bool deviceTyped = false;
  final FocusNode extensionFocus = FocusNode();
  final FocusNode deviceFocus = FocusNode();

  DeskPhoneLink get link => DeskPhoneLink(extension: extension.text.trim(), device: device.text.trim());

  void dispose() {
    extension.dispose();
    device.dispose();
    extensionFocus.dispose();
    deviceFocus.dispose();
  }
}

class _LocationSettingsScreenState extends State<LocationSettingsScreen> {
  Coursing? _coursing;
  Quotes? _quotes;
  String? _loadError;
  bool _enabled = true;
  List<_Row> _rows = [];
  String? _defaultKey;
  int _added = 0;
  String? _message;
  bool _busy = false;
  List<_PhoneRow> _phones = [];
  int _phonesAdded = 0;
  String? _phonesMessage;
  bool _phonesBusy = false;
  Map<String, dynamic>? _pbx; // how the hub stands with the PBX; null until it answers
  List<PbxExtension> _extensions = []; // the PBX's extensions, as the hub lists them
  List<String> _devices = []; // the screens the hub has heard from
  FaceStatus? _faceStatus; // how the hub stands with face sign-in; null until it answers
  bool _faceEnabled = false;
  bool _faceKnown = false; // the hub answered about faces at all (an older hub does not)
  List<StaffEntry> _staff = [];
  String? _faceMessage;
  bool _faceBusy = false;
  HandsFree? _handsFree; // the hands-free switching as the hub has it; null until it answers (an older hub)
  bool _handsFreeBusy = false;
  String? _handsFreeMessage;
  PrinterSettings? _printers; // the kitchen printers as the hub has them; null until it answers (an older hub)
  TableTimers? _timers; // the table timers as the hub has them; null until it answers (an older hub)
  VoidRules? _voids; // the void rules as the hub has them; null until it answers (an older hub)
  BagQuestion? _bag; // the to-go question as the hub has it; null until it answers (an older hub)
  List<BoardRow>? _board; // what is sold out and what has a number left; null until the hub answers
  StationList? _stations; // the stations the menu prints at, with the ones missing a printer
  TicketWords? _ticketWords; // what the tickets of one send say about each other; null from an older hub
  BillSettings? _bill; // the guest's bill as the hub has it; null from an older hub, which prints none
  TicketSkips? _ticketSkips; // the stations each screen prints no ticket at; null from an older hub
  bool _ticketWordsBusy = false;
  String? _ticketWordsMessage;
  ClockSetting? _clock; // the time clock as the hub has it; null from an older hub, which has none
  bool _clockBusy = false;
  String? _clockMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.controller.dispose();
    }
    for (final phone in _phones) {
      phone.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final coursing = await widget.api.coursing();
      final quotes = await widget.api.quotes();
      final phones = await widget.api.deskPhones();
      if (!mounted) return;
      setState(() {
        _quotes = quotes;
        _apply(coursing);
        _applyPhones(phones);
      });
    } on ApiException catch (err) {
      if (mounted) setState(() => _loadError = err.message);
    }
    try {
      final pbx = await widget.api.pbxStatus();
      if (mounted) setState(() => _pbx = pbx);
    } on ApiException {
      // the card then says the hub did not answer about the PBX
    }
    try {
      final extensions = await widget.api.extensions();
      if (mounted) setState(() => _extensions = extensions);
    } on ApiException {
      // an older hub, or no PBX: the extension is typed
    }
    try {
      final devices = await widget.api.devicesSeen();
      if (mounted) setState(() => _devices = devices);
    } on ApiException {
      // an older hub: the list holds this device and Other
    }
    try {
      final timers = await widget.api.tableTimers();
      if (mounted) setState(() => _timers = timers);
    } on ApiException {
      // an older hub without table timers: the card says so
    }
    try {
      final voids = await widget.api.voidRules();
      if (mounted) setState(() => _voids = voids);
    } on ApiException {
      // nothing answered about voids: the card says so
    }
    try {
      final bag = await widget.api.bagQuestion();
      if (mounted) setState(() => _bag = bag);
    } on ApiException {
      // nothing answered about the to-go question: the row says so
    }
    try {
      final board = await widget.api.board();
      if (mounted) setState(() => _board = board);
    } on ApiException {
      // nothing answered about the 86 board: the card says so
    }
    try {
      final clock = await widget.api.clockSetting();
      if (mounted) setState(() => _clock = clock);
    } on ApiException {
      // nothing answered about the time clock: the card says so
    }
    await _loadFaces();
    await _loadPrinters();
  }

  /// The time clock's switches save as they are flipped: on or off, breaks counted or not, the week's first day.
  Future<void> _saveClock(ClockSetting next) async {
    final was = _clock;
    setState(() {
      _clock = next;
      _clockBusy = true;
      _clockMessage = null;
    });
    try {
      final saved = await widget.api.saveClockSetting(widget.token, next);
      if (mounted) setState(() => _clock = saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _clock = was;
        _clockMessage = 'Not saved: ${err.detail?['message'] ?? err.message}';
      });
    } finally {
      if (mounted) setState(() => _clockBusy = false);
    }
  }

  Future<void> _loadPrinters() async {
    try {
      final printers = await widget.api.printerSettings();
      final stations = await widget.api.printStations();
      if (!mounted) return;
      setState(() {
        _printers = printers;
        _stations = stations;
      });
    } on ApiException {
      // an older hub without printer settings: the card says so
    }
    try {
      final words = await widget.api.ticketWords();
      if (mounted) setState(() => _ticketWords = words);
    } on ApiException {
      // an older hub prints none of the lines: the card shows no switch for them
    }
    try {
      final bill = await widget.api.billSettings();
      if (mounted) setState(() => _bill = bill);
    } on ApiException {
      // nothing answered about the bill: the card shows no row for it
    }
    try {
      final skips = await widget.api.ticketSkips();
      if (mounted) setState(() => _ticketSkips = skips);
    } on ApiException {
      // nothing answered about the screens that skip a station: the card shows no row for them
    }
  }

  /// One line on the bill: where it prints and what heads it.
  String get _billLine {
    final bill = _bill!;
    final at = bill.nameOf(bill.printsAt);
    final head = bill.header.where((line) => line.isNotEmpty).firstOrNull;
    return [
      at == null ? 'No printer to print it at' : 'Prints at $at',
      head == null ? 'no heading yet' : 'headed "$head"',
    ].join(' · ');
  }

  Future<void> _openBill() async {
    final saved = await showDialog<BillSettings>(
      context: context,
      builder: (_) => BillDialog(api: widget.api, token: widget.token, bill: _bill!),
    );
    if (saved == null || !mounted) return;
    setState(() => _bill = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The bill is saved')));
  }

  Future<void> _openTicketSkips() async {
    final saved = await showDialog<TicketSkips>(
      context: context,
      builder: (_) => TicketSkipsDialog(
        api: widget.api,
        token: widget.token,
        skips: _ticketSkips!,
        stations: _stations?.stations ?? const [],
        devices: _devices,
        device: widget.device,
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _ticketSkips = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved: the next send prints by it')));
  }

  Future<void> _saveTicketWords(TicketWords next) async {
    setState(() {
      _ticketWordsBusy = true;
      _ticketWordsMessage = null;
    });
    try {
      final saved = await widget.api.saveTicketWords(widget.token, next);
      if (!mounted) return;
      setState(() {
        _ticketWords = saved;
        _ticketWordsBusy = false;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _ticketWordsBusy = false;
        _ticketWordsMessage = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _openPrinters() async {
    await Navigator.of(context).push(
      PosPageRoute(
        builder: (_) => PrintersScreen(api: widget.api, token: widget.token),
      ),
    );
    if (mounted) await _loadPrinters();
  }

  /// One line on the printers: how many, and the stations the menu prints at that have none.
  String get _printersLine {
    final printers = _printers;
    if (printers == null) return 'The hub has not answered about printers (an older hub: update it)';
    final count = printers.printers.length;
    final head = count == 0
        ? 'No printer yet'
        : '$count ${count == 1 ? 'printer' : 'printers'}'
              '${printers.source == 'env' ? ' from the hub\'s POS_PRINTERS' : ''}';
    final missing = _stations?.missing ?? const [];
    if (missing.isEmpty) return count == 0 ? '$head: add the kitchen\'s printers' : head;
    final names = missing.map((code) => _stations!.nameOf(code)).join(', ');
    return '$head · no printer for $names';
  }

  Future<void> _loadFaces() async {
    try {
      final status = await widget.api.faceStatus();
      final enabled = await widget.api.faceSetting();
      final staff = await widget.api.adminStaff(widget.token);
      if (!mounted) return;
      setState(() {
        _faceStatus = status;
        _faceEnabled = enabled;
        _staff = staff;
        _faceKnown = true;
      });
    } on ApiException {
      // an older hub without face sign-in: the card says so
    }
    try {
      final handsFree = await widget.api.handsFree();
      if (mounted) setState(() => _handsFree = handsFree);
    } on ApiException {
      // an older hub without hands-free switching: the card says so
    }
  }

  Future<void> _saveHandsFree(HandsFree next) async {
    setState(() {
      _handsFreeBusy = true;
      _handsFreeMessage = null;
    });
    try {
      final saved = await widget.api.saveHandsFree(widget.token, next);
      if (!mounted) return;
      setState(() {
        _handsFree = saved;
        _handsFreeBusy = false;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _handsFreeBusy = false;
        _handsFreeMessage = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _giveTag(StaffEntry staff) async {
    final ends = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TagEnrollDialog(
        api: widget.api,
        token: widget.token,
        staff: staff,
        device: widget.device ?? '',
        reader: widget.tags,
      ),
    );
    if (!mounted) return;
    await _loadFaces();
    if (!mounted || ends == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${staff.name}: tag …$ends kept')));
  }

  Future<void> _forgetTag(StaffEntry staff) async {
    setState(() => _faceMessage = null);
    try {
      await widget.api.forgetTag(widget.token, staff.staffId);
      if (!mounted) return;
      await _loadFaces();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${staff.name}\'s tag forgotten')));
    } on ApiException catch (err) {
      if (mounted) setState(() => _faceMessage = err.detail?['message'] as String? ?? err.message);
    }
  }

  Future<void> _switchFaces(bool on) async {
    setState(() {
      _faceBusy = true;
      _faceMessage = null;
    });
    try {
      final saved = await widget.api.saveFaceSetting(widget.token, enabled: on);
      final status = await widget.api.faceStatus();
      if (!mounted) return;
      setState(() {
        _faceEnabled = saved;
        _faceStatus = status;
        _faceBusy = false;
      });
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _faceBusy = false;
        _faceMessage = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _enroll(StaffEntry staff) async {
    final camera = widget.camera;
    if (camera == null) return;
    final views = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FaceEnrollDialog(
        api: widget.api,
        token: widget.token,
        staff: staff,
        camera: camera,
        device: widget.device ?? '',
      ),
    );
    if (!mounted) return;
    await _loadFaces();
    if (!mounted || views == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(views > 0 ? '${staff.name}: $views views enrolled' : 'Nothing enrolled for ${staff.name}'),
      ),
    );
  }

  Future<void> _forget(StaffEntry staff) async {
    setState(() => _faceMessage = null);
    try {
      await widget.api.forgetFace(widget.token, staff.staffId);
      if (!mounted) return;
      await _loadFaces();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${staff.name} signs in by PIN now')));
    } on ApiException catch (err) {
      if (mounted) setState(() => _faceMessage = err.detail?['message'] as String? ?? err.message);
    }
  }

  /// One line under a staff member's name: their role and how their face stands.
  String _staffLine(StaffEntry staff) {
    final role = staff.role.isEmpty ? '' : '${staff.role[0].toUpperCase()}${staff.role.substring(1)} · ';
    final tag = staff.hasTag ? ' · tag …${staff.tagEnds}' : '';
    if (staff.enrolled) {
      final at = staff.updatedAt;
      final when = at == null ? '' : ' on ${at.month}/${at.day}';
      return '${role}Enrolled, ${staff.samples} views$when$tag';
    }
    if (staff.stale > 0) return '${role}Enrolled with an older model: enroll again$tag';
    return '${role}Not enrolled: signs in by ${staff.hasTag ? 'tag or PIN' : 'PIN'}$tag';
  }

  void _applyPhones(DeskPhoneLinks links) {
    for (final phone in _phones) {
      phone.dispose();
    }
    _phones = [
      for (final link in links.links) _PhoneRow(link.extension, extension: link.extension, device: link.device),
    ];
  }

  void _addPhone() => setState(() => _phones.add(_PhoneRow('new-${++_phonesAdded}', extension: '', device: '')));

  void _removePhone(_PhoneRow phone) => setState(() {
    _phones.remove(phone);
    phone.dispose();
  });

  Future<void> _savePhones() async {
    final links = [for (final phone in _phones) phone.link];
    if (links.any((l) => l.extension.isEmpty || l.device.isEmpty)) {
      setState(() => _phonesMessage = 'Every phone needs its extension and the name of its screen.');
      return;
    }
    setState(() {
      _phonesBusy = true;
      _phonesMessage = null;
    });
    try {
      final saved = await widget.api.saveDeskPhones(widget.token, DeskPhoneLinks(links));
      if (!mounted) return;
      setState(() {
        _phonesBusy = false;
        _applyPhones(saved);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Desk phones saved')));
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _phonesBusy = false;
        _phonesMessage = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  /// One line on the hub's link to the PBX, which the desk phones depend on.
  String get _pbxLine {
    final pbx = _pbx;
    if (pbx == null) return 'The hub has not said how it stands with the PBX';
    if (pbx['configured'] != true) return 'The hub is not linked to the PBX yet: see the hub guide (hubctl pbx)';
    final host = pbx['host'] ?? 'the PBX';
    if (pbx['connected'] == true) {
      return 'Hub watching $host · ${pbx['answers'] ?? 0} calls answered, ${pbx['pops'] ?? 0} opened on a screen';
    }
    return 'Hub cannot reach $host: ${pbx['last_error'] ?? 'not connected'}';
  }

  /// The screen as the hub has it; rows get the ids the hub gave them.
  void _apply(Coursing coursing) {
    for (final row in _rows) {
      row.controller.dispose();
    }
    _coursing = coursing;
    _enabled = coursing.enabled;
    _rows = [for (final c in coursing.courses) _Row(c.id, id: c.id, name: c.name)];
    _defaultKey = coursing.defaultCourse;
  }

  void _add() => setState(() {
    final row = _Row('new-${++_added}', name: '');
    _rows.add(row);
    _defaultKey ??= row.key;
  });

  void _remove(_Row row) => setState(() {
    _rows.remove(row);
    row.controller.dispose();
    if (_defaultKey == row.key) _defaultKey = _rows.firstOrNull?.key;
  });

  void _reorder(int from, int to) => setState(() => _rows.insert(to, _rows.removeAt(from)));

  Future<void> _save() async {
    if (_rows.any((r) => r.name.isEmpty)) {
      setState(() => _message = 'Every course needs a name.');
      return;
    }
    if (_enabled && _rows.isEmpty) {
      setState(() => _message = 'Coursing needs at least one course, or turn it off.');
      return;
    }
    // A course from the hub keeps its id; a new one gets one from its name, unique among the rest.
    final taken = {for (final r in _rows) ?r.id};
    final courses = <Course>[];
    String? defaultId;
    for (final row in _rows) {
      final id = row.id ?? newCourseId(row.name, taken);
      taken.add(id);
      courses.add(Course(id, row.name));
      if (row.key == _defaultKey) defaultId = id;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveCoursing(
        widget.token,
        Coursing(enabled: _enabled, defaultCourse: defaultId ?? courses.firstOrNull?.id, courses: courses),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _apply(saved);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Courses saved')));
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = err.detail?['message'] as String? ?? err.message;
      });
    }
  }

  Future<void> _quoteTimes() async {
    final saved = await showDialog<Quotes>(
      context: context,
      builder: (_) => QuotesDialog(api: widget.api, token: widget.token, quotes: _quotes ?? const Quotes()),
    );
    if (saved == null || !mounted) return;
    setState(() => _quotes = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Quote times saved')));
  }

  Future<void> _bagQuestion() async {
    final saved = await showDialog<BagQuestion>(
      context: context,
      builder: (_) => BagQuestionDialog(api: widget.api, token: widget.token, question: _bag!),
    );
    if (saved == null || !mounted) return;
    setState(() => _bag = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('To-go question saved')));
  }

  Future<void> _tableTimers() async {
    final saved = await showDialog<TableTimers>(
      context: context,
      builder: (_) => TableTimersDialog(api: widget.api, token: widget.token, timers: _timers!),
    );
    if (saved == null || !mounted) return;
    setState(() => _timers = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Table timers saved')));
  }

  Future<void> _voidRules() async {
    final saved = await showDialog<VoidRules>(
      context: context,
      builder: (_) => VoidRulesDialog(api: widget.api, token: widget.token, rules: _voids!),
    );
    if (saved == null || !mounted) return;
    setState(() => _voids = saved);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Void rules saved')));
  }

  /// The 86 board: what is sold out and what is running low, read again each time it is opened.
  Future<void> _openBoard() async {
    final rows = await showDialog<List<BoardRow>>(
      context: context,
      builder: (_) => EightySixBoard(api: widget.api),
    );
    if (rows != null && mounted) setState(() => _board = rows);
  }

  /// One line on the void rules: who stands behind a void, and how many reasons there are to pick from.
  String get _voidsSummary {
    final voids = _voids;
    if (voids == null) return 'The hub has not answered about voids (an older hub: update it)';
    final reasons = '${voids.reasons.length} ${voids.reasons.length == 1 ? 'reason' : 'reasons'}';
    return voids.needsManager
        ? "A sent dish is voided with a reason and a manager's PIN · $reasons"
        : 'A sent dish is voided with a reason alone · $reasons';
  }

  /// One line on the to-go question: what it offers, or that nothing is asked.
  String get _bagSummary {
    final bag = _bag;
    if (bag == null) return 'The hub has not answered about the to-go question (an older hub: update it)';
    if (!bag.asks) return 'Off: a to-go order is sent with nothing asked';
    return 'Asked before a to-go order is sent: ${[for (final choice in bag.choices) choice.name].join(', ')}';
  }

  /// One line on the timers: each stage's minutes to amber and to red, a dash for never.
  String get _timersSummary {
    final timers = _timers;
    if (timers == null) return 'The hub has not answered about table timers (an older hub: update it)';
    if (!timers.enabled) return 'Off: the tables show no countdown';
    String minutes(int n) => n == 0 ? '–' : '$n';
    const short = {'sat': 'Seated', 'unsent': 'Not sent', 'held': 'Held', 'fired': 'All sent'};
    return '${[for (final stage in timerStages) '${short[stage]} ${minutes(timers.timesFor(stage).warn)}/${minutes(timers.timesFor(stage).late)}'].join(' · ')} min';
  }

  String get _quotesSummary {
    final quotes = _quotes;
    if (quotes == null) return 'Loading…';
    final channels = [
      for (final c in const ['counter', 'phone', 'online', 'delivery']) '${channelLabel(c)} ${quotes.baseFor(c)}',
    ].join(' · ');
    final big = quotes.extraFor(quotes.bigDishes) > 0
        ? ' · ${quotes.bigDishes} dishes or more +${quotes.bigMinutes}'
        : '';
    return '$channels min$big';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget body;
    if (_loadError != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    } else if (_coursing == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // first, above the settings: it is what a manager comes to look at in the middle of service
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('board'),
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('Sold out and running low'),
                  subtitle: Text(
                    _board == null
                        ? 'The hub has not answered about what is sold out'
                        : EightySixBoard.summary(_board!),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openBoard,
                ),
                const Divider(height: 1),
                // and what a manager comes to look at when service is over
                ListTile(
                  key: const ValueKey('day-report'),
                  leading: const Icon(Icons.summarize_outlined),
                  title: const Text('The day'),
                  subtitle: const Text('Sales, the money taken, what came off and what is still open'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DayReportScreen(api: widget.api, token: widget.token, device: widget.device),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('sales-report'),
                  leading: const Icon(Icons.insights_outlined),
                  title: const Text('Sales'),
                  subtitle: const Text('Any days, beside the same days the weeks before'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SalesScreen(api: widget.api, token: widget.token),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('dishes-report'),
                  leading: const Icon(Icons.format_list_numbered),
                  title: const Text('Dishes sold'),
                  subtitle: const Text('Best to worst, with their sizes and options'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DishesScreen(api: widget.api, token: widget.token),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('guests-report'),
                  leading: const Icon(Icons.people_outline),
                  title: const Text('Guests'),
                  subtitle: const Text('Phone customers: visits, what they spent, favourites'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => GuestsScreen(api: widget.api, token: widget.token),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // what the managers tell the staff, and each other
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('shift-notes'),
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: const Text('Notes for the shift'),
                  subtitle: const Text('What everybody sees once after signing in: the specials, what is out'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ShiftNotesScreen(api: widget.api, device: widget.device ?? '', token: widget.token),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('logbook'),
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text("Manager's log"),
                  subtitle: const Text('What happened in a shift, by subject, for the next manager'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LogbookScreen(api: widget.api, token: widget.token, device: widget.device ?? ''),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const ValueKey('coursing-enabled'),
                    value: _enabled,
                    onChanged: (on) => setState(() => _enabled = on),
                    title: const Text('Course the dishes'),
                    subtitle: Text(
                      _enabled
                          ? 'Each dish goes to a course that is held and fired on its own'
                          : 'Every dish is sent together; the order screen shows no courses',
                    ),
                  ),
                  if (_enabled) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text(
                        'In the order the kitchen serves them. The star marks where a new dish goes.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: _rows.length,
                      onReorderItem: _reorder,
                      itemBuilder: (context, i) => _courseRow(context, i),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('course-add'),
                          onPressed: _add,
                          icon: const Icon(Icons.add),
                          label: const Text('Add course'),
                        ),
                      ),
                    ),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Text(_message!, style: TextStyle(color: scheme.error)),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton(
                          key: const ValueKey('coursing-save'),
                          onPressed: _busy ? null : _save,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // what a to-go order is promised, and what it is asked before it is sent
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('quote-times'),
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Quote times'),
                  subtitle: Text(_quotesSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _quoteTimes,
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('to-go-question'),
                  leading: const Icon(Icons.shopping_bag_outlined),
                  title: const Text('To-go question'),
                  subtitle: Text(_bagSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _bag == null ? null : _bagQuestion,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const ValueKey('table-timers'),
              leading: const Icon(Icons.timelapse_outlined),
              title: const Text('Table timers'),
              subtitle: Text(_timersSummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: _timers == null ? null : _tableTimers,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('voids'),
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('Voids'),
                  subtitle: Text(_voidsSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _voids == null ? null : _voidRules,
                ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('adjustments-report'),
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Voids and comps report'),
                  subtitle: const Text('What came off the checks: by reason, by person and by manager'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AdjustmentsScreen(api: widget.api, token: widget.token),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _clockCard(context),
          const SizedBox(height: 12),
          _printersCard(context),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.phone_in_talk_outlined),
                    title: const Text('Desk phones'),
                    subtitle: Text(_pbxLine),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      'A call taken on a linked phone opens the caller\'s order on that screen, as if the screen had '
                      'taken the call. The device is the name that screen shows under Settings.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (_phones.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('No desk phone is linked yet.', style: theme.textTheme.bodyMedium),
                    ),
                  for (var i = 0; i < _phones.length; i++) _phoneRow(context, i),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('desk-add'),
                        onPressed: _addPhone,
                        icon: const Icon(Icons.add),
                        label: const Text('Add phone'),
                      ),
                    ),
                  ),
                  if (_phonesMessage != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Text(_phonesMessage!, style: TextStyle(color: scheme.error)),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton(
                          key: const ValueKey('desk-phones-save'),
                          onPressed: _phonesBusy ? null : _savePhones,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _facesCard(context),
          const SizedBox(height: 12),
          _handsFreeCard(context),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Location settings')),
      body: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }

  /// The time clock: whether the location uses it (off until a manager turns it on), whether a break counts
  /// as time worked, the day the pay week starts on, and the way to the hours. Each saves as it is changed. A
  /// hub older than the clock has none of it.
  Widget _clockCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clock = _clock;
    if (clock == null) {
      return const Card(
        child: ListTile(
          key: ValueKey('time-clock-none'),
          leading: Icon(Icons.punch_clock_outlined),
          title: Text('Time clock'),
          subtitle: Text('The hub has not answered about the time clock (an older hub: update it)'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const ValueKey('time-clock-enabled'),
            secondary: const Icon(Icons.punch_clock_outlined),
            value: clock.enabled,
            onChanged: _clockBusy ? null : (on) => _saveClock(clock.copyWith(enabled: on)),
            title: const Text('Time clock'),
            subtitle: Text(
              clock.enabled
                  ? 'Staff clock in and out and take breaks with their own PIN: Time clock on the sign-in '
                        'screen, or in the menu once signed in'
                  : 'Off: nobody is asked to clock in',
            ),
          ),
          if (clock.enabled) ...[
            SwitchListTile(
              key: const ValueKey('time-clock-breaks-paid'),
              value: clock.breaksPaid,
              onChanged: _clockBusy ? null : (on) => _saveClock(clock.copyWith(breaksPaid: on)),
              title: const Text('Breaks count as time worked'),
              subtitle: Text(
                clock.breaksPaid ? 'A break stays in the hours' : 'Off: a break is taken out of the hours',
              ),
            ),
            ListTile(
              title: const Text('The pay week starts on'),
              trailing: SegmentedButton<String>(
                key: const ValueKey('time-clock-week'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'mon', label: Text('Monday')),
                  ButtonSegment(value: 'sun', label: Text('Sunday')),
                ],
                selected: {clock.weekStarts},
                onSelectionChanged: _clockBusy
                    ? null
                    : (picked) => _saveClock(clock.copyWith(weekStarts: picked.first)),
              ),
            ),
          ],
          if (_clockMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_clockMessage!, style: TextStyle(color: scheme.error)),
              ),
            ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('time-clock-hours'),
            leading: const Icon(Icons.schedule),
            title: const Text('Hours'),
            subtitle: const Text('Who is on the clock, what each person worked, and corrections'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TimeClockScreen(api: widget.api, token: widget.token, device: widget.device),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The printers (on their own screen) and, under them, what the tickets say beyond their dishes: two switches
  /// for what the tickets of one send say about each other, and one for PAID or NOT PAID on a to-go order's
  /// takeout ticket. Each saves as it is flipped. A hub older than a switch does not show it.
  Widget _printersCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final missing = _stations?.missing.isNotEmpty ?? false;
    final words = _ticketWords;
    return Card(
      child: Column(
        children: [
          ListTile(
            key: const ValueKey('printers'),
            leading: Icon(
              missing ? Icons.print_disabled_outlined : Icons.print_outlined,
              color: missing ? scheme.error : null,
            ),
            title: const Text('Printers'),
            subtitle: Text(_printersLine),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openPrinters,
          ),
          if (_bill != null) ...[
            const Divider(height: 1),
            ListTile(
              key: const ValueKey('bill'),
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('The bill'),
              subtitle: Text(_billLine),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openBill,
            ),
          ],
          if (_ticketSkips case final skips?) ...[
            const Divider(height: 1),
            ListTile(
              key: const ValueKey('ticket-skips'),
              leading: const Icon(Icons.speaker_notes_off_outlined),
              title: const Text('Screens that skip a station'),
              subtitle: Text(ticketSkipsLine(skips, _stations)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openTicketSkips,
            ),
          ],
          if (words != null) ...[
            const Divider(height: 1),
            SwitchListTile(
              key: const ValueKey('tickets-numbered'),
              value: words.numbered,
              onChanged: _ticketWordsBusy ? null : (on) => _saveTicketWords(words.copyWith(numbered: on)),
              title: const Text('Number the tickets of one send'),
              subtitle: const Text('"Ticket 2 of 3", when more than one station is cooking'),
            ),
            SwitchListTile(
              key: const ValueKey('tickets-also-at'),
              value: words.alsoAt,
              onChanged: _ticketWordsBusy ? null : (on) => _saveTicketWords(words.copyWith(alsoAt: on)),
              title: const Text('Name the other stations on each ticket'),
              subtitle: const Text('"Also at: Wok 2, Sushi Bar", so a cook can time a dish against them'),
            ),
            if (words.paid case final paid?)
              SwitchListTile(
                key: const ValueKey('tickets-paid'),
                value: paid,
                onChanged: _ticketWordsBusy ? null : (on) => _saveTicketWords(words.copyWith(paid: on)),
                title: const Text('Print PAID or NOT PAID on to-go orders'),
                subtitle: const Text("On the takeout station's ticket, with what is still to collect"),
              ),
            if (words.moved case final moved?)
              SwitchListTile(
                key: const ValueKey('tickets-moved'),
                value: moved,
                onChanged: _ticketWordsBusy ? null : (on) => _saveTicketWords(words.copyWith(moved: on)),
                title: const Text('Tell the kitchen when a table moves'),
                subtitle: const Text('A MOVED slip at each station still cooking for it, with the new table'),
              ),
            if (_ticketWordsMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_ticketWordsMessage!, style: TextStyle(color: scheme.error)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Face sign-in: the location's switch, how the hub stands, and each staff member's enrollment.
  Widget _facesCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canEnroll = widget.camera != null && widget.camera is! NoCamera;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('faces-enabled'),
              value: _faceEnabled,
              onChanged: _faceKnown && !_faceBusy ? _switchFaces : null,
              secondary: const Icon(Icons.face_outlined),
              title: const Text('Sign in by face'),
              subtitle: Text(
                !_faceKnown
                    ? 'The hub has not answered about face sign-in (an older hub: update it)'
                    : _faceStatus?.line ?? 'Loading…',
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Enroll each person here: they look at this screen\'s camera and turn their head a little, and the hub '
                'keeps five views as templates (numbers, never pictures). The sign-in screen then recognises them; '
                'the PIN always works too. Get each person\'s consent first.'
                '${canEnroll ? '' : ' This screen has no camera: enroll from one that has.'}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            for (final staff in _staff)
              ListTile(
                key: ValueKey('staff:${staff.staffId}'),
                dense: true,
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: staff.enrolled ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                  child: Text(staff.name.isEmpty ? '?' : staff.name[0].toUpperCase()),
                ),
                title: Text(staff.name),
                subtitle: Text(_staffLine(staff)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      key: ValueKey('enroll:${staff.staffId}'),
                      onPressed: canEnroll && (_faceStatus?.ready ?? false) ? () => _enroll(staff) : null,
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: Text(staff.enrolled || staff.stale > 0 ? 'Enroll again' : 'Enroll'),
                    ),
                    if (staff.enrolled || staff.stale > 0)
                      IconButton(
                        key: ValueKey('forget:${staff.staffId}'),
                        tooltip: 'Forget the face',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _forget(staff),
                      ),
                    IconButton(
                      key: ValueKey('tag:${staff.staffId}'),
                      tooltip: staff.hasTag ? 'Another tag' : 'Give a tag',
                      icon: Icon(Icons.nfc, color: staff.hasTag ? scheme.primary : null),
                      onPressed: () => _giveTag(staff),
                    ),
                    if (staff.hasTag)
                      IconButton(
                        key: ValueKey('forget-tag:${staff.staffId}'),
                        tooltip: 'Forget the tag',
                        icon: const Icon(Icons.nfc_outlined),
                        onPressed: () => _forgetTag(staff),
                      ),
                  ],
                ),
              ),
            if (_faceMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Text(_faceMessage!, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  /// Hands-free switching: whether a face or tag seen while someone is signed in makes the screen theirs,
  /// and how long the camera may miss the signed-in person before the screen signs them out.
  Widget _handsFreeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final setting = _handsFree;
    const aways = [
      (0, 'Never'),
      (30, '30 seconds'),
      (60, '1 minute'),
      (120, '2 minutes'),
      (300, '5 minutes'),
      (600, '10 minutes'),
    ];
    final away = setting?.awaySeconds ?? 60;
    final choices = aways.any((a) => a.$1 == away) ? aways : [...aways, (away, '$away seconds')];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('hands-free-switch'),
              value: setting?.switching ?? true,
              onChanged: setting == null || _handsFreeBusy
                  ? null
                  : (on) => _saveHandsFree(setting.copyWith(switching: on)),
              secondary: const Icon(Icons.swap_horiz),
              title: const Text('Switch to whoever steps up'),
              subtitle: Text(
                setting == null
                    ? 'The hub has not answered about hands-free switching (an older hub: update it)'
                    : 'A face the camera knows, or a tag held to the reader, makes the screen that person\'s at once; '
                          'an open order stays open and each dish they add is theirs. Off: only the sign-in screen '
                          'signs people in.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Sign out when the camera has not seen the person for'),
              subtitle: const Text(
                'Once the camera has recognised the person at the screen; someone it does not know (not enrolled, '
                'or the switch off) stays until they sign out.',
              ),
              trailing: DropdownButton<int>(
                key: const ValueKey('hands-free-away'),
                value: away,
                onChanged: setting == null || _handsFreeBusy
                    ? null
                    : (seconds) {
                        if (seconds != null) _saveHandsFree(setting.copyWith(awaySeconds: seconds));
                      },
                items: [for (final (seconds, label) in choices) DropdownMenuItem(value: seconds, child: Text(label))],
              ),
            ),
            if (_handsFreeMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Text(_handsFreeMessage!, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  /// A course: the handle to move it, its name, the star for the default, and the bin.
  Widget _courseRow(BuildContext context, int i) {
    final row = _rows[i];
    final scheme = Theme.of(context).colorScheme;
    final isDefault = row.key == _defaultKey;
    return Padding(
      key: ValueKey('course:${row.key}'),
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: Padding(
              key: ValueKey('course-handle:${row.key}'),
              padding: const EdgeInsets.all(10),
              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('course-name:${row.key}'),
              controller: row.controller,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(isDense: true, hintText: 'Course name'),
            ),
          ),
          IconButton(
            key: ValueKey('course-default:${row.key}'),
            tooltip: 'Where a new dish goes',
            icon: Icon(isDefault ? Icons.star : Icons.star_border, color: isDefault ? scheme.primary : null),
            onPressed: () => setState(() => _defaultKey = row.key),
          ),
          IconButton(
            key: ValueKey('course-delete:${row.key}'),
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _remove(row),
          ),
        ],
      ),
    );
  }

  /// A desk phone: its extension, picked from the PBX's (typed when the hub lists none, or after "Other"),
  /// the screen it is linked to, picked from the ones the hub knows with this one first (or typed after
  /// "Other"), and the bin.
  Widget _phoneRow(BuildContext context, int i) {
    final phone = _phones[i];
    return Padding(
      key: ValueKey('desk-phone:${phone.key}'),
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        children: [
          SizedBox(
            width: 136,
            child: _extensions.isEmpty || phone.extensionTyped
                ? TextField(
                    key: ValueKey('desk-ext:$i'),
                    controller: phone.extension,
                    focusNode: phone.extensionFocus,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Extension',
                      hintText: '200',
                      suffixIcon: _extensions.isEmpty
                          ? null
                          : _backToList(ValueKey('desk-ext-list:$i'), () => phone.extensionTyped = false),
                    ),
                  )
                : _pullDown(
                    key: ValueKey('desk-ext-pick:$i'),
                    label: 'Extension',
                    controller: phone.extension,
                    items: _extensionItems(phone.extension.text.trim()),
                    onOther: () => phone.extensionTyped = true,
                    typing: phone.extensionFocus,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: phone.deviceTyped
                ? TextField(
                    key: ValueKey('desk-dev:$i'),
                    controller: phone.device,
                    focusNode: phone.deviceFocus,
                    autocorrect: false,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Device',
                      hintText: 'tab1',
                      suffixIcon: _backToList(ValueKey('desk-dev-list:$i'), () => phone.deviceTyped = false),
                    ),
                  )
                : _pullDown(
                    key: ValueKey('desk-dev-pick:$i'),
                    label: 'Device',
                    controller: phone.device,
                    items: _deviceItems(phone.device.text.trim()),
                    onOther: () => phone.deviceTyped = true,
                    typing: phone.deviceFocus,
                  ),
          ),
          IconButton(
            key: ValueKey('desk-delete:$i'),
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _removePhone(phone),
          ),
        ],
      ),
    );
  }

  /// The value of the "Other…" entry at the end of each list; nothing a manager types can be it.
  static const _other = '\u0000other';

  /// A list to pick from, in the frame of a field: the pick goes to [controller] (whose text is the current
  /// pick, or nothing yet), and "Other…" at the end calls [onOther] with the text cleared, for typing: the
  /// field that takes the list's place gets the focus ([typing]) as soon as it is there, so one just types,
  /// and a touch screen brings up its keyboard.
  Widget _pullDown({
    required Key key,
    required String label,
    required TextEditingController controller,
    required List<(String, String)> items,
    required VoidCallback onOther,
    required FocusNode typing,
  }) {
    final current = controller.text.trim();
    return InputDecorator(
      decoration: InputDecoration(isDense: true, labelText: label),
      isEmpty: current.isEmpty,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: key,
          value: current.isEmpty ? null : current,
          isExpanded: true,
          isDense: true,
          items: [
            for (final (value, shown) in items)
              DropdownMenuItem(
                value: value,
                child: Text(shown, overflow: TextOverflow.ellipsis),
              ),
            const DropdownMenuItem(value: _other, child: Text('Other…')),
          ],
          onChanged: (picked) => setState(() {
            if (picked == _other) {
              controller.clear();
              onOther();
              WidgetsBinding.instance.addPostFrameCallback((_) => typing.requestFocus());
            } else if (picked != null) {
              controller.text = picked;
            }
          }),
        ),
      ),
    );
  }

  /// Back from typing to the list (the typed text stays as the pick).
  Widget _backToList(Key key, VoidCallback back) => IconButton(
    key: key,
    tooltip: 'Pick from the list',
    icon: const Icon(Icons.arrow_drop_down),
    onPressed: () => setState(back),
  );

  /// The PBX's extensions, lowest first, an offline one marked, with [current] among them even when the PBX
  /// does not list it (it was typed, or the PBX has changed).
  List<(String, String)> _extensionItems(String current) {
    final known = {for (final ext in _extensions) ext.extension: ext.online};
    final numbers = [...known.keys, if (current.isNotEmpty && !known.containsKey(current)) current]
      ..sort((a, b) => (int.tryParse(a) ?? 1 << 30).compareTo(int.tryParse(b) ?? 1 << 30));
    return [for (final number in numbers) (number, known[number] == false ? '$number (offline)' : number)];
  }

  /// The screens: this one first, marked, then the ones the hub has heard from by name, with [current] among
  /// them even when the hub has not heard from it.
  List<(String, String)> _deviceItems(String current) {
    final here = widget.device?.trim() ?? '';
    final others = <String>{
      for (final device in _devices)
        if (device.toLowerCase() != here.toLowerCase()) device,
      if (current.isNotEmpty && current != here) current,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [if (here.isNotEmpty) (here, '$here (this device)'), for (final device in others) (device, device)];
  }
}
