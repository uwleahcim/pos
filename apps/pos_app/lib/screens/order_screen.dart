import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../allergies.dart';
import '../api.dart';
import '../bag.dart';
import '../check_order.dart';
import '../coursing.dart';
import '../customers.dart';
import '../dish_names.dart';
import '../line_ops.dart';
import '../live.dart';
import '../local_order.dart';
import '../menu.dart';
import '../outbox.dart';
import '../phone.dart';
import '../photos.dart';
import '../pricing.dart';
import '../printers.dart';
import '../session.dart';
import '../floor.dart';
import '../moves.dart';
import '../split.dart';
import '../takeout.dart';
import '../voids.dart';
import 'allergy_dialog.dart';
import 'bag_sheet.dart';
import 'check_history_screen.dart';
import 'check_list.dart';
import 'comp_menu.dart';
import 'compact.dart';
import 'discount_sheet.dart';
import 'event_fields.dart';
import 'lot_comp_dialog.dart';
import 'menu_editor.dart' show ManagerPinDialog;
import 'menu_panel.dart';
import 'pay_dialog.dart';
import 'split_screen.dart';
import 'status_bar.dart';
import 'tab_dialog.dart';
import 'table_moves.dart';
import 'tax_exempt_dialog.dart';
import 'theme.dart';
import 'void_dialog.dart';

/// What the order screen closes with when "Seat at a table" was tapped on a bar tab: the tab as this screen
/// had it. The list of checks takes it from there: the floor map comes up, and the next table tapped is
/// where the party sits down. [thenSignOut] says this device goes back to sign-in after sending and drinks
/// were sent from here, so the person is signed out once the tab is seated rather than on the way there.
class SeatTab {
  const SeatTab(this.order, {this.thenSignOut = false});

  final Order order;
  final bool thenSignOut;
}

/// One order: its check as the backend prices it, and the menu whose taps append to it.
class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.api,
    required this.outbox,
    required this.photos,
    required this.orderId,
    this.coursing = Coursing.defaults,
    this.staffName,
    this.session,
    this.phone,
    this.now,
  });

  final PosApi api;
  final Outbox outbox;
  final PhotoQueue photos;
  final String orderId;

  /// What time it is, for how long ago a dish was sent; the device's own clock unless a test names one.
  /// It is the clock that stamps what this screen sends and the one in the corner of the device, so "sent
  /// 18:42, 23 min ago" adds up with what the server sees.
  final int Function()? now;

  /// The terminal's phone, when it is one, for the status icon.
  final PhoneClient? phone;

  /// The location's coursing: whether dishes are coursed, the courses by name, where a new dish goes.
  final Coursing coursing;

  /// Who is signed in, named on each dish they add and each discount they apply. [session] says who it is now:
  /// a hands-free switch changes the person under an open order, and every dish added from then on is theirs;
  /// [staffName] stands in for a screen without a session.
  final String? staffName;
  final Session? session;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Order? _read; // what the backend last returned
  Check? _readCheck;
  final _local = <String, LocalLine>{}; // line id -> what this screen knew when it added the line
  String? _lastAdded; // the check scrolls to it

  /// Who is at the screen now.
  String? get _staffName => widget.session?.staff?.name ?? widget.staffName;
  String? get _staffId => widget.session?.staff?.staffId;
  Timer? _timer;
  // The hub tells this screen when its order changed (another terminal added to the table, the kitchen
  // was fired from the floor); the timer only asks while it cannot, and now and then.
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(milliseconds: 250), _fetch);
  StreamSubscription<LiveChange>? _live;
  int? _seat; // null: for the table, shared
  List<Allergen>? _allergens; // what the menu names; null until read, and on a hub older than allergies
  Map<String, String> _allergenNames = const {};
  final _warned = <String>{}; // the dishes whose allergy mark this screen has already said
  String _customerNote = ''; // the line kept about the customer at this order's number
  String? _noteFor; // the number's digits it was read for
  Quotes? _quotes; // read once for a to-go order: a big order is promised later, settled as it is sent
  bool _quotesAsked = false;
  Future<BagQuestion?>? _bagRead; // the to-go question as the location set it, being read or read
  bool _billing = false; // a bill is on its way to the printer: the button waits
  bool _packing = false; // so is a pack sheet
  bool _sentHere = false; // dishes were sent to the kitchen from this screen since it opened
  final _changes = _Changes(); // tells the split screen, which stands over this one, of a new read
  int? _extraSaid; // the big-order minutes this screen last told the operator of; null until it knows them
  late String? _course = widget.coursing.enabled ? widget.coursing.defaultCourse : null; // null: not coursed

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) _refresh();
    });
    _live = widget.api.live.changes.listen((change) {
      if (change.touches(widget.orderId)) _reader();
    });
    widget.outbox.addListener(_onOutbox);
    _refresh();
    unawaited(_readAllergens());
    final fresh = _order; // a to-go order opened here a moment ago: no hub has it yet
    if (fresh != null) unawaited(_readQuotes(fresh));
  }

  /// The quote times, once, for a to-go order the kitchen does not have yet: what a big order adds shows
  /// in the title while the dishes go on, so the customer hears the right time.
  Future<void> _readQuotes(Order order) async {
    if (_quotesAsked || !order.isTakeout) return;
    _quotesAsked = true;
    try {
      final quotes = await widget.api.quotes();
      if (!mounted) return;
      setState(() => _quotes = quotes);
      _extraSaid = 0; // one that is big as it opens (the same again as last time) is said like any other
      _sayIfBig();
    } on ApiException {
      // nothing answers and nothing was saved: the order keeps the time it was given
    }
  }

  /// The minutes this order takes on top of its quote for being big, while that is still open: until it is
  /// first sent to the kitchen. After that its time is settled and changes only by hand.
  int _extra(Order order) {
    final quotes = _quotes;
    if (quotes == null || !order.isTakeout || !order.isOpen || order.isFired || order.promisedAt == null) return 0;
    return quotes.extraFor(order.dishes);
  }

  /// Whether the customer named this order's time. An order from before orders said so is told by its
  /// time: further off than its own quote, it was asked for then.
  bool _namedTime(Order order) {
    if (order.forLater) return true;
    final promised = order.promisedAt;
    if (promised == null || order.fields.containsKey('for_later')) return false;
    final ahead = promised - DateTime.now().millisecondsSinceEpoch;
    return ahead > (order.quotedMinutes + 1) * 60000;
  }

  /// When the order will be ready as it stands on this screen: its promised time, and what being big adds
  /// while that is still to settle. A time the customer named does not move.
  int? _readyAt(Order order) {
    final promised = order.promisedAt;
    if (promised == null) return null;
    return _namedTime(order) ? promised : promised + _extra(order) * 60000;
  }

  /// What settles a big order's time, to go in the batch that first sends it: the quote grows by the extra
  /// minutes, and so does the promised time unless the customer named it (then the kitchen starts sooner).
  List<(String, Map<String, dynamic>)> _settleQuote(Order order) {
    final extra = _extra(order);
    final promised = order.promisedAt;
    if (extra == 0 || promised == null) return const [];
    return [
      (
        'set_field',
        {
          'quoted_minutes': order.quotedMinutes + extra,
          if (!_namedTime(order)) 'promised_at': promised + extra * 60000,
        },
      ),
    ];
  }

  /// Says it once when the order becomes big, or stops being big, so the operator can tell the customer.
  void _sayIfBig() {
    final order = _order;
    if (order == null || _quotes == null || _extraSaid == null) return;
    final extra = _extra(order);
    if (extra == _extraSaid) return;
    _extraSaid = extra;
    if (order.isFired) return; // sent: the time is settled, nothing more to tell
    final ready = _readyAt(order);
    if (ready == null) return;
    final named = _namedTime(order);
    final String words;
    if (extra > 0) {
      words = named
          ? 'Big order: the kitchen starts it $extra minutes sooner. Still for ${clockTime(ready)}.'
          : 'Big order: ready at ${clockTime(ready)}, $extra minutes later.';
    } else {
      words = named ? 'No longer a big order.' : 'No longer a big order: ready at ${clockTime(ready)}.';
    }
    // Queued behind whatever is showing: an allergy warning is never cut short for this.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(key: const ValueKey('big-order-said'), content: Text(words)));
  }

  Future<void> _readAllergens() async {
    try {
      final allergens = await widget.api.allergens();
      if (!mounted || allergens == null) return;
      setState(() {
        _allergens = allergens;
        _allergenNames = allergenNames(allergens);
      });
    } on ApiException {
      // nothing answers and no list was saved: no Allergy chip until the screen is opened again
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    widget.outbox.removeListener(_onOutbox);
    _changes.dispose();
    super.dispose();
  }

  /// A tap queued or the hub accepted something: redraw now, and read back once nothing is left to send.
  void _onOutbox() {
    if (!mounted) return;
    setState(() {});
    _sayIfBig();
    final waiting = widget.outbox.pendingOps.any((op) => op['order_id'] == widget.orderId);
    if (!waiting && widget.outbox.localOps(widget.orderId).isNotEmpty) _refresh();
  }

  /// Reads the order unless a read is already under way (that one will do: what this screen sent is read
  /// back once the outbox settles, and what others changed the hub tells).
  Future<void> _refresh() => _reader.now(must: false);

  Future<void> _fetch() async {
    _poll.asked();
    final mark = widget.outbox.readMark;
    try {
      final order = await widget.api.order(widget.orderId);
      final check = await widget.api.check(widget.orderId);
      final settled = widget.outbox.seen(widget.orderId, mark);
      final first = _read == null;
      // A backend with nothing new hands back the order and the check it gave last time: nothing to redraw
      // then, unless this read is the one that shows what this screen sent.
      final same = identical(order, _read) && identical(check, _readCheck) && !settled;
      if (mounted && !same) {
        setState(() {
          _read = order;
          _readCheck = check;
        });
        _changes.tell();
        _sayAllergic(order, quiet: first);
        _sayIfBig(); // another screen may have added the dishes that make it one
        unawaited(_readCustomer(order));
        unawaited(_readQuotes(order));
        if (order.isTakeout && order.isOpen) unawaited(_bagQuestion()); // read by the time Send is tapped
      }
    } on ApiException {
      // 404 until the create op lands; the status bar shows outages.
    }
  }

  /// The line kept about the customer at this order's number ("no MSG, side door"), read once for the
  /// number: whoever rings the dishes in sees it, on a new order and on the one a caller comes back to.
  Future<void> _readCustomer(Order order) async {
    final digits = phoneDigits(order.fields['phone']?.toString());
    if (digits == _noteFor) return;
    _noteFor = digits;
    final customer = await widget.api.customer(digits);
    if (!mounted || _noteFor != digits) return;
    final note = customer?.note ?? '';
    if (note != _customerNote) setState(() => _customerNote = note);
  }

  /// The order as it stands on this screen: the last read plus this device's operations not yet in it.
  Order? get _order {
    final local = widget.outbox.localOps(widget.orderId);
    final base = _read ?? (local.isEmpty ? null : Order.empty(widget.orderId));
    return base == null ? null : withLocalOps(base, local);
  }

  /// A dish the hub marks as containing what its seat cannot have is said aloud once, when the mark first
  /// shows: on a phone the check is behind the menu, and the mark on it would go unseen. What a check
  /// already carried when it was opened is not said again ([quiet]): the strip and the marks show it.
  void _sayAllergic(Order order, {required bool quiet}) {
    final marked = {
      for (final line in order.activeLines)
        if (line.allergy.isNotEmpty) line.lineId: line,
    };
    _warned.retainAll(marked.keys); // taken off and told again, it is said again
    final fresh = [
      for (final line in marked.values)
        if (_warned.add(line.lineId)) line,
    ];
    if (quiet || fresh.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final words = fresh.length == 1
        ? 'ALLERGY: ${fresh.single.item} ${containsWords(fresh.single.allergy, _allergenNames)}.'
        : 'ALLERGY: ${fresh.length} dishes on this check contain what the guest cannot have. They are marked.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('allergy-warning'),
        backgroundColor: scheme.error,
        duration: const Duration(seconds: 8),
        content: Text(
          words,
          style: TextStyle(color: scheme.onError, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  /// The Allergy chip, or the strip that lists what was told: note what a guest cannot have, for the table
  /// or for a seat, change it or take it off. Each seat changed is its own operation, so two screens noting
  /// two seats both count. With dishes already at the kitchen, the hub prints the stations a notice.
  Future<void> _noteAllergy(Order order) async {
    final changed = await showDialog<List<Allergy>>(
      context: context,
      builder: (_) => AllergyDialog(
        allergens: _allergens ?? const [],
        told: order.allergies,
        seated: order.hasTable,
        seats: _seats(order),
        seat: _seat,
      ),
    );
    if (changed == null || changed.isEmpty) return;
    await _appendAll([for (final told in changed) ('allergy', told.toOp(by: _staffName, byId: _staffId))]);
    if (mounted && order.activeLines.any((l) => l.fired)) {
      _say('The kitchen gets a ticket about it for the dishes it already has.');
    }
  }

  static const _photographed = {
    'fire',
    'close',
    'reopen',
    'void_line',
    'void_order',
    'discount',
    'remove_discount',
    'charge',
    'remove_charge',
    'pay',
  };

  Future<void> _append(String kind, [Map<String, dynamic> data = const {}]) => _appendAll([(kind, data)]);

  /// Operations that belong together go in one batch, so the kitchen gets one ticket for a change. A dish
  /// taken off, or fewer of one kept, says who did it: nothing is asked for an unsent dish, and the hub's
  /// report of dishes taken off before sending names the person (a void of a sent dish already does).
  Future<void> _appendAll(List<(String, Map<String, dynamic>)> asked) async {
    final ops = [
      for (final (kind, data) in asked)
        if (kind == 'void_line' || (kind == 'set_line' && data.containsKey('qty')))
          (
            kind,
            {
              ...data,
              if (!data.containsKey('by')) 'by': ?_staffName,
              if (!data.containsKey('by_id')) 'by_id': ?_staffId,
            },
          )
        else
          (kind, data),
    ];
    final ids = await widget.outbox.addAll(widget.orderId, ops);
    final i = ops.indexWhere((op) => _photoOf(op) != null);
    if (i >= 0) unawaited(widget.photos.capture(_photoOf(ops[i])!, opId: ids[i]));
  }

  /// What the silent photo of an operation is filed under, or null for one that takes none. A check marked
  /// tax exempt is a field like its table, so it is told apart by what it sets.
  static String? _photoOf((String, Map<String, dynamic>) op) {
    if (_photographed.contains(op.$1)) return op.$1;
    if (op.$1 == 'set_field' && op.$2['tax_exempt'] != null) return 'tax_exempt';
    return null;
  }

  /// The `add_line` for a dish, priced on this screen until the hub answers. [replaces] names the line an
  /// edit takes off, so a comp on it follows the changed dish (here and on the hub).
  Map<String, dynamic> _lineData(ChosenLine line, {required int? seat, required String? course, String? replaces}) {
    final id = widget.outbox.newId();
    _lastAdded = id;
    _local[id] = LocalLine(
      unitPrice: line.unitPrice,
      modifiers: line.modifiers,
      itemId: line.itemId,
      entryId: line.request.entryId,
      zhName: line.zhName,
    );
    return {
      'line_id': id,
      'item': line.name,
      'qty': line.qty,
      'seat': ?seat,
      'course': ?course,
      'replaces': ?replaces,
      'by': ?_staffName,
      'by_id': ?_staffId,
      if (line.note.isNotEmpty) 'note': line.note,
      'request': line.request.toJson(),
    };
  }

  Future<void> _add(ChosenLine line) => _append('add_line', _lineData(line, seat: _seat, course: _course));

  /// The check's whole history, for a manager (docs/check-history.md): every step, who did it, at which
  /// screen and when. Anyone may ask; the hub tells it to the PIN of a manager, or of someone the location
  /// handed the history to (docs/roles.md).
  Future<void> _history() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => ManagerPinDialog(
        api: widget.api,
        device: widget.api.settings.device,
        action: 'Show the history',
        what: "read a check's history",
        power: 'history',
      ),
    );
    if (token == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CheckHistoryScreen(api: widget.api, token: token, orderId: widget.orderId),
      ),
    );
  }

  /// A discount or a charge from the location's rules. The hub refuses what its rules do not allow, so the
  /// sheet shows them first; a reason that needs a manager asks for the PIN before anything is sent.
  Future<void> _discount() async {
    if (!widget.api.connection.value.isOnline) {
      _say('Discounts need a hub or the cloud, and none answers now.');
      return;
    }
    final PricingRules rules;
    try {
      rules = await widget.api.pricingRules();
    } on ApiException catch (err) {
      _say(err.message);
      return;
    }
    if (!mounted) return;
    final check = _readCheck;
    final choice = await showDialog<Adjustment>(
      context: context,
      builder: (_) => DiscountSheet(
        rules: rules,
        lines: check?.lines ?? const [],
        existing: check?.discounts ?? const [],
        // offered by a hub that knows of it, on a check that pays its tax now
        taxExempt: (check?.exempts ?? false) && check?.exempt == null,
      ),
    );
    if (choice == null || !mounted) return;
    await _apply(choice);
  }

  /// A comp on one dish, from a hold on its price: the menu at the price offers the reasons the rules allow
  /// on an item (and takes off one already there); a reason that needs a manager asks for the PIN first.
  Future<void> _compLine(Line line, BuildContext anchor) async {
    if (!widget.api.connection.value.isOnline) {
      _say('Comps need a hub or the cloud, and none answers now.');
      return;
    }
    final PricingRules rules;
    try {
      rules = await widget.api.pricingRules();
    } on ApiException catch (err) {
      _say(err.message);
      return;
    }
    if (!mounted || !anchor.mounted) return;
    // the check as the screen shows it: a comp that followed an edited dish counts on the new line
    final order = _order;
    final check = order == null ? _readCheck : estimateCheck(_readCheck ?? widget.api.savedTaxes, order, _local);
    final priced = check?.line(line.lineId);
    final choice = await showCompMenu(
      anchor,
      dish: priced?.name ?? line.item,
      price: priced?.total ?? '',
      lineId: line.lineId,
      rules: rules,
      existing: check?.discounts ?? const [],
    );
    if (choice == null || !mounted) return;
    await _apply(choice);
  }

  /// Sends a discount or charge chosen from the sheet or the comp menu, after the manager's PIN when the
  /// reason needs one; a removal goes as it is.
  Future<void> _apply(Adjustment choice) async {
    if (choice.op == 'remove_discount') return _append(choice.op, choice.data);
    if (choice.op == DiscountSheet.exemptOp) return _markExempt();
    String? approval;
    if (choice.needsManager) {
      approval = await _approve(choice.label);
      if (approval == null) return;
    }
    final id = widget.outbox.newId();
    await _append(choice.op, {
      choice.op == 'discount' ? 'discount_id' : 'charge_id': id,
      ...choice.data,
      'applied_by': ?_staffName,
      'approval': ?approval,
    });
  }

  /// A manager's PIN for one adjustment on this order (or, with [purpose] `void`, one void of a sent dish);
  /// null when they walk away.
  Future<String?> _approve(String what, {String purpose = 'adjust'}) => showDialog<String>(
    context: context,
    builder: (_) => ApprovalDialog(
      api: widget.api,
      device: widget.api.settings.device,
      orderId: widget.orderId,
      what: what,
      purpose: purpose,
    ),
  );

  Future<void> _removeDiscount(CheckDiscount discount) =>
      _append('remove_discount', {'discount_id': discount.discountId});

  /// Marks the check exempt from sales tax (docs/tax-exempt.md): who it is for and the number of their
  /// certificate, typed, then a manager's PIN. The hub keeps all three with the check and takes the tax
  /// off; the sale stays in every report. What was paid was paid with the tax in it, so it comes first.
  Future<void> _markExempt() async {
    if (_order?.payments.isNotEmpty ?? false) {
      _say('Money has been taken on this check. A check is marked tax exempt before it is paid.');
      return;
    }
    final who = await showDialog<({String organisation, String certificate})>(
      context: context,
      builder: (_) => const TaxExemptDialog(),
    );
    if (who == null || !mounted) return;
    final approval = await _approve('Marking this check tax exempt', purpose: 'exempt');
    if (approval == null) return;
    await _append('set_field', {
      'tax_exempt': {'organisation': who.organisation, 'certificate': who.certificate},
      'approval': approval,
      'by': ?_staffName,
      'by_id': ?_staffId,
    });
  }

  /// Puts the sales tax back on a check marked exempt, after a word that it will be charged again. Anyone
  /// with the check open may: it only ever adds tax, and the check's history keeps who.
  Future<void> _removeExempt() async {
    final exempt = _readCheck?.exempt;
    if (exempt == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Charge sales tax again?'),
        content: Text(
          'This check is tax exempt for ${exempt.organisation}. Taking that off puts the sales tax back on it. '
          'Marking it exempt again needs a manager.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it exempt'),
          ),
          FilledButton(
            key: const ValueKey('exempt-remove'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Charge tax'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _append('set_field', {'tax_exempt': null, 'by': ?_staffName, 'by_id': ?_staffId});
  }

  /// An automatic charge (the gratuity on a large party) comes off only with a manager when the rules say
  /// so; one that staff put on comes off freely.
  Future<void> _removeCharge(CheckCharge charge) async {
    String? approval;
    if (charge.automatic) {
      final bool needsManager;
      try {
        needsManager = (await widget.api.pricingRules()).charge(charge.chargeId)?.needsManagerToRemove ?? true;
      } on ApiException catch (err) {
        _say(err.message);
        return;
      }
      if (!mounted) return;
      if (needsManager) {
        approval = await _approve('Taking off ${charge.name}');
        if (approval == null) return;
      }
    }
    await _append('remove_charge', {'charge_id': charge.chargeId, 'approval': ?approval});
  }

  /// Sends a held course (or everything) to the kitchen. Sending has two forms: stay on the check for the
  /// next round, or leave it for the next table.
  Future<void> _fire(String course, {bool leave = false}) async {
    _sentHere = true;
    await _append('fire', {'course': course});
    if (leave && mounted) Navigator.of(context).pop();
  }

  /// Whether leaving this check signs the person out: the device goes back to sign-in after sending
  /// ([Settings.signOutAfterSend], for a screen several people share) and dishes were sent from here.
  bool get _signsOutOnLeaving =>
      _sentHere && widget.api.settings.signOutAfterSend && (widget.session?.signedIn ?? false);

  /// The check was left, by whatever way (the back arrow, a send that leaves, closing it). After a send on a
  /// device that goes back to sign-in, the person is signed out: once the screen is on its way out, since
  /// signing out closes whatever is open and the navigator is busy with this very leaving.
  void _left(bool didPop, [Object? result]) {
    // left to seat a tab: the person is still at it, and is signed out once it sat down ([SeatTab])
    if (!didPop || result is SeatTab || !_signsOutOnLeaving) return;
    final session = widget.session;
    unawaited(Future.microtask(() => session?.signOut()));
  }

  /// "Seat at a table" on a bar tab: this screen closes, and the floor map comes up for the table.
  void _seatTab(Order order) => Navigator.of(context).pop(SeatTab(order, thenSignOut: _signsOutOnLeaving));

  /// The name on a bar tab, changed: the title tapped. The check's history keeps who changed it.
  Future<void> _renameTab(Order order) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TabDialog(name: order.customerName.trim()),
    );
    if (name == null || name == order.customerName || !mounted) return;
    await _append('set_field', {'customer_name': name, 'by': ?_staffName, 'by_id': ?_staffId});
  }

  /// The to-go question as the location set it (docs/to-go-question.md), read once for this screen. Null
  /// from a hub older than the question, and while nothing answers and nothing was saved: nothing is asked
  /// then, and the read is tried again the next time.
  Future<BagQuestion?> _bagQuestion() => _bagRead ??= () async {
    try {
      return await widget.api.bagQuestion();
    } on ApiException {
      _bagRead = null;
      return null;
    }
  }();

  /// Asks what goes in the bag before a to-go order is sent, once: an order that carries an answer is not
  /// asked about again. The answer goes on the order at once, so it is kept if the payment that follows is
  /// called off. False when the sheet was closed without an answer: the order is not sent.
  Future<bool> _askBag(Order order, {String action = 'Send'}) async {
    if (!order.isTakeout || order.bag != null) return true;
    final question = await _bagQuestion();
    if (!mounted) return false;
    if (question == null || !question.asks) return true;
    final answer = await askBag(context, question: question, action: action);
    if (answer == null || !mounted) return false;
    await _append('set_field', {'bag': bagField(answer), 'by': ?_staffName, 'by_id': ?_staffId});
    return mounted;
  }

  /// The answer tapped on the check: the question again, with what the order carries. Once the kitchen has
  /// the order, the hub prints the takeout station a slip about the change.
  Future<void> _changeBag(Order order) async {
    final had = order.bag ?? const <BagItem>[];
    final question = await _bagQuestion();
    if (!mounted) return;
    if (question == null) {
      _say('The hub is not answering: what goes in the bag stays as it is.');
      return;
    }
    final answer = await askBag(context, question: question, answer: had, action: 'Save');
    if (answer == null || !mounted || listEquals(answer, had)) return;
    await _append('set_field', {'bag': bagField(answer), 'by': ?_staffName, 'by_id': ?_staffId});
    if (mounted && order.isFired) _say('The takeout printer gets a slip about it.');
  }

  /// A to-go order with nothing due goes to the kitchen: its time is settled first if it is a big one.
  Future<void> _sendToGo(Order order) async {
    if (!await _askBag(order)) return;
    _sentHere = true;
    await _appendAll([
      ..._settleQuote(order),
      ('fire', {'course': '*'}),
    ]);
    if (mounted) Navigator.of(context).pop();
  }

  /// Counter mode (architecture section 12): the check is paid before the kitchen sees it, the change shows,
  /// and the screen goes back for the next customer. Where the location lets the channel pay at pickup (a
  /// phone order), the order can go to the kitchen unpaid and the ready text says so.
  Future<void> _payAndSend(Order order, Check check) async {
    if (!await _askBag(order, action: 'Next')) return;
    if (!mounted) return;
    var payAtPickup = false;
    try {
      payAtPickup = (await widget.api.quotes()).mayPayAtPickup(order.channel);
    } on ApiException {
      // nothing answers: cash and paid elsewhere need nothing from a backend
    }
    if (!mounted) return;
    // Where the order may go to the kitchen with money still to collect, a part of it can be taken now: a
    // deposit (docs/catering.md). The counter pays the whole.
    final choice = await showDialog<PayChoice>(
      context: context,
      builder: (_) => PayDialog(due: check.due, channel: order.channel, payAtPickup: payAtPickup, partial: payAtPickup),
    );
    if (choice == null || !mounted) return;
    _sentHere = true;
    await _appendAll([
      if (choice.takesMoney) _payOp(choice, check.due),
      ..._settleQuote(_order ?? order),
      ('fire', {'course': '*'}),
    ]);
    if (!mounted) return;
    await _showChange(choice, check.due);
    if (mounted) Navigator.of(context).pop();
  }

  /// The payment [choice] makes, of what it says was taken (the whole of [due] where it names no amount).
  (String, Map<String, dynamic>) _payOp(PayChoice choice, String due) => (
    'pay',
    {
      'payment_id': widget.outbox.newId(),
      'method': choice.method,
      'amount': choice.amount ?? due,
      'tendered': ?choice.tendered,
      if (choice.note.isNotEmpty) 'note': choice.note,
      'by': ?_staffName,
    },
  );

  /// The change to hand back, when more cash was handed over than was taken.
  Future<void> _showChange(PayChoice choice, String due) async {
    final change = choice.tendered == null ? 0 : cents(choice.tendered!) - cents(choice.amount ?? due);
    if (change <= 0) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Change \$${money(change)}', key: const ValueKey('change-due')),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
      ),
    );
  }

  /// Money taken on a to-go order and nothing else (docs/catering.md): a deposit on an order for a later
  /// day before it is sent, or what is still due on one the kitchen already has. Any part of what is due
  /// can be taken; the screen stays on the order.
  Future<void> _pay(Order order, Check check) async {
    final choice = await showDialog<PayChoice>(
      context: context,
      builder: (_) => PayDialog(due: check.due, channel: order.channel, partial: true, sends: false),
    );
    if (choice == null || !choice.takesMoney || !mounted) return;
    await _appendAll([_payOp(choice, check.due)]);
    if (mounted) await _showChange(choice, check.due);
  }

  /// The day and the time of an order for later, changed on the order, and on a catering order what its
  /// event needs. Only what was changed is written, each change with who made it.
  Future<void> _changeWhen(Order order) async {
    final promised = order.promisedAt;
    if (promised == null) return;
    final had = order.isCatering ? order.event : null;
    final asked = await showDialog<WhenAndEvent>(
      context: context,
      builder: (_) => WhenDialog(promised: DateTime.fromMillisecondsSinceEpoch(promised), event: had),
    );
    if (asked == null || !mounted) return;
    final was = had?.toFields() ?? const <String, dynamic>{};
    final now = asked.event?.toFields() ?? const <String, dynamic>{};
    final changed = <String, dynamic>{
      if (asked.promised.millisecondsSinceEpoch != promised) 'promised_at': asked.promised.millisecondsSinceEpoch,
      for (final MapEntry(:key, :value) in now.entries)
        if (value != was[key]) key: value,
    };
    if (changed.isEmpty) return;
    await _append('set_field', {...changed, 'by': ?_staffName, 'by_id': ?_staffId});
  }

  void _say(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// Prints the guest's bill: the check as the hub has it, so whatever was just rung in goes there first. It
  /// comes out of the printer this screen keeps for its bills, or where the location's bills print. [kept]
  /// is what to add when the screen's printer was just picked. A table that pays on several checks gets a
  /// bill for each, or the one of [check] alone.
  Future<void> _printBill({String kept = '', int? check}) async {
    if (_billing) return;
    setState(() => _billing = true);
    _changes.tell();
    try {
      await widget.outbox.flush();
      if (widget.outbox.pendingOps.any((op) => op['order_id'] == widget.orderId)) {
        if (mounted) _say('The bill prints once this check has reached the hub');
        return;
      }
      final own = widget.api.settings.billPrinter;
      final (:at, :bills) = await widget.api.printBill(widget.orderId, printer: own.isEmpty ? null : own, check: check);
      if (!mounted) return;
      final order = _order;
      final what = check != null
          ? "${order != null && splitOf(order).isEven ? 'Part' : 'Check'} $check's bill is"
          : bills > 1
          ? '$bills bills are'
          : 'The bill is';
      _say('$what printing${at.isEmpty ? '' : ' at $at'}$kept');
    } on ApiException catch (err) {
      if (!mounted) return;
      final told = err.detail?['message'] as String?;
      _say(
        told ??
            (err.status == 404 || err.status == 405
                ? 'This hub does not print bills yet: update it'
                : 'The bill did not print: nothing answered'),
      );
    } finally {
      if (mounted) {
        setState(() => _billing = false);
        _changes.tell();
      }
    }
  }

  /// Prints the order's pack sheet (docs/catering.md): the order as the hub has it, so whatever was just
  /// rung in goes there first. It comes out where to-go orders are packed.
  Future<void> _printPack() async {
    if (_packing) return;
    setState(() => _packing = true);
    try {
      await widget.outbox.flush();
      if (widget.outbox.pendingOps.any((op) => op['order_id'] == widget.orderId)) {
        if (mounted) _say('The pack sheet prints once this order has reached the hub');
        return;
      }
      final at = await widget.api.printPackSheet(widget.orderId);
      if (mounted) _say('The pack sheet is printing${at.isEmpty ? '' : ' at $at'}');
    } on ApiException catch (err) {
      if (!mounted) return;
      final told = err.detail?['message'] as String?;
      _say(
        told ??
            (err.status == 404 || err.status == 405
                ? 'This hub does not print pack sheets yet: update it'
                : 'The pack sheet did not print: nothing answered'),
      );
    } finally {
      if (mounted) setState(() => _packing = false);
    }
  }

  /// The order and its check as this screen shows them, for the split screen standing over it.
  SplitView? _view() {
    final order = _order;
    if (order == null) return null;
    return SplitView(
      order: order,
      check: estimateCheck(_readCheck ?? widget.api.savedTaxes, order, _local),
      billing: _billing,
    );
  }

  /// The Split button beside the total: how the table pays. The screen that opens works on this order
  /// through this one, so what it changes goes out and is photographed like anything else done here.
  Future<void> _openSplit() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => SplitScreen(
        changes: Listenable.merge([widget.outbox, _changes]),
        read: _view,
        onOps: _appendAll,
        onBill: (check) => _printBill(check: check),
      ),
    ),
  );

  /// The Bill button held: this bill at another printer, which the screen then keeps for its bills (on the
  /// device). The bar's screen prints at the bar, the host stand's at the front, whatever the location's
  /// own choice is.
  Future<void> _billPlace() async {
    final BillSettings? bill;
    try {
      bill = await widget.api.billSettings();
    } on ApiException {
      if (mounted) _say('The printers could not be read: nothing answered');
      return;
    }
    if (!mounted) return;
    if (bill == null || bill.printers.isEmpty) {
      _say(bill == null ? 'This hub does not print bills yet: update it' : 'No printer is set up yet');
      return;
    }
    final settings = widget.api.settings;
    final own = bill.nameOf(settings.billPrinter) == null ? '' : settings.billPrinter;
    final usual = bill.nameOf(bill.printsAt);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Print this bill at', style: Theme.of(context).textTheme.titleMedium),
              Text(
                'This screen keeps the printer you pick for its next bills.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('bill-at:'),
                    label: Text(usual == null ? "The location's printer" : "The location's: $usual"),
                    selected: own.isEmpty,
                    onSelected: (_) => Navigator.of(context).pop(''),
                  ),
                  for (final p in bill!.printers)
                    ChoiceChip(
                      key: ValueKey('bill-at:${p.id}'),
                      label: Text(p.name),
                      selected: own == p.id,
                      onSelected: (_) => Navigator.of(context).pop(p.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await settings.saveBillPrinter(picked);
    if (!mounted) return;
    await _printBill(
      kept: picked.isEmpty
          ? ". This screen's bills print where the location's do again"
          : ". This screen's bills print there from now on",
    );
  }

  /// Makes a line hold `qty` of its dish: one more from a tap on the quantity, one fewer from a tap on the
  /// bin, any number typed after holding the quantity, none after holding the bin. Before the kitchen has the
  /// line it simply changes. After, more is a new line of the extra, held until fired like any new dish; fewer
  /// or none voids it (and sends the rest again), so a VOID ticket prints and the operator says why first.
  Future<void> _setQty(Line line, int qty) async {
    var change = qtyChange(line, qty, newId: widget.outbox.newId);
    if (change.isEmpty) return;
    if (change.voidsFired) {
      final word = await _voidWord(
        what: line.item,
        title: qty == 0 ? 'Void ${line.item}?' : 'Void ${line.item} and send $qty again?',
        body: qty == 0
            ? 'It has gone to the kitchen. A VOID ticket prints so they stop making it.'
            : 'It has gone to the kitchen. A VOID ticket prints for the ${line.qty}, and a new one for $qty.',
      );
      if (word == null) return;
      change = change.voiding(word);
    }
    await _send(change, line);
  }

  /// The operator's word for voiding a dish the kitchen already has, as what goes on the void: the reason
  /// picked from the location's list, who is voiding and, where the location asks for one, a manager's
  /// approval (the PIN is checked by the hub, so that needs a backend). Null when they keep the dish, or
  /// when the void cannot be made now (a message says why). A hub older than the rule asks for nothing:
  /// the operator confirms as before ([confirm]; an edit's own sheet has already warned). [what] names what
  /// is voided to the manager: a dish, or "3 dishes" when several go on the one word.
  Future<Map<String, dynamic>?> _voidWord({
    required String what,
    required String title,
    required String body,
    bool confirm = true,
  }) async {
    final VoidRules? rules;
    try {
      rules = await widget.api.voidRules();
    } on ApiException {
      _say('Voiding a sent dish needs a hub or the cloud, and none answers now.');
      return null;
    }
    if (!mounted) return null;
    if (rules == null) {
      if (confirm && !await _confirmVoid(title: title, body: body, action: 'Void')) return null;
      return const {};
    }
    if (rules.needsManager && !widget.api.connection.value.isOnline) {
      _say("A void needs a manager's PIN, and no hub or cloud answers to check it.");
      return null;
    }
    final reason = await showDialog<VoidReason>(
      context: context,
      builder: (_) => VoidDialog(title: title, body: body, reasons: rules!.reasons),
    );
    if (reason == null || !mounted) return null;
    String? approval;
    if (rules.needsManager) {
      approval = await _approve('Voiding $what (${reason.name})', purpose: 'void');
      if (approval == null) return null;
    }
    return {'reason': reason.id, 'by': ?_staffName, 'by_id': ?_staffId, 'approval': ?approval};
  }

  /// The dishes in hand were let go over Comp or Void at the foot of the check: one reason and, where one
  /// is needed, one manager's PIN for all of them, sent as one change (so the kitchen gets one VOID ticket).
  Future<void> _lot(String target, List<Line> picked) async {
    final lines = [
      for (final line in picked)
        if (line.isActive) line,
    ];
    if (lines.isEmpty || !(_order?.isOpen ?? false)) return;
    if (target == 'comp') return _compLot(lines);
    if (target == 'void') return _voidLot(lines);
    if (target == 'move') return _moveLot(lines);
  }

  /// The lot goes to another table's check: asked which, then each dish goes over as it is, with its
  /// choices, its price and its comp, sent or not. Nothing is voided and the kitchen cooks nothing twice.
  /// Walking away from the question keeps every dish here.
  Future<void> _moveLot(List<Line> lines) async {
    final FloorPlan plan;
    try {
      plan = await widget.api.floor();
    } on ApiException {
      _say('The tables cannot be read right now, so the dishes stay here.');
      return;
    }
    final order = _order;
    if (!mounted || order == null) return;
    if (CheckPicker.places(plan, widget.orderId).isEmpty) {
      _say('No other table has a check to move them to.');
      return;
    }
    final what = lines.length == 1 ? lines.single.item : dishes(lines.length);
    final to = await showModalBottomSheet<(TableSpot, TableCheck)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Move $what to', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                CheckPicker(
                  plan: plan,
                  except: widget.orderId,
                  onPicked: (table, check) => Navigator.of(context).pop((table, check)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (to == null || !mounted) return;
    final (table, check) = to;
    final ops = moveLinesOps(
      from: order,
      onto: check.orderId,
      lines: lines,
      newId: widget.outbox.newId,
      by: widget.session?.staff,
    );
    for (final (orderId, batch) in ops) {
      await widget.outbox.addAll(orderId, batch);
    }
    if (mounted) _say('$what moved to table ${table.label}');
  }

  /// Voids the lot. The dishes the kitchen has take the operator's word, once for all of them; the ones it
  /// has not seen come off with nothing asked, as from the bin. Walking away from the word keeps every dish.
  Future<void> _voidLot(List<Line> lines) async {
    final sent = [
      for (final line in lines)
        if (line.fired) line,
    ];
    var word = const <String, dynamic>{};
    if (sent.isNotEmpty) {
      final what = sent.length == 1 ? sent.single.item : dishes(sent.length);
      final unsent = lines.length - sent.length;
      final said = await _voidWord(
        what: what,
        title: 'Void $what?',
        body: [
          if (sent.length > 1) '${[for (final line in sent) '${line.qty} × ${line.item}'].join(', ')}.',
          sent.length == 1
              ? 'It has gone to the kitchen. A VOID ticket prints so they stop making it.'
              : 'They have gone to the kitchen. A VOID ticket prints so they stop making them.',
          if (unsent == 1) 'The other dish was not sent and just comes off.',
          if (unsent > 1) 'The other $unsent were not sent and just come off.',
        ].join(' '),
      );
      if (said == null) return;
      word = said;
    }
    await _appendAll([
      for (final line in lines)
        ...(line.fired
                ? qtyChange(line, 0, newId: widget.outbox.newId).voiding(word)
                : qtyChange(line, 0, newId: widget.outbox.newId))
            .ops,
    ]);
  }

  /// Comps the lot: the reasons the rules allow on an item, one picked for all of them, then the manager's
  /// PIN once when that reason needs it. Each dish gets its own discount, as if comped one by one.
  Future<void> _compLot(List<Line> lines) async {
    if (!widget.api.connection.value.isOnline) {
      _say('Comps need a hub or the cloud, and none answers now.');
      return;
    }
    final PricingRules rules;
    try {
      rules = await widget.api.pricingRules();
    } on ApiException catch (err) {
      _say(err.message);
      return;
    }
    if (!mounted) return;
    final order = _order;
    final check = order == null ? _readCheck : estimateCheck(_readCheck ?? widget.api.savedTaxes, order, _local);
    final chosen = await showDialog<LotComp>(
      context: context,
      builder: (_) => LotCompDialog(
        lot: [
          for (final line in lines)
            (
              lineId: line.lineId,
              qty: line.qty,
              name: check?.line(line.lineId)?.name ?? line.item,
              total: check?.line(line.lineId)?.total ?? '',
            ),
        ],
        choices: lotChoices(rules, check?.discounts ?? const [], [for (final line in lines) line.lineId]),
      ),
    );
    if (chosen == null || !mounted) return;
    String? approval;
    if (chosen.rule.needsManager) {
      approval = await _approve('${chosen.rule.name} on ${dishes(chosen.lineIds.length)}');
      if (approval == null) return;
    }
    await _appendAll([
      for (final discount in chosen.discounts)
        (
          'discount',
          {'discount_id': widget.outbox.newId(), ...discount, 'applied_by': ?_staffName, 'approval': ?approval},
        ),
    ]);
  }

  /// Delete or Backspace on a dish of the menu: one of it comes off the check, the opposite of the Enter that
  /// adds one. A line the kitchen has not seen goes first, the one added last (one fewer of it, off the check
  /// at one). Once every one of that dish has been sent, the last is voided, after the operator's word like
  /// any void. A dish that is not on the check: nothing happens.
  Future<void> _takeOff(MenuEntry entry) async {
    final order = _order;
    if (order == null || !order.isOpen) return;
    final lines = [
      for (final line in order.activeLines)
        if (_lineMatchesEntry(line, entry)) line,
    ];
    if (lines.isEmpty) return;
    final line = lines.lastWhere((l) => !l.fired, orElse: () => lines.last);
    await _setQty(line, line.qty - 1);
  }

  /// Lines dragged on the check: to another place in a course, or under another course. A dish the kitchen
  /// already has moves like any other and keeps its place on the ticket it went out on: nothing is voided.
  Future<void> _move(Drop drop) async {
    final ops = [
      for (var i = 0; i < drop.lines.length; i++)
        ...moveChange(drop.lines[i], course: drop.course, rank: drop.ranks[i]).ops,
    ];
    if (ops.isEmpty) return;
    await _appendAll(ops);
  }

  /// Sends a change; the line it adds, if any, is priced like the line it copies and scrolled into view.
  Future<void> _send(LineChange change, Line line) async {
    final copy = change.newLineId;
    if (copy != null) {
      _local[copy] = _localFor(line);
      _lastAdded = copy;
    }
    await _appendAll(change.ops);
  }

  /// A VOID ticket is about to print: the operator's word first.
  Future<bool> _confirmVoid({required String title, required String body, required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          // with a keyboard, Enter keeps the dish: voiding it takes a deliberate step over to Void
          TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// What this screen knows of a line, to price a copy of it before the backend does.
  LocalLine _localFor(Line line) {
    final known = _local[line.lineId];
    if (known != null) return known;
    final priced = _readCheck?.line(line.lineId);
    return LocalLine(
      unitPrice: priced == null || priced.qty == 0 ? null : money(cents(priced.total) ~/ priced.qty),
      modifiers: priced?.modifiers ?? const [],
      itemId: line.itemId,
      entryId: line.entryId,
      zhName: line.zhName,
    );
  }

  Future<void> _typeQty(Line line) async {
    final qty = await showDialog<int>(
      context: context,
      builder: (_) => _QtyDialog(name: line.item, qty: line.qty),
    );
    if (qty != null) await _setQty(line, qty);
  }

  /// Reopens a line's choices. The changed dish replaces the old one: an unfired line just comes off, a
  /// fired one is voided and the new one fired with it, so the kitchen gets both on one ticket. The new
  /// line says which line it replaces, so a comp on the old one follows it (nobody approves it again).
  /// Fewer of a sent dish on the way is a void of the difference, with the operator's word like any void.
  Future<void> _edit(Line line) async {
    final itemId = line.itemId ?? _local[line.lineId]?.itemId;
    final entryId = line.entryId ?? _local[line.lineId]?.entryId;
    if (!line.isActive || line.request == null || itemId == null) {
      _say('This line has no menu choices to change. Remove it and add it again.');
      return;
    }
    final ItemDetail detail;
    try {
      detail = await widget.api.item(itemId, entryId: entryId);
    } on ApiException catch (err) {
      _say('Could not open the dish: $err');
      return;
    }
    if (!mounted) return;
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(
        api: widget.api,
        entry: MenuEntry.fromDetail(detail, entryId: entryId),
        initial: ChosenLine(name: line.item, request: line.request!, qty: line.qty, note: line.note),
        warning: line.fired ? 'Already sent to the kitchen: updating voids it and fires the new one.' : null,
      ),
    );
    if (chosen == null || !mounted) return;
    var word = const <String, dynamic>{};
    if (line.fired && chosen.qty < line.qty) {
      final said = await _voidWord(
        what: line.item,
        title: 'Void ${line.qty - chosen.qty} of the ${line.qty} ${line.item}?',
        body:
            'They have gone to the kitchen. A VOID ticket prints for the ${line.qty}, and a new one for ${chosen.qty}.',
        confirm: false,
      );
      if (said == null) return;
      word = said;
    }
    await _appendAll([
      ('void_line', {'line_id': line.lineId, 'reason': 'changed', ...word}),
      ('add_line', _lineData(chosen, seat: line.seat, course: line.course, replaces: line.lineId)),
      if (line.fired) ('fire', {'course': line.course ?? '*'}),
    ]);
  }

  /// The party size, or more when a dish is on a higher seat.
  int _seats(Order? order) {
    var seats = (order?.fields['guests'] as int?) ?? 0;
    for (final line in order?.activeLines ?? const <Line>[]) {
      if ((line.seat ?? 0) > seats) seats = line.seat!;
    }
    for (final told in order?.allergies ?? const <Allergy>[]) {
      if ((told.seat ?? 0) > seats) seats = told.seat!; // a seat with an allergy never drops out of sight
    }
    return seats;
  }

  bool _lineMatchesEntry(Line line, MenuEntry entry) {
    final local = _local[line.lineId];
    final lineEntryId = line.entryId ?? line.request?.entryId ?? local?.entryId;
    if (lineEntryId != null && lineEntryId.isNotEmpty && entry.entryId.isNotEmpty) {
      return lineEntryId == entry.entryId;
    }
    final lineItemId = line.itemId ?? local?.itemId;
    if (lineItemId != null && lineItemId.isNotEmpty && entry.item.isNotEmpty) {
      return lineItemId == entry.item;
    }
    final variantId = line.request?.variantId;
    if (variantId != null && variantId.isNotEmpty && entry.variants.isNotEmpty) {
      return entry.variants.any((v) => v.variantId == variantId);
    }
    return line.item == entry.name || line.item.startsWith('${entry.name} (');
  }

  /// Total quantity of `entry` across all active lines on the check.
  int _entryQty(Order? order, MenuEntry entry) {
    if (order == null) return 0;
    var total = 0;
    for (final line in order.activeLines) {
      if (_lineMatchesEntry(line, entry)) total += line.qty;
    }
    return total;
  }

  /// Seats are the order's party size, so every screen on the order shows the same ones. A seat comes off
  /// only from the end, and only once its dishes are off it or moved.
  Future<void> _setSeats(Order? order, int seats) async {
    if (order == null || seats < 0) return;
    final current = _seats(order);
    if (seats < current) {
      final left = order.activeLines.where((l) => l.seat == current).length;
      if (left > 0) {
        _say(
          'Seat $current still has ${left == 1 ? 'a dish' : '$left dishes'}. Take ${left == 1 ? 'it' : 'them'} off first.',
        );
        return;
      }
      if (order.allergies.any((a) => a.seat == current)) {
        _say('Seat $current has an allergy noted. Take the allergy off first.');
        return;
      }
    }
    setState(() {
      if (seats > current) {
        _seat = seats;
      } else if ((_seat ?? 0) > seats) {
        _seat = seats == 0 ? null : seats;
      }
    });
    await _append('set_field', {'guests': seats});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final order = _order;
    // With no check from a backend yet (a check opened while nothing answers), the tax comes from the rates
    // the last priced check carried, and the total shows as an estimate until a backend prices it.
    final check = order == null ? null : estimateCheck(_readCheck ?? widget.api.savedTaxes, order, _local);
    final open = order?.isOpen ?? true;
    final seats = _seats(order);
    final told = order?.allergies ?? const <Allergy>[];
    // offered once the hub has said what the menu names (a hub older than allergies never does)
    final allergyChip = order == null || _allergens == null
        ? null
        : _AllergyChip(noted: told.isNotEmpty, onTap: () => _noteAllergy(order));
    final ticket = _TicketPanel(
      order: order,
      check: check,
      open: open,
      allergenNames: _allergenNames,
      coursing: widget.coursing,
      lastAdded: _lastAdded,
      now: widget.now ?? _deviceNow,
      zhNameOf: (line) => line.zhName ?? _local[line.lineId]?.zhName,
      onEdit: _edit,
      onQty: _setQty,
      onTypeQty: _typeQty,
      onComp: _compLine,
      onRemoveDiscount: _removeDiscount,
      onRemoveCharge: _removeCharge,
      onRemoveExempt: _removeExempt,
      onBag: order == null ? null : () => _changeBag(order),
      onMove: _move,
      onLot: _lot,
      onBill: _billing ? null : _printBill,
      onBillPlace: _billPlace,
      onSplit: _openSplit,
      // Money alone on a to-go order: a deposit on one for later before it is sent, or what is still due
      // on one the kitchen has. An order for now that was not sent is paid as it is sent ("Pay & send").
      onPay:
          order != null &&
              check != null &&
              open &&
              order.isTakeout &&
              check.lines.isNotEmpty &&
              cents(check.due) > 0 &&
              (order.heldCourses.isEmpty || order.forLater)
          ? () => _pay(order, check)
          : null,
    );
    final menu = open
        ? Column(
            children: [
              // a table's seats and courses; a to-go order has neither, and its bar is the Allergy chip alone;
              // a bar tab has courses and no seats yet, and the way to a table instead
              if (order?.isTakeout != true || allergyChip != null)
                _SeatCourseBar(
                  seated: order?.isTakeout != true,
                  onSeatTab: order != null && order.isTab ? () => _seatTab(order) : null,
                  allergy: allergyChip,
                  allergic: {for (final a in told) a.seat ?? 0},
                  seats: seats,
                  seat: _seat,
                  course: _course,
                  courses: widget.coursing.active,
                  onSeat: (seat) => setState(() => _seat = seat),
                  onAddSeat: () => _setSeats(order, seats + 1),
                  onRemoveSeat: () => _setSeats(order, seats - 1),
                  onCourse: (course) => setState(() => _course = course),
                ),
              Expanded(
                child: MenuPanel(
                  api: widget.api,
                  onChosen: _add,
                  qtyOf: (entry) => _entryQty(order, entry),
                  onRemove: _takeOff,
                  by: _staffName,
                ),
              ),
            ],
          )
        : Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 36, color: scheme.outline),
                const SizedBox(height: 12),
                const Text('This check is closed. Reopen it to add items.'),
              ],
            ),
          );
    // Leaving is noticed whichever way it happens, for a device that goes back to sign-in after sending.
    return PopScope(
      onPopInvokedWithResult: (didPop, result) => _left(didPop, result),
      child: Scaffold(
        appBar: AppBar(
          // The title held opens the check's history: a phone's bar has no room for one more button, and
          // would cut the check's name short to fit one.
          // A bar tab's title tapped changes the name on it.
          title: GestureDetector(
            key: const ValueKey('order-title'),
            onTap: order != null && open && order.isTab ? () => _renameTab(order) : null,
            onLongPress: order == null ? null : _history,
            child: Text(
              order == null
                  ? 'Order'
                  : order.isTakeout
                  ? _takeoutTitle(order, _readyAt(order))
                  : order.isTab
                  // an open tab is its name alone: a phone's bar cuts a long title short, and the name is
                  // what the tab is known by
                  ? (open ? order.tabLabel : '${order.tabLabel} · ${order.status}')
                  : 'Table ${order.table} · ${order.status}',
            ),
          ),
          actions: [
            StatusIcon(api: widget.api, outbox: widget.outbox, phone: widget.phone),
            if (order != null && open && !order.isTakeout)
              _FireMenu(
                order: order,
                coursing: widget.coursing,
                onFire: _fire,
                signsOut: widget.api.settings.signOutAfterSend && (widget.session?.signedIn ?? false),
              ),
            // Counter mode: pay first, then everything goes to the kitchen at once and the screen comes back.
            if (order != null && open && order.isTakeout && order.heldCourses.isNotEmpty)
              check != null && cents(check.due) > 0
                  ? _Action('Pay & send', Icons.point_of_sale, () => _payAndSend(order, check))
                  : _Action('Send', Icons.send, () => _sendToGo(order)),
            if (order != null && open) _Action('Discount', Icons.percent, _discount),
            if (order != null && open) _Action('Close', Icons.check, () => _append('close')),
            if (order != null && order.status == 'closed') _Action('Reopen', Icons.undo, () => _append('reopen')),
            // Where the bar has room for it: a phone holds the title instead.
            if (order != null && !compact(context)) _Action('History', Icons.history, _history),
          ],
        ),
        body: Column(
          children: [
            CaptureBanner(api: widget.api, outbox: widget.outbox),
            // what the guests cannot have, over the check and the menu alike: on a phone they are two tabs
            if (order != null && told.isNotEmpty)
              _AllergyStrip(
                words: allergySummary(told, _allergenNames, seated: order.hasTable),
                onTap: open && _allergens != null ? () => _noteAllergy(order) : null,
              ),
            if (order != null && _customerNote.isNotEmpty) _CustomerStrip(note: _customerNote),
            // an order for later says its day and time, and a catering order what its event needs; a tap
            // changes them
            if (order != null && order.isTakeout && order.forLater && order.promisedAt != null)
              _WhenStrip(
                order: order,
                onTap: open ? () => _changeWhen(order) : null,
                onPack: order.activeLines.isEmpty || _packing ? null : _printPack,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 720) {
                    // Mac and iPad: the check on the left, the menu on the right.
                    return Row(
                      children: [
                        SizedBox(width: constraints.maxWidth * 0.38, child: ticket),
                        const VerticalDivider(width: 1),
                        Expanded(child: menu),
                      ],
                    );
                  }
                  // iPhone: the check and the menu as two tabs.
                  return DefaultTabController(
                    length: 2,
                    initialIndex: 1,
                    child: Column(
                      children: [
                        TabBar(
                          tabs: [
                            Tab(text: 'Check ${check == null ? '' : '\$${check.total}'}'),
                            const Tab(text: 'Menu'),
                          ],
                        ),
                        Expanded(child: TabBarView(children: [ticket, menu])),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int _deviceNow() => DateTime.now().millisecondsSinceEpoch;

/// The lines on the check with their prices, and the totals the backend computed. The line added last
/// scrolls into view, so the operator sees what the last tap did.
class _TicketPanel extends StatefulWidget {
  const _TicketPanel({
    required this.order,
    required this.check,
    required this.open,
    required this.coursing,
    required this.lastAdded,
    required this.now,
    required this.zhNameOf,
    this.allergenNames = const {},
    required this.onEdit,
    required this.onQty,
    required this.onTypeQty,
    required this.onComp,
    required this.onRemoveDiscount,
    required this.onRemoveCharge,
    required this.onRemoveExempt,
    required this.onBag,
    required this.onMove,
    required this.onLot,
    required this.onBill,
    required this.onBillPlace,
    required this.onSplit,
    this.onPay,
  });

  final Order? order;
  final Check? check;
  final bool open;
  final Coursing coursing;
  final String? lastAdded;

  /// Takes money on the order: the Pay button on what is due. Null where there is none.
  final VoidCallback? onPay;

  /// What time it is, in milliseconds: an open check says how long ago its dishes were sent.
  final int Function() now;

  /// A line's dish in Chinese, where the menu names it so: what the check calls it for a person who reads
  /// dish names in Chinese (docs/dish-names.md). From the hub's own record of the line, or, until the hub
  /// has answered, from what the menu showed when the dish was rung.
  final String? Function(Line line) zhNameOf;

  /// The menu's allergens by code, to name what a marked dish contains.
  final Map<String, String> allergenNames;
  final ValueChanged<Line> onEdit;

  /// Makes a line hold [qty]; done once the change is on its way (after the operator's word, for a void).
  final Future<void> Function(Line line, int qty) onQty;
  final ValueChanged<Line> onTypeQty;

  /// The price of a line held: the comp menu opens at [anchor], the price's own context.
  final void Function(Line line, BuildContext anchor) onComp;
  final ValueChanged<CheckDiscount> onRemoveDiscount;
  final ValueChanged<CheckCharge> onRemoveCharge;

  /// Puts the tax back on a check a manager marked tax exempt.
  final VoidCallback onRemoveExempt;

  /// Asks again what goes in the bag of a to-go order: the answer's row tapped.
  final VoidCallback? onBag;

  /// Lines let go at another place or course on the check.
  final Future<void> Function(Drop drop) onMove;

  /// The dishes in hand were let go over a place at the foot of the check: `comp` or `void`.
  final Future<void> Function(String target, List<Line> lines) onLot;

  /// Prints the guest's bill; null while one is on its way. A hold picks the printer this screen's bills
  /// come out of ([onBillPlace]).
  final VoidCallback? onBill;
  final VoidCallback onBillPlace;

  /// Opens the split screen: how the table pays.
  final VoidCallback onSplit;

  @override
  State<_TicketPanel> createState() => _TicketPanelState();
}

class _TicketPanelState extends State<_TicketPanel> {
  final _keys = <String, GlobalKey>{};
  final _focus = <String, FocusNode>{}; // each line's own: which line a key was pressed on, and where to next
  List<CheckRow>? _rows; // where lines let go show until their move lands
  List<CheckRow> _built = const []; // the rows as last laid out
  Placed _placed = Placed.none; // which check each dish is on, while the table pays on several

  // The minute it is now, for "23 min ago" beside a sent time. Only the words that say it listen, and they
  // hear of it once a minute: the check itself is not rebuilt as time passes.
  late final ValueNotifier<int> _minute = ValueNotifier(_minuteNow());
  Timer? _minuteTimer;

  int _minuteNow() => widget.now() ~/ Duration.millisecondsPerMinute * Duration.millisecondsPerMinute;

  @override
  void dispose() {
    _minuteTimer?.cancel();
    _minute.dispose();
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Delete or Backspace with the keyboard's focus on a line (the line itself, or its quantity, price or
  /// bin): the line comes off the check, all of it, as a hold on its bin takes it off. A line the kitchen
  /// has is voided, after the operator's word.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.backspace && key != LogicalKeyboardKey.delete) return KeyEventResult.ignored;
    final focused = _focus.entries.where((e) => e.value.hasFocus).firstOrNull?.key;
    final line = widget.order?.lines.where((l) => l.lineId == focused && l.isActive).firstOrNull;
    if (line == null || !widget.open) return KeyEventResult.ignored;
    // one press, one line: a key held down does not empty the check
    if (event is KeyDownEvent) unawaited(_removeWithKey(line));
    return KeyEventResult.handled;
  }

  /// Whether a line's row is built: one that scrolled away keeps its old context, so only a mounted one counts.
  static bool _onScreen(FocusNode node) => node.context?.mounted ?? false;

  /// Takes [line] off, then hands the focus to the line after it (the one before it, for the last line), so
  /// the next press takes the next line. A line that stayed (the operator kept it) keeps the focus.
  Future<void> _removeWithKey(Line line) async {
    final ids = [
      for (final row in _built)
        if (row is LineRow && row.line.isActive) row.line.lineId,
    ];
    final at = ids.indexOf(line.lineId);
    await widget.onQty(line, 0);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // still there and still a line that takes keys: it was kept. (Whether it has the focus says nothing
      // yet: a line that just turned void gives the focus up only after this frame.)
      final own = _focus[line.lineId];
      if (own != null && _onScreen(own) && own.canRequestFocus) return;
      for (final id in [...ids.skip(at + 1), ...ids.take(math.max(0, at)).toList().reversed]) {
        final next = _focus[id];
        if (next != null && _onScreen(next) && next.canRequestFocus) {
          next.requestFocus();
          return;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    _minuteTimer = Timer.periodic(const Duration(seconds: 5), (_) => _minute.value = _minuteNow());
    _showLastAdded(); // the phone's Check tab opens on it too
  }

  @override
  void didUpdateWidget(_TicketPanel old) {
    super.didUpdateWidget(old);
    if (widget.lastAdded != old.lastAdded) _showLastAdded();
  }

  void _showLastAdded() {
    final id = widget.lastAdded;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final line = _keys[id]?.currentContext;
      if (!mounted || line == null) return;
      Scrollable.ensureVisible(
        line,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final open = widget.open;
    final scheme = Theme.of(context).colorScheme;
    final posColors = PosColors.of(context);
    if (order == null) return const Center(child: CircularProgressIndicator());
    if (order.shownLines.isEmpty) {
      return Material(
        color: posColors.checkPaper,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_outlined, size: 34, color: scheme.outline),
              const SizedBox(height: 10),
              const Text('Nothing ordered yet.'),
            ],
          ),
        ),
      );
    }
    final shown = {for (final l in order.shownLines) l.lineId};
    _keys.removeWhere((id, _) => !shown.contains(id));
    final gone = [
      for (final id in _focus.keys)
        if (!shown.contains(id)) id,
    ];
    if (gone.isNotEmpty) {
      // once their rows have left the screen
      final nodes = [for (final id in gone) _focus.remove(id)!];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in nodes) {
          node.dispose();
        }
      });
    }
    final check = widget.check;
    final rows = _built = _rows ?? checkRows(order, widget.coursing);
    _placed = placedOn(order);
    final checks = checksOf(order);
    return Material(
      color: posColors.checkPaper,
      child: Column(
        children: [
          Expanded(
            // Every row is built (a check is short), so the line added last exists to scroll to. A line is
            // held by its dish and carried to another place, or under another course's header; other lines
            // tapped while it is held stack under it and go along.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onKeyEvent: _onKey,
              child: CheckList(
                key: const ValueKey('check-rows'),
                rows: rows,
                paper: posColors.checkPaper,
                onDrop: _dropped,
                targets: open ? (inHand) => _lotTargets(inHand, moves: check?.moves ?? false) : null,
                onTarget: (target, lines) => unawaited(widget.onLot(target, lines)),
                rowBuilder: (context, i, row, drag) => switch (row) {
                  CourseRow(:final id, :final name, :final state, :final sentMs) => _CourseHeader(
                    key: ValueKey('course-row:$id'),
                    id: id,
                    name: name,
                    state: state,
                    sentMs: sentMs,
                    minute: open ? _minute : null,
                  ),
                  final LineRow row => _lineTile(context, i, row, drag),
                },
              ),
            ),
          ),
          if (check != null)
            Container(
              decoration: BoxDecoration(
                color: posColors.checkFooter,
                border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1.5)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Column(
                children: [
                  // a to-go order's answer to what goes in the bag, under its dishes; a tap asks again
                  if (order.bag case final bag? when order.isTakeout)
                    _BagRow(key: const ValueKey('bag-row'), items: bag, onTap: open ? widget.onBag : null),
                  _TotalRow('Subtotal', check.subtotal),
                  // Each discount and charge is its own row; a tap takes it off (a manager's PIN when the
                  // rules ask for one). The receipt shows them the same way.
                  for (final d in check.discounts)
                    _TotalRow(
                      _discountLabel(d, check),
                      inParens(d.amount),
                      key: ValueKey('discount-${d.discountId}'),
                      onTap: open ? () => widget.onRemoveDiscount(d) : null,
                    ),
                  for (final c in check.charges)
                    _TotalRow(
                      c.name,
                      c.amount,
                      key: ValueKey('charge-${c.chargeId}'),
                      onTap: open ? () => widget.onRemoveCharge(c) : null,
                    ),
                  const SizedBox(height: 2),
                  // a check a manager marked tax exempt says for whom where its tax was; a tap charges it again
                  if (check.exempt case final exempt?)
                    _TotalRow(
                      'Tax exempt · ${exempt.organisation}',
                      check.tax,
                      key: const ValueKey('tax-exempt-row'),
                      onTap: open ? widget.onRemoveExempt : null,
                    )
                  else
                    _TotalRow('Sales tax ${_rate(check.taxRatePct)}%', check.tax),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
                  _TotalFoot(
                    label: check.estimated ? 'Total (updating)' : 'Total',
                    amount: check.total,
                    // how the table pays, once the hub knows of splitting; then the bill
                    checks: checks,
                    onSplit: check.splits && (open || checks > 1) ? widget.onSplit : null,
                    onBill: widget.onBill,
                    onBillPlace: widget.onBillPlace,
                    buttons: check.lines.isNotEmpty,
                  ),
                  for (final p in order.payments)
                    _TotalRow(_paymentLabel(p), '−${p.amount}', key: ValueKey('paid-${p.paymentId}')),
                  if (order.payments.isNotEmpty || widget.onPay != null)
                    _TotalRow(
                      'Due',
                      check.due,
                      strong: true,
                      key: const ValueKey('due'),
                      action: widget.onPay == null ? null : _PayButton(onTap: widget.onPay!),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A line: its quantity and seat, the dish with its price (choices included; with a comp or discount on
  /// it, the old price struck through over the new one), and the bin. Under the dish, a line for each of its
  /// choices with what it changes ("+0.50"), then each comp or discount with what it took off, "(30.00)",
  /// then the line's state. Held by the dish, it lifts into the hand and can be carried to another place or
  /// course (the quantity, the price and the bin keep their own tap and hold: the price held opens the comp
  /// menu). While a dish is in hand, a tap on a line picks it up to go along, and a tap on a line in the
  /// stack puts it back.
  Widget _lineTile(BuildContext context, int index, LineRow row, CheckDrag? drag) {
    final line = row.line;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final posColors = PosColors.of(context);
    final priced = widget.check?.line(line.lineId);
    // the dish in the language of whoever is at the screen; the record, the bill and the reports keep one name
    final zhName = DishLanguage.chineseOf(context) ? widget.zhNameOf(line) : null;
    final comps = [
      for (final d in widget.check?.discounts ?? const <CheckDiscount>[])
        if (d.lineId == line.lineId) d,
    ];
    final changeable = widget.open && line.isActive;
    final held = drag != null; // a dish is in hand
    final isLatest = line.lineId == widget.lastAdded;
    Widget holdable(Widget child) => changeable && !held
        ? HoldToDrag(
            index: index,
            child: SizedBox(width: double.infinity, child: child),
          )
        : child;
    final on = _placed.isSplit && line.isActive ? _placed.on[line.lineId] : null;
    final sentAt = row.sentMs; // a dish that went later than its course's header says: it says its own time
    List<String> wordsAt(int? now) => [
      // on a split table: the check the dish is on, or the checks it is shared between
      if (on != null) on.length == 1 ? 'check ${on.single}' : 'shared by checks ${on.join(', ')}',
      if (line.isVoid) line.voidReason.isEmpty ? 'void' : 'void · ${line.voidReason}',
      if (line.isActive && !line.fired && row.courseState != 'held') 'not sent yet',
      if (sentAt != null) sentWords(sentAt, nowMs: now),
      if (line.isActive && line.modifiedAfterFire) 'added after fire',
      if (line.note.isNotEmpty) line.note,
      // a dish someone other than the order's server added, with hands-free switching
      if (line.by.isNotEmpty && line.byId != widget.order?.fields['server_id']) 'by ${line.by}',
    ];
    final words = wordsAt(null);
    final below = <Widget>[
      // first, in red: the menu says the dish has in it what its seat (or the table) cannot have
      if (line.isActive && line.allergy.isNotEmpty)
        _SubLine(
          'ALLERGY: ${containsWords(line.allergy, widget.allergenNames)}',
          key: ValueKey('allergy-mark:${line.lineId}'),
          alert: true,
        ),
      // each choice on its own line, with what it changes when it changes anything
      for (final m in priced?.modifiers ?? const <CheckModifier>[])
        _SubLine(m.label, amount: m.charged ? priceChange(m.amount) : null, depth: m.depth),
      // then each comp or discount on the line (they come off after every choice), with what it took off
      for (final d in comps) _SubLine(compLabel(d), amount: inParens(d.amount)),
      if (sentAt != null && widget.open)
        // how long ago moves on with the minute: these words alone are built again
        ValueListenableBuilder<int>(
          valueListenable: _minute,
          builder: (context, now, _) => _SubLine(wordsAt(now).join(' · '), key: ValueKey('sent:${line.lineId}')),
        )
      else if (words.isNotEmpty)
        _SubLine(words.join(' · '), key: sentAt == null ? null : ValueKey('sent:${line.lineId}')),
    ];
    final tile = ListTile(
      key: _keys.putIfAbsent(line.lineId, GlobalKey.new),
      focusNode: _focus.putIfAbsent(line.lineId, () => FocusNode(debugLabel: 'line ${line.lineId}')),
      dense: true,
      onTap: !changeable
          ? null
          : held
          ? () => drag.toggle(line.lineId)
          : () => widget.onEdit(line),
      leading: _Hold(
        key: ValueKey('qty-${line.lineId}'),
        tooltip: 'Tap for one more, hold to type how many',
        onTap: changeable && !held ? () => widget.onQty(line, line.qty + 1) : null,
        onLongPress: changeable && !held ? () => widget.onTypeQty(line) : null,
        // the sync mark has its own fixed slot on the far left, so nothing moves when it shows
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              child: line.pending
                  ? Icon(
                      Icons.cloud_upload_outlined,
                      key: ValueKey('sending-${line.lineId}'),
                      size: 12,
                      color: scheme.primary,
                    )
                  : null,
            ),
            SizedBox(
              width: 40,
              height: 34,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: line.isVoid ? scheme.surfaceContainerHighest : scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${line.qty}×',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: PosTheme.tabular,
                          ),
                        ),
                        Text(
                          line.seat == null ? 'table' : 'seat ${line.seat}',
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: holdable(
              Text(
                zhName ?? priced?.name ?? line.item,
                style: line.isVoid
                    ? TextStyle(decoration: TextDecoration.lineThrough, color: scheme.onSurfaceVariant)
                    : theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // the dish's price with its choices (what each changes lines up under it), in a fixed width so a
          // longer price does not push the name onto another line; held, the price opens the comp menu
          // (tapped, it opens the dish like the rest of the line)
          SizedBox(
            width: _amountWidth,
            child: Builder(
              builder: (anchor) => _Hold(
                key: ValueKey('price-${line.lineId}'),
                tooltip: 'Hold to comp',
                onTap: changeable && !held ? () => widget.onEdit(line) : null,
                onLongPress: changeable && !held ? () => widget.onComp(line, anchor) : null,
                child: _Price(total: priced?.total, discount: priced?.discount),
              ),
            ),
          ),
        ],
      ),
      subtitle: below.isEmpty
          ? null
          : holdable(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: below)),
      trailing: !changeable
          ? null
          : _Hold(
              key: ValueKey('bin-${line.lineId}'),
              tooltip: line.qty > 1
                  ? 'Tap for one fewer, hold to take them all off'
                  : (line.fired ? 'Void (sent to the kitchen)' : 'Remove'),
              onTap: held ? null : () => widget.onQty(line, line.qty - 1),
              onLongPress: held ? null : () => widget.onQty(line, 0),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  line.fired ? Icons.block : Icons.delete_outline,
                  size: 20,
                  color: line.fired ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ),
    );
    if (!isLatest) return tile;
    return TweenAnimationBuilder<Color?>(
      key: ValueKey('flash-${line.lineId}'),
      tween: ColorTween(begin: posColors.highlightFlash, end: posColors.checkPaper),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, color, child) => Material(color: color ?? posColors.checkPaper, child: child),
      child: tile,
    );
  }

  /// Where the dishes in hand can be let go instead of put back down: over Move (to another table's check,
  /// on a hub that [moves] dishes), over Comp, or over Void ("Take off" while the kitchen has seen none of
  /// them). With several in hand each says how many it takes.
  static List<LotTarget> _lotTargets(List<Line> inHand, {bool moves = false}) {
    final count = inHand.length == 1 ? '' : ' ${inHand.length}';
    final sent = inHand.any((line) => line.fired);
    return [
      if (moves) LotTarget(id: 'move', label: 'Move$count', icon: Icons.open_with_rounded, plain: true),
      LotTarget(id: 'comp', label: 'Comp$count', icon: Icons.card_giftcard_outlined),
      LotTarget(
        id: 'void',
        label: '${sent ? 'Void' : 'Take off'}$count',
        icon: sent ? Icons.block : Icons.delete_outline,
        danger: true,
      ),
    ];
  }

  /// The stack has come down: the check shows its lines there while their move is sent.
  Future<void> _dropped(Drop drop) async {
    final rows = _built;
    final moving = {for (final line in drop.lines) line.lineId};
    final byId = {
      for (final row in rows)
        if (row is LineRow) row.line.lineId: row,
    };
    final shown = [
      for (final row in rows)
        if (row is! LineRow || !moving.contains(row.line.lineId)) row,
    ];
    shown.insertAll(drop.at.clamp(0, shown.length), [for (final line in drop.lines) ?byId[line.lineId]]);
    setState(() => _rows = shown);
    try {
      await widget.onMove(drop);
    } finally {
      if (mounted) setState(() => _rows = null);
    }
  }
}

/// An app bar button: icon and label, or the icon alone on a phone.
class _Action extends StatelessWidget {
  const _Action(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => compact(context)
      ? IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon))
      : TextButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label));
}

/// The width of the check's price column: the dish's price, and under it what each choice changes and what
/// a comp took off, all lined up.
const _amountWidth = 60.0;

/// A line's price: what it costs with its choices, or, with a comp or discount on it, that struck through
/// over what it costs now.
class _Price extends StatelessWidget {
  const _Price({required this.total, required this.discount});

  final String? total;
  final String? discount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: PosTheme.tabular);
    final total = this.total;
    final off = discount == null ? 0 : cents(discount!);
    if (total == null || off == 0) {
      return Text(total ?? '', textAlign: TextAlign.end, maxLines: 1, style: style);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          total,
          maxLines: 1,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            decoration: TextDecoration.lineThrough,
            fontFeatures: PosTheme.tabular,
          ),
        ),
        Text(money(cents(total) - off), maxLines: 1, style: style),
      ],
    );
  }
}

/// A line under a dish on the check: one of its choices and what it changes ("+0.50"), a comp or discount
/// on it and what it took off ("(30.00)"), or its state ("not sent yet", a kitchen note). A choice on a
/// choice that is a dish (the sauce on a roll of the maki combination) sits one step further in.
class _SubLine extends StatelessWidget {
  const _SubLine(this.label, {super.key, this.amount, this.depth = 0, this.alert = false});

  final String label;
  final String? amount;
  final int depth;

  /// A warning (a dish that contains what the guest is allergic to): red and bold.
  final bool alert;

  /// How far each level of choices moves in.
  static const indent = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = alert
        ? theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error, fontWeight: FontWeight.w700)
        : theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final amount = this.amount;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: depth * indent),
            child: Text(label, style: style),
          ),
        ),
        if (amount != null && amount.isNotEmpty)
          SizedBox(
            width: _amountWidth,
            child: Text(
              amount,
              textAlign: TextAlign.end,
              maxLines: 1,
              style: style?.copyWith(fontFeatures: PosTheme.tabular),
            ),
          ),
      ],
    );
  }
}

/// A tap target that also answers holding it down, which an [IconButton] does not.
class _Hold extends StatelessWidget {
  const _Hold({super.key, required this.tooltip, required this.onTap, required this.onLongPress, required this.child});

  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null && onLongPress == null) return child;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(seconds: 1),
      child: InkResponse(onTap: onTap, onLongPress: onLongPress, radius: 24, child: child),
    );
  }
}

/// How many of a dish, typed. Zero takes the line off.
class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.name, required this.qty});

  final String name;
  final int qty;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final _text = TextEditingController(text: '${widget.qty}')
    ..selection = TextSelection(baseOffset: 0, extentOffset: '${widget.qty}'.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  int? get _qty {
    final qty = int.tryParse(_text.text.trim());
    return qty == null || qty < 0 || qty > 999 ? null : qty;
  }

  void _done() {
    final qty = _qty;
    if (qty != null) Navigator.of(context).pop(qty);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('How many ${widget.name}?'),
      content: TextField(
        key: const ValueKey('qty-field'),
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(helperText: '0 takes it off the check'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _done(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _qty == null ? null : _done, child: const Text('Set')),
      ],
    );
  }
}

/// A course on the check: its name and state, or the name alone, dimmed, while nothing is under it (a
/// line can be dragged there). Once the kitchen has dishes of it, it says when the first of them went,
/// before the state: "sent 18:42", and on an open check ([minute], the time it is now) how long ago.
class _CourseHeader extends StatelessWidget {
  const _CourseHeader({super.key, this.id = '', required this.name, required this.state, this.sentMs, this.minute});
  final String id;
  final String name;
  final String state;
  final int? sentMs;
  final ValueListenable<int>? minute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posColors = PosColors.of(context);
    final fired = state == 'fired';
    final empty = state.isEmpty;
    final badgeBg = fired ? posColors.fired : posColors.waiting;
    final badgeFg = fired ? posColors.firedText : posColors.waitingText;
    final badgeBorder = fired ? posColors.firedBorder : posColors.waitingBorder;
    final sentMs = this.sentMs;
    final minute = this.minute;
    // in the type of the words under a dish ("not sent yet"), which it reads along with
    Widget sentText(String words) => Text(
      words,
      key: ValueKey('course-sent:$id'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: PosTheme.tabular,
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: posColors.checkHeader,
        border: Border.symmetric(horizontal: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.7)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          // The name, and beside it when the course went. Where the check is too narrow for both on one
          // line (a phone, a long name, large type) the time goes under the name, whole and no smaller.
          Expanded(
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: empty ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
                if (sentMs != null && !empty)
                  if (minute != null)
                    ValueListenableBuilder<int>(
                      valueListenable: minute,
                      builder: (context, now, _) => sentText(sentWords(sentMs, nowMs: now)),
                    )
                  else
                    sentText(sentWords(sentMs)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (empty)
            const SizedBox(height: 20) // the row keeps the height of the state it will show
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: badgeBorder.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(fired ? Icons.local_fire_department : Icons.pause_circle_outline, size: 14, color: badgeFg),
                  const SizedBox(width: 4),
                  Text(
                    state,
                    style: theme.textTheme.labelSmall?.copyWith(color: badgeFg, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Which seat and course the next dish goes to, and the seats at the table: + adds one, − takes the last
/// one away once nothing is on it. With coursing off ([courses] empty) the row is the seats alone. The
/// Allergy chip leads the row, where a phone shows it without scrolling, and a seat with an allergy noted
/// carries a warning mark. A to-go order has no seats ([seated] false): its bar is the chip alone.
class _SeatCourseBar extends StatelessWidget {
  const _SeatCourseBar({
    this.seated = true,
    this.onSeatTab,
    this.allergy,
    this.allergic = const {},
    required this.seats,
    required this.seat,
    required this.course,
    required this.courses,
    required this.onSeat,
    required this.onAddSeat,
    required this.onRemoveSeat,
    required this.onCourse,
  });

  final bool seated;

  /// A bar tab, which has no seats yet: the bar starts with "Seat at a table" in their place, and this is
  /// what it does. Null for any other check.
  final VoidCallback? onSeatTab;

  /// The Allergy chip, when the hub takes allergies.
  final Widget? allergy;

  /// The seats with an allergy noted (0: the table).
  final Set<int> allergic;
  final int seats;
  final int? seat;
  final String? course;
  final List<Course> courses;
  final ValueChanged<int?> onSeat;
  final VoidCallback onAddSeat;
  final VoidCallback onRemoveSeat;
  final ValueChanged<String> onCourse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String label, bool selected, VoidCallback onTap, {bool alert = false}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: !alert
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  const SizedBox(width: 3),
                  Icon(Icons.warning_amber_rounded, size: 15, color: scheme.error, semanticLabel: 'allergy'),
                ],
              ),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
    final seatChips = !seated
        ? [?allergy]
        : onSeatTab != null
        ? [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ActionChip(
                key: const ValueKey('seat-tab'),
                avatar: const Icon(Icons.table_restaurant_outlined, size: 18),
                label: const Text('Seat at a table'),
                tooltip: 'The party sits down: pick their table on the floor map',
                visualDensity: VisualDensity.compact,
                onPressed: onSeatTab,
              ),
            ),
            if (allergy != null) Padding(padding: const EdgeInsets.only(right: 10), child: allergy),
          ]
        : [
            if (allergy != null) Padding(padding: const EdgeInsets.only(right: 10), child: allergy),
            const Text('Seat  '),
            chip('Table', seat == null, () => onSeat(null), alert: allergic.contains(0)),
            for (var i = 1; i <= seats; i++) chip('$i', seat == i, () => onSeat(i), alert: allergic.contains(i)),
            IconButton(
              tooltip: 'Remove seat $seats',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: seats > 0 ? onRemoveSeat : null,
            ),
            IconButton(
              tooltip: 'Add a seat',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onAddSeat,
            ),
          ];
    final courseChips = [
      if (seated && courses.isNotEmpty) const Text('Course  '),
      if (seated)
        for (final c in courses) chip(c.name, course == c.id, () => onCourse(c.id)),
    ];
    Widget row(List<Widget> children) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: compact(context) || courseChips.isEmpty
          // a phone: both on one line that scrolls, to leave the screen to the menu
          ? row([...seatChips, if (courseChips.isNotEmpty) const SizedBox(width: 8), ...courseChips])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [row(seatChips), row(courseChips)]),
    );
  }
}

/// "Allergy": opens the allergies told at the table. Red once one is noted.
class _AllergyChip extends StatelessWidget {
  const _AllergyChip({required this.noted, required this.onTap});

  final bool noted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      key: const ValueKey('allergy-chip'),
      avatar: Icon(Icons.warning_amber_rounded, size: 18, color: noted ? scheme.onError : scheme.error),
      label: const Text('Allergy'),
      labelStyle: noted ? TextStyle(color: scheme.onError, fontWeight: FontWeight.w700) : null,
      backgroundColor: noted ? scheme.error : null,
      side: noted ? BorderSide(color: scheme.error) : null,
      tooltip: noted ? 'Change the allergies noted' : 'Note an allergy for the table or a seat',
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}

/// What the guests cannot have, in a red strip under the app bar for as long as the order carries an
/// allergy: "Table: Peanuts · Seat 2: Sesame - no oyster sauce". A tap opens them to change.
class _AllergyStrip extends StatelessWidget {
  const _AllergyStrip({required this.words, required this.onTap});

  final String words;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('allergy-strip'),
      color: scheme.errorContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ALLERGY  $words',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line kept about the customer at the order's number, in a slim strip under the app bar: "no MSG,
/// side door". It is for whoever takes the order; it does not print in the kitchen.
class _CustomerStrip extends StatelessWidget {
  const _CustomerStrip({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('customer-note-strip'),
      color: scheme.surfaceContainerHighest, // plain: red is the allergy strip's
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.sticky_note_2_outlined, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Customer note: $note',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The day and time an order for later is for, and on a catering order what its event needs, in one line
/// under the bar: "For Sat 21 Nov 12:00 · 30 guests · Delivery · 12 Main St". A tap changes them.
class _WhenStrip extends StatelessWidget {
  const _WhenStrip({required this.order, this.onTap, this.onPack});

  final Order order;
  final VoidCallback? onTap;

  /// Prints the order's pack sheet; null while there is nothing to pack, or one is on its way.
  final VoidCallback? onPack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final event = order.isCatering ? order.event.words : '';
    return Material(
      key: const ValueKey('when-strip'),
      color: scheme.surfaceContainerHighest, // plain, like the customer's note: red is the allergy strip's
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: Row(
                  children: [
                    Icon(Icons.event_outlined, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ['For ${whenFor(order.promisedAt!, DateTime.now())}', if (event.isNotEmpty) event].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onTap != null) Icon(Icons.edit_outlined, size: 14, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          // the paper to pack the order by: beside what the order is for, not one more button in the bar.
          // A wide screen has the room to say what it is; a phone shows the sign alone.
          if (MediaQuery.sizeOf(context).width >= 720)
            Tooltip(
              message: 'Print the pack sheet',
              child: TextButton.icon(
                key: const ValueKey('pack-sheet'),
                onPressed: onPack,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(44, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Pack sheet'),
              ),
            )
          else
            IconButton(
              key: const ValueKey('pack-sheet'),
              tooltip: 'Print the pack sheet',
              onPressed: onPack,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 30),
              iconSize: 18,
              icon: const Icon(Icons.fact_check_outlined),
            ),
        ],
      ),
    );
  }
}

/// Fire one held course, or everything at once: and stay on the check, or leave it. With coursing off
/// (or dishes not coursed) only everything can go, and the button counts the dishes still to send.
class _FireMenu extends StatelessWidget {
  const _FireMenu({required this.order, required this.coursing, required this.onFire, this.signsOut = false});

  final Order order;
  final Coursing coursing;
  final void Function(String course, {bool leave}) onFire;

  /// Whether leaving after a send signs the person out here (a shared screen): the last choice says so.
  final bool signsOut;

  @override
  Widget build(BuildContext context) {
    final posColors = PosColors.of(context);
    final waiting = order.heldCourses;
    final held = [
      for (final c in coursing.courses)
        if (waiting.contains(c.id)) c,
    ];
    final unsent = order.activeLines.where((l) => !l.fired).length;
    final anyHeld = unsent > 0;
    final label = held.isNotEmpty
        ? 'Fire (${held.length} held)'
        : anyHeld
        ? 'Fire ($unsent to send)'
        : 'Fire';
    return PopupMenuButton<(String, bool)>(
      tooltip: 'Fire',
      onSelected: (choice) => onFire(choice.$1, leave: choice.$2),
      itemBuilder: (_) => [
        for (final c in held)
          PopupMenuItem(
            value: (c.id, false),
            child: Row(
              children: [
                Icon(Icons.local_fire_department, size: 18, color: posColors.waitingBorder),
                const SizedBox(width: 8),
                Flexible(child: Text('Fire ${c.name}', overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        if (held.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(value: ('*', false), child: Text('Fire everything')),
        PopupMenuItem(
          key: const ValueKey('fire-and-leave'),
          value: ('*', true),
          child: Row(
            children: [
              const Icon(Icons.logout, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  signsOut ? 'Fire everything and sign out' : 'Fire everything and leave',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: compact(context)
            ? Badge(
                isLabelVisible: anyHeld,
                label: Text('${held.isNotEmpty ? held.length : unsent}'),
                child: const Icon(Icons.local_fire_department),
              )
            : AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: anyHeld ? posColors.waiting : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: anyHeld ? Border.all(color: posColors.waitingBorder.withValues(alpha: 0.6)) : null,
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department, size: 18, color: anyHeld ? posColors.waitingText : null),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: anyHeld ? TextStyle(color: posColors.waitingText, fontWeight: FontWeight.w700) : null,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// "#42 Linda · 18:05" for the app bar of a to-go order; the hub gives the number when the create lands.
/// [readyAt] is when it will be ready as the screen works it out (a big order not sent yet takes longer).
/// An order the customer named a time for says its day too, when that is not today ("Sat 21 Nov 12:00").
String _takeoutTitle(Order order, int? readyAt) => [
  '#${order.orderNo ?? '…'} ${order.customerName.isEmpty ? 'To go' : order.customerName}',
  if (readyAt != null) order.forLater ? whenFor(readyAt, DateTime.now()) : clockTime(readyAt),
  if (!order.isOpen) order.status,
].join(' · ');

/// "Paid cash (tendered 20.00)", "Paid elsewhere · sending".
String _paymentLabel(Payment p) =>
    ['Paid ${p.method}${p.tendered != null ? ' (tendered ${p.tendered})' : ''}', if (p.pending) 'sending'].join(' · ');

/// "Manager comp · on Peking Duck · Mike approved".
String _discountLabel(CheckDiscount d, Check check) {
  final on = d.lineId == null ? null : check.line(d.lineId!)?.name;
  return [d.name, if (on != null) 'on $on', if (d.approvedBy != null) '${d.approvedBy} approved'].join(' · ');
}

/// 7.00 -> 7, 6.25 -> 6.25.
String _rate(String pct) {
  final value = double.tryParse(pct);
  if (value == null) return pct;
  return value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}

/// The Bill button beside the total: a tap prints the guest's bill, a hold picks the printer this screen's
/// bills come out of. Greyed while a bill is on its way.
class _BillButton extends StatelessWidget {
  const _BillButton({required this.onTap, required this.onHold, this.bills = 1, this.tight = false});

  final VoidCallback? onTap;
  final VoidCallback onHold;

  /// How many bills a tap prints: one for each check of a table that pays on several.
  final int bills;

  /// On a narrow check: the word alone, no icon.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: bills > 1
          ? 'Print the $bills bills. Hold to pick the printer for this screen'
          : 'Print the bill. Hold to pick the printer for this screen',
      child: OutlinedButton.icon(
        key: const ValueKey('bill'),
        onPressed: onTap,
        onLongPress: onTap == null ? null : onHold,
        icon: tight ? null : const Icon(Icons.receipt_long_outlined, size: 18),
        label: const Text('Bill'),
        style: OutlinedButton.styleFrom(
          // as tall as a finger needs and no taller: the foot of the check is always on the screen
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

/// The Pay button beside what is due on a to-go order: takes money and nothing else.
class _PayButton extends StatelessWidget {
  const _PayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      key: const ValueKey('pay'),
      onPressed: onTap,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: const Text('Pay'),
    );
  }
}

/// The Split button beside the total: how the table pays. It says how many checks once there are several.
class _SplitButton extends StatelessWidget {
  const _SplitButton({required this.checks, required this.onTap, this.tight = false});

  final int checks;
  final VoidCallback onTap;

  /// On a narrow check: the word alone, no icon.
  final bool tight;

  /// What the button says: how many checks, once there are several.
  static String words(int checks) => checks > 1 ? 'Split $checks' : 'Split';

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: checks > 1 ? 'This table pays on $checks checks' : 'Split the check',
      child: OutlinedButton.icon(
        key: const ValueKey('split'),
        onPressed: onTap,
        icon: tight ? null : const Icon(Icons.call_split, size: 18),
        label: Text(words(checks)),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

/// The total at the foot of the check, with its buttons: Split (how the table pays) and Bill. The bill is
/// the total on paper, so the buttons stand beside the total and cost no row. They never run off a narrow
/// check: where they do not fit with their icons they are words alone (a small tablet shows the check on a
/// third of its width), and where the words do not fit either they take the row above the total.
class _TotalFoot extends StatelessWidget {
  const _TotalFoot({
    required this.label,
    required this.amount,
    required this.checks,
    required this.onSplit,
    required this.onBill,
    required this.onBillPlace,
    required this.buttons,
  });

  final String label;
  final String amount;
  final int checks;

  /// Null where there is no Split button: a hub older than splitting, a closed check that was never split.
  final VoidCallback? onSplit;
  final VoidCallback? onBill;
  final VoidCallback onBillPlace;

  /// False for a check with no dish: nothing to bill or split.
  final bool buttons;

  static const _gap = 6.0;
  static const _around = 10.0; // on either side of the buttons, between the label and the amount
  static const _labelRoom = 44.0; // what "Total" needs to stay a word

  @override
  Widget build(BuildContext context) {
    if (!buttons) return _TotalRow(label, amount, strong: true);
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double wide(String text, TextStyle? style) => (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout()).width;
    final split = onSplit;
    final words = [if (split != null) _SplitButton.words(checks), 'Bill'];
    final written = words.fold(0.0, (sum, word) => sum + wide(word, theme.textTheme.labelLarge));
    // each button: its word, its padding and, with an icon, the icon and the space after it
    final plain = written + words.length * 2 * 12 + (words.length - 1) * _gap;
    final iconed = plain + words.length * (18 + 8);
    final total = wide(amount, theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800));
    Widget row({required bool tight}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (split != null) ...[_SplitButton(checks: checks, onTap: split, tight: tight), const SizedBox(width: _gap)],
        _BillButton(onTap: onBill, onHold: onBillPlace, bills: checks, tight: tight),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth - total - _labelRoom - 2 * _around;
        if (plain <= room) return _TotalRow(label, amount, strong: true, action: row(tight: iconed > room));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            row(tight: iconed > constraints.maxWidth),
            const SizedBox(height: 6),
            _TotalRow(label, amount, strong: true),
          ],
        );
      },
    );
  }
}

/// Tells whoever listens that this screen read something new.
class _Changes extends ChangeNotifier {
  void tell() => notifyListeners();
}

/// What goes in the bag of a to-go order besides the food, over the totals: the answer to the question
/// asked before sending. A tap asks it again.
class _BagRow extends StatelessWidget {
  const _BagRow({super.key, required this.items, this.onTap});

  final List<BagItem> items;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grey = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(Icons.shopping_bag_outlined, size: 16, color: grey),
            ),
            Expanded(
              child: Text(
                'In the bag: ${bagWords(items)}',
                style: theme.textTheme.bodyMedium?.copyWith(color: grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: Icon(Icons.edit_outlined, size: 14, color: grey),
              ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {super.key, this.strong = false, this.onTap, this.action});

  final String label;
  final String amount;
  final bool strong;

  /// A button between the label and the amount (the Bill button on the total).
  final Widget? action;

  /// Set on a discount or charge row: a tap takes it off.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = strong
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)
        : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final row = Row(
      children: [
        if (action == null)
          Expanded(
            child: Text(label, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        else
          // the button right after the label, the amount still at the edge; a narrow check shortens the label
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(label, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: action),
              ],
            ),
          ),
        Text(amount, style: baseStyle?.copyWith(fontFeatures: PosTheme.tabular)),
        if (onTap != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.close, size: 14, color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: row),
    );
  }
}
