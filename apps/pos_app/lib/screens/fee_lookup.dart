import 'package:flutter/material.dart';

import '../api.dart';
import '../delivery_fee.dart';
import '../drive_lookups.dart';
import '../takeout.dart';
import 'service_badge.dart';

/// How far a form's delivery goes, asked of the hub (docs/delivery.md, "Looking the distance up"). The hub
/// asks its map service, and is sent the address alone. A form asks when the address is done being typed,
/// and once per address: the same one is not asked twice, and one that failed is asked again only when
/// somebody says so.
///
/// A customer who had a delivery brought to the address before is answered from that order, by the hub
/// ("Customers who order again"): the form says so, and offers to look it up again.
class DistanceAsker extends ChangeNotifier {
  /// How the hub is asked (`PosApi.deliveryDistance`); null while this location looks nothing up.
  DistanceSource? source;

  /// Whether there is anything to ask.
  bool get can => source != null;

  String? _address;
  int _turn = 0;
  bool _gone = false;
  bool _now = false; // whether the address was asked about as a delivery for now

  /// The hub was asked and has not answered yet.
  bool get asking => _asking;
  bool _asking = false;

  /// What the hub said of the address asked last.
  FeeLookup? get found => _found;
  FeeLookup? _found;

  /// Why there is no distance, in words for the form.
  String? get problem => _problem;
  String? _problem;

  /// What the map said of [address], when that is the address it was asked about and the figures may go
  /// onto the order ([FeeLookup.keep]): what a pick sends back to the hub.
  Measured? measuredFor(String address) {
    final found = _found;
    return found != null && found.keep && _address == oneLine(address) ? found.measured : null;
  }

  /// The drive to [address] as the roads are right now, when that is the address the hub was asked about
  /// as a delivery for now and it could say ("Live traffic"): what such a delivery is promised by.
  DriveNow? driveFor(String address) => _address == oneLine(address) ? _found?.driveNow : null;

  /// Asks how far [address] is. The answer, or null when there is nothing to ask, the address was asked
  /// already (unless [again]), no distance came of it, or the form has moved on meanwhile. [fresh] asks
  /// again and has the hub ask its map service, whatever the customer's earlier order says.
  ///
  /// [now] says the delivery is for now, so the hub also says how long the drive is at this minute where
  /// live traffic is on. An address that was asked about as an order for later is asked about once more
  /// when the order becomes one for now.
  Future<FeeLookup?> ask(String address, {bool again = false, bool fresh = false, bool now = false}) async {
    final source = this.source, line = oneLine(address);
    if (source == null || line.isEmpty) return null;
    final forNow = now && !_now; // it is for now, and what was asked last was not
    if (line == _address && !forNow && (_asking || (!again && !fresh && (_found != null || _problem != null)))) {
      return null;
    }
    final turn = ++_turn;
    _address = line;
    _now = now;
    _asking = true;
    _found = null;
    _problem = null;
    notifyListeners();
    FeeLookup? answer;
    String? problem;
    try {
      answer = await source(line, fresh: fresh, now: now);
    } on ApiException catch (err) {
      problem =
          (err.detail?['message'] as String?) ??
          (err.status == null
              ? 'The hub is not answering. Pick the fee by hand.'
              : 'The distance could not be looked up. Pick the fee by hand.');
    }
    if (_gone || turn != _turn) return null;
    _asking = false;
    _found = answer;
    _problem = problem;
    notifyListeners();
    return answer;
  }

  /// The address was typed over: what was found is not about it any more.
  void typed(String address) {
    if (oneLine(address) == _address) return;
    _turn++;
    _address = null;
    _now = false;
    if (!_asking && _found == null && _problem == null) return;
    _asking = false;
    _found = null;
    _problem = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

/// Somebody asked a form for the distance by hand. `fresh` when the customer's earlier order said how far
/// and they want the map service asked all the same.
typedef LookUp = void Function({bool fresh});

/// The line over a delivery's prices that says how far the address is: what the map said, that it is being
/// asked, why there is no answer, or a button that asks. What the hub read off the customer's own earlier
/// order says "as last time", with a small button beside it that asks the map service again. Figures of a
/// service that wants its name beside them carry it ([MapCredit]).
///
/// Where the hub also said how long the drive is at this minute ("Live traffic"), that stands with it:
/// "With traffic now: 14 min", and the name of the service that knows the roads. It is the one place a
/// form shows that figure.
///
/// Where the hub says who gave a figure and what that service has left today ("Which service is asked
/// first"), the service's badge stands before the figure: its letter in a ring for how many of its day's
/// lookups are left ([ServiceBadge]). Each figure then has a line of its own, so a badge is always the
/// first thing of its line and never moves with the length of what is written after it.
class FeeLookupLine extends StatelessWidget {
  const FeeLookupLine({super.key, required this.asker, required this.address, required this.onLookUp});

  final DistanceAsker asker;

  /// What the form holds as the address now.
  final String address;

  /// Somebody asked for the distance, or for another try.
  final LookUp onLookUp;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: asker,
    builder: (context, _) {
      final theme = Theme.of(context);
      final found = asker.found, problem = asker.problem;
      final quiet = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
      if (asker.asking) {
        return Text('Looking up how far it is…', key: const ValueKey('fee-lookup-asking'), style: quiet);
      }
      if (found != null) {
        final drive = '${found.measured.words} drive${found.saved ? ', as last time' : ''}';
        final said = Text(
          found.beyond ? '$drive: further than the prices reach' : drive,
          key: const ValueKey('fee-lookup-found'),
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        );
        final credit = found.credit;
        final now = found.driveNow;
        // one name serves both figures when the same service gave both
        final together = now != null && now.credit == credit;
        final line = !found.saved
            ? said
            : Row(
                mainAxisSize: credit == null && !together ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Flexible(child: said),
                  IconButton(
                    key: const ValueKey('fee-lookup-again'),
                    onPressed: () => onLookUp(fresh: true),
                    tooltip: 'Look it up again',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                ],
              );
        // beside the figures where there is room, under them where there is not; never broken in two
        Widget credited(List<Widget> children) => children.length == 1
            ? children.single
            : Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: children);
        // who gave a figure, before it
        Widget led(AnsweredBy? by, Key mark, Widget child) => by == null
            ? child
            : Row(
                children: [
                  ServiceBadge(
                    key: mark,
                    service: by.service,
                    title: by.title,
                    share: leftShare(by.left, by.dailyMost),
                    words: leftToday(by.left, by.dailyMost),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: child),
                ],
              );
        const measuredBy = ValueKey('fee-lookup-by'), saidBy = ValueKey('fee-lookup-now-by');
        if (now == null) return led(found.by, measuredBy, credited([line, if (credit != null) MapCredit(credit)]));
        final traffic = Text(
          'With traffic now: ${now.minutes} min',
          key: const ValueKey('fee-lookup-now'),
          style: theme.textTheme.bodyMedium,
        );
        if (found.by != null || now.by != null) {
          // a line each, so each badge leads its own; one name serves both where one service gave both
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              led(found.by, measuredBy, credited([line, if (credit != null && !together) MapCredit(credit)])),
              const SizedBox(height: 2),
              led(
                now.by,
                saidBy,
                credited([
                  traffic,
                  if (now.credit case final name?)
                    MapCredit(name, mark: ValueKey(together ? 'fee-lookup-credit' : 'fee-lookup-now-credit')),
                ]),
              ),
            ],
          );
        }
        if (together) return credited([line, traffic, if (credit != null) MapCredit(credit)]);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            credited([line, if (credit != null) MapCredit(credit)]),
            const SizedBox(height: 2),
            credited([
              traffic,
              if (now.credit case final name?) MapCredit(name, mark: const ValueKey('fee-lookup-now-credit')),
            ]),
          ],
        );
      }
      final button = TextButton.icon(
        key: const ValueKey('fee-lookup'),
        onPressed: oneLine(address).isEmpty ? null : () => onLookUp(),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
        icon: const Icon(Icons.route_outlined, size: 18),
        label: Text(problem == null ? 'Look up the distance' : 'Try again'),
      );
      if (problem == null) return Align(alignment: Alignment.centerLeft, child: button);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            problem,
            key: const ValueKey('fee-lookup-problem'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
          button,
        ],
      );
    },
  );
}

/// A map service's name beside its figures, where its terms ask for it wherever they are shown without
/// its map (docs/delivery.md, "A second map service"). Google's guide for the words "Google Maps" is what
/// this follows: the words as they are, on one line that is never broken, Roboto where the device has it
/// and its own plain face where not, regular weight, 12 points that grow with the reader's type, and white
/// on a dark screen or its gray on a light one.
class MapCredit extends StatelessWidget {
  const MapCredit(this.name, {super.key, this.mark = const ValueKey('fee-lookup-credit')});

  /// The service's name in its own words, as the hub sends it.
  final String name;

  /// The key its words are found by.
  final Key mark;

  /// The gray Google's guide lists for a light background, and the white for a dark one.
  static const onLight = Color(0xFF5E5E5E);
  static const onDark = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) => Text(
    name,
    key: mark,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.visible,
    style: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 12,
      height: 1.3,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
      letterSpacing: 0,
      color: Theme.of(context).brightness == Brightness.dark ? onDark : onLight,
    ),
  );
}
