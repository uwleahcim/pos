import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../guest_display.dart';
import '../live.dart';
import 'theme.dart';

/// The guest display (docs/guest-display.md): a screen turned to the customer. It shows the order open on
/// the screen it is linked to ([of], that screen's device name) as it is rung up: each dish with its choices
/// and what it comes to, the sums, the total, what was paid and the change. It is the bill, live, worked out
/// on the hub; nothing is added up here. Nobody is signed in on it and nothing on it can be changed: the
/// only button is the staff's way to the sign-in pad.
///
/// With no order open on that screen it greets, with the restaurant's name. An order paid in full says so,
/// and when the screen it is linked to leaves an order that is paid, this one says thank you for
/// [thanksFor] before it greets the next guest.
///
/// It reads when the hub says the linked screen opened or left an order, or that the order it shows
/// changed, and now and then while the hub cannot say. A hub that stops answering leaves the last picture up
/// for [staleAfter] and no longer: a guest is never shown a total that may be behind.
class GuestDisplayScreen extends StatefulWidget {
  const GuestDisplayScreen({
    super.key,
    required this.api,
    required this.of,
    this.onStaff,
    this.thanksFor = const Duration(seconds: 8),
    this.staleAfter = const Duration(seconds: 10),
    this.lateFor = const Duration(seconds: 5),
  });

  final PosApi api;

  /// The screen this one faces the guest of, by its device name.
  final String of;

  /// One of the staff wants the sign-in pad.
  final VoidCallback? onStaff;
  final Duration thanksFor;
  final Duration staleAfter;

  /// How long after an order was left its payment still gets a thank you: paying and leaving are one tap,
  /// and the payment can reach the hub a moment after the word that the order was left.
  final Duration lateFor;

  @override
  State<GuestDisplayScreen> createState() => _GuestDisplayScreenState();
}

class _GuestDisplayScreenState extends State<GuestDisplayScreen> {
  GuestDisplay? _read; // what the hub last answered: the same answer again is nothing to draw
  GuestOrder? _order; // the order on the screen now
  String _name = ''; // the restaurant's, as last read: it stays up while the hub is away
  String? _watching; // the order the linked screen has open, shown or not yet
  String? _gone; // the order it left a moment ago, unpaid as far as the hub knew then
  bool _known = true; // the hub hears from the linked screen
  bool _thanks = false; // a paid order was just left: thank you, for a moment
  bool _away = false; // the last read got no answer
  bool _old = false; // the hub is older than guest displays
  late final _poll = SafetyPoll(widget.api.live);
  late final _reader = Paced(const Duration(milliseconds: 250), _fetch);
  final _scroll = ScrollController();
  StreamSubscription<LiveChange>? _live;
  Timer? _timer;
  Timer? _thanksOver;
  Timer? _goneOver;
  Timer? _stale;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_poll.due()) unawaited(_reader.now(must: false));
    });
    _live = widget.api.live.changes.listen((change) {
      final watching = _watching, gone = _gone;
      // the linked screen opened an order or left one, the order it has open (or left a moment ago) changed,
      // or the restaurant's own lines were written again
      if (change.everything ||
          change.showing ||
          change.settings ||
          (watching != null && change.touches(watching)) ||
          (gone != null && change.touches(gone))) {
        _reader();
      }
    });
    unawaited(_reader.now());
  }

  @override
  void didUpdateWidget(GuestDisplayScreen old) {
    super.didUpdateWidget(old);
    if (old.of != widget.of) unawaited(_reader.now()); // linked to another screen, in Settings behind the pad
  }

  @override
  void dispose() {
    _timer?.cancel();
    _thanksOver?.cancel();
    _goneOver?.cancel();
    _stale?.cancel();
    unawaited(_live?.cancel());
    _reader.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    _poll.asked();
    final GuestDisplay? view;
    try {
      view = await widget.api.guestDisplay(widget.of);
    } on ApiException {
      if (mounted) _lost();
      return;
    }
    if (!mounted) return;
    _stale?.cancel();
    _stale = null;
    if (view == null) {
      // a hub from before guest displays: nothing to show a guest, and a word for the staff
      _watching = null;
      _forget();
      if (!_old || _order != null || _away || _thanks) {
        _thanksOver?.cancel();
        setState(() {
          _old = true;
          _away = false;
          _order = null;
          _thanks = false;
        });
      }
      return;
    }
    if (identical(view, _read) && !_away && !_old) return;
    _read = view;
    final before = _watching;
    _watching = view.showing;
    final was = _order;
    final next = view.order;
    final left = view.left;
    // the order the screen it is linked to left: with this read, or a moment ago
    final moved = before != null && view.showing != before;
    final gone = moved ? before : _gone;
    var thanks = _thanks;
    if (next != null) {
      thanks = false;
      _thanksOver?.cancel();
      _forget();
    } else if (gone != null && left?.orderId == gone && left!.paidInFull) {
      // it left the order this one was on, and that order is paid: thank you, before the next guest. The
      // hub says whether it is paid: paying and leaving are often one tap, and then no read ever saw the
      // order paid.
      thanks = true;
      _forget();
      _thanksOver?.cancel();
      _thanksOver = Timer(widget.thanksFor, () {
        if (mounted) setState(() => _thanks = false);
      });
    } else if (moved) {
      // left unpaid, as far as the hub knows. The payment may still be on its way to the hub (it and the
      // word that the order was left are two calls): for a moment this screen still listens for it.
      _gone = before;
      _goneOver?.cancel();
      _goneOver = Timer(widget.lateFor, () => _gone = null);
    }
    final grew = next != null && (was == null || was.orderId != next.orderId || next.lines.length != was.lines.length);
    final (name, known) = (view.name, view.known);
    setState(() {
      _order = next;
      _thanks = thanks;
      _name = name;
      _known = known;
      _away = false;
      _old = false;
    });
    if (grew) _toLastDish(jump: was == null || was.orderId != next.orderId);
  }

  void _forget() {
    _goneOver?.cancel();
    _gone = null;
  }

  /// No hub answered. The picture stays for a moment (a hub that restarts is back within seconds), then goes:
  /// a guest is not shown an order that may have changed since.
  void _lost() {
    if (!_away) setState(() => _away = true);
    if (_stale != null || (_order == null && !_thanks)) return;
    _stale = Timer(widget.staleAfter, () {
      _stale = null;
      if (!mounted) return;
      _thanksOver?.cancel();
      _read = null;
      setState(() {
        _order = null;
        _thanks = false;
      });
    });
  }

  /// The dish just rung in is the one the guest looks for: the list goes to its end.
  void _toLastDish({required bool jump}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        unawaited(_scroll.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic));
      }
    });
  }

  /// A word in the corner for the staff: what this screen is linked to, and what is wrong when something is.
  String get _note {
    if (_old) return 'The hub is older than guest displays: update the hub.';
    if (_away) return 'The hub is not answering.';
    if (!_known) return 'Linked to ${widget.of}, which is not on.';
    return 'Linked to ${widget.of}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final order = _order;
    final trouble = _old || _away || !_known;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // the dishes beside the total where the screen is wide and lying down; the total under the
            // dishes on a phone or a tablet standing up
            final wide = box.maxWidth >= 720 && box.maxWidth > box.maxHeight;
            // the size of everything follows the screen: a tablet on the counter, a phone in a stand
            final unit = ((wide ? box.maxWidth * 0.58 : box.maxWidth) / 24).clamp(15.0, 30.0);
            final Widget body;
            if (order != null) {
              body = _OrderView(
                key: const ValueKey('guest-order'),
                order: order,
                unit: unit,
                wide: wide,
                scroll: _scroll,
                most: box.maxHeight,
              );
            } else if (_thanks) {
              body = _Greeting(key: const ValueKey('guest-thanks'), big: 'Thank you!', small: _name, unit: unit);
            } else {
              body = _Greeting(
                key: const ValueKey('guest-welcome'),
                big: _name.isEmpty ? 'Welcome' : _name,
                small: _name.isEmpty ? '' : 'Welcome',
                unit: unit,
              );
            }
            return Column(
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: body,
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _note,
                          key: const ValueKey('guest-note'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: trouble ? scheme.error : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      if (widget.onStaff != null)
                        TextButton(
                          key: const ValueKey('guest-staff'),
                          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                          onPressed: widget.onStaff,
                          child: const Text('Staff'),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What the screen says with no order to show: the restaurant's name and a welcome, or a thank you.
class _Greeting extends StatelessWidget {
  const _Greeting({super.key, required this.big, required this.small, required this.unit});

  final String big;
  final String small;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(unit),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              big,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: unit * 2.2, fontWeight: FontWeight.w700, height: 1.15),
            ),
            if (small.isNotEmpty) ...[
              SizedBox(height: unit * 0.5),
              Text(
                small,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: unit * 1.2, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An order as the guest reads it: the dishes, and the sums with the total.
class _OrderView extends StatelessWidget {
  const _OrderView({
    super.key,
    required this.order,
    required this.unit,
    required this.wide,
    required this.scroll,
    required this.most,
  });

  final GuestOrder order;
  final double unit;
  final bool wide;
  final ScrollController scroll;

  /// The height there is for the whole of it: on a narrow screen the sums take no more than half.
  final double most;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dishes = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(unit, unit * 0.7, unit, unit * 0.3),
          child: Text(
            [order.where, order.detail].where((part) => part.isNotEmpty).join(' · '),
            key: const ValueKey('guest-where'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: unit * 0.95, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(unit, 0, unit, unit * 0.6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, line) in order.lines.indexed)
                  _DishRow(key: ValueKey('guest-line:$i'), line: line, unit: unit),
              ],
            ),
          ),
        ),
      ],
    );
    final sums = _Sums(order: order, unit: unit);
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 58, child: dishes),
          VerticalDivider(width: 1, color: scheme.outlineVariant),
          Expanded(
            flex: 42,
            child: ColoredBox(
              color: scheme.surfaceContainerLow,
              child: Center(child: SingleChildScrollView(child: sums)),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: dishes),
        Divider(height: 1, color: scheme.outlineVariant),
        ColoredBox(
          color: scheme.surfaceContainerLow,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(most * 0.55, 120)),
            child: SingleChildScrollView(child: sums),
          ),
        ),
      ],
    );
  }
}

/// One dish: how many, its name, what it comes to; its choices and a comp on it in words under the name.
class _DishRow extends StatelessWidget {
  const _DishRow({super.key, required this.line, required this.unit});

  final GuestLine line;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final big = TextStyle(fontSize: unit, fontWeight: FontWeight.w600, height: 1.25);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: unit * 0.28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: unit * 1.7,
            child: Text('${line.qty}', style: big.copyWith(fontFeatures: PosTheme.tabular)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.name, style: big),
                for (final note in line.notes)
                  Padding(
                    padding: EdgeInsets.only(left: unit * 0.8 * note.depth, top: unit * 0.08),
                    child: Text(
                      note.text,
                      style: TextStyle(fontSize: unit * 0.78, color: scheme.onSurfaceVariant, height: 1.25),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(width: unit * 0.6),
          Text(line.amount, style: big.copyWith(fontFeatures: PosTheme.tabular)),
        ],
      ),
    );
  }
}

/// Under the dishes: the subtotal, each discount and charge, the tax; the total, large; what was paid and
/// what is still due.
class _Sums extends StatelessWidget {
  const _Sums({required this.order, required this.unit});

  final GuestOrder order;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PosColors.of(context);
    final small = TextStyle(fontSize: unit * 0.85, color: scheme.onSurfaceVariant, height: 1.3);
    final large = TextStyle(fontSize: unit * 1.7, fontWeight: FontWeight.w800, height: 1.15);
    final paidInk = theme.brightness == Brightness.dark ? colors.firedBorder : colors.firedText;
    Widget row(GuestRow sum, {Key? key}) => Padding(
      key: key,
      padding: EdgeInsets.symmetric(vertical: unit * 0.1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(sum.label, style: small)),
          if (sum.amount.isNotEmpty) ...[
            SizedBox(width: unit * 0.6),
            Text(sum.amount, style: small.copyWith(fontFeatures: PosTheme.tabular)),
          ],
        ],
      ),
    );
    Widget figure(String label, String amount, {required Key key, Color? color}) => Padding(
      padding: EdgeInsets.symmetric(vertical: unit * 0.15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(label, style: large.copyWith(color: color)),
          ),
          SizedBox(width: unit * 0.6),
          Text(
            '\$$amount',
            key: key,
            style: large.copyWith(color: color, fontFeatures: PosTheme.tabular),
          ),
        ],
      ),
    );
    final due = order.due;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: unit, vertical: unit * 0.6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, sum) in order.sums.indexed) row(sum, key: ValueKey('guest-sum:$i')),
          SizedBox(height: unit * 0.2),
          figure('Total', order.total, key: const ValueKey('guest-total')),
          for (final (i, paid) in order.paid.indexed) row(paid, key: ValueKey('guest-paid:$i')),
          if (due != null && !order.paidInFull) figure('Due', due, key: const ValueKey('guest-due')),
          if (order.paidInFull)
            Padding(
              padding: EdgeInsets.only(top: unit * 0.3),
              child: Row(
                key: const ValueKey('guest-paid-in-full'),
                children: [
                  Icon(Icons.check_circle, size: unit * 1.5, color: paidInk),
                  SizedBox(width: unit * 0.4),
                  Expanded(
                    child: Text(
                      'Paid in full. Thank you!',
                      style: TextStyle(fontSize: unit * 1.15, fontWeight: FontWeight.w700, color: paidInk),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
