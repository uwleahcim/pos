import 'package:flutter/material.dart';

import '../api.dart';
import '../delivery_fee.dart';
import '../takeout.dart';

/// How far a form's delivery goes, asked of the hub (docs/delivery.md, "Looking the distance up"). The hub
/// asks its map service, and is sent the address alone. A form asks when the address is done being typed,
/// and once per address: the same one is not asked twice, and one that failed is asked again only when
/// somebody says so.
class DistanceAsker extends ChangeNotifier {
  /// How the hub is asked (`PosApi.deliveryDistance`); null while this location looks nothing up.
  Future<FeeLookup> Function(String address)? source;

  /// Whether there is anything to ask.
  bool get can => source != null;

  String? _address;
  int _turn = 0;
  bool _gone = false;

  /// The hub was asked and has not answered yet.
  bool get asking => _asking;
  bool _asking = false;

  /// What the hub said of the address asked last.
  FeeLookup? get found => _found;
  FeeLookup? _found;

  /// Why there is no distance, in words for the form.
  String? get problem => _problem;
  String? _problem;

  /// What the map said of [address], when that is the address it was asked about.
  Measured? measuredFor(String address) => _found != null && _address == oneLine(address) ? _found!.measured : null;

  /// Asks how far [address] is. The answer, or null when there is nothing to ask, the address was asked
  /// already (unless [again]), no distance came of it, or the form has moved on meanwhile.
  Future<FeeLookup?> ask(String address, {bool again = false}) async {
    final source = this.source, line = oneLine(address);
    if (source == null || line.isEmpty) return null;
    if (line == _address && (_asking || (!again && (_found != null || _problem != null)))) return null;
    final turn = ++_turn;
    _address = line;
    _asking = true;
    _found = null;
    _problem = null;
    notifyListeners();
    FeeLookup? answer;
    String? problem;
    try {
      answer = await source(line);
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

/// The line over a delivery's prices that says how far the address is: what the map said, that it is being
/// asked, why there is no answer, or a button that asks.
class FeeLookupLine extends StatelessWidget {
  const FeeLookupLine({super.key, required this.asker, required this.address, required this.onLookUp});

  final DistanceAsker asker;

  /// What the form holds as the address now.
  final String address;

  /// Somebody asked for the distance, or for another try.
  final VoidCallback onLookUp;

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
        return Text(
          found.beyond
              ? '${found.measured.words} drive: further than the prices reach'
              : '${found.measured.words} drive',
          key: const ValueKey('fee-lookup-found'),
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        );
      }
      final button = TextButton.icon(
        key: const ValueKey('fee-lookup'),
        onPressed: oneLine(address).isEmpty ? null : onLookUp,
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
