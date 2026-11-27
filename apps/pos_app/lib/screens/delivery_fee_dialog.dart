import 'package:flutter/material.dart';

import '../api.dart';
import '../delivery_fee.dart';
import '../drive_lookups.dart';
import '../takeout.dart';
import 'address_box.dart';
import 'drive_services.dart';

/// What a delivery costs the customer, as a manager sets it for the location (docs/delivery.md, "The
/// delivery fee"): whether a fee is charged at all, whether it goes by miles or by the minutes of the drive,
/// the prices ("up to 2.5 mi, $5.00") and whether sales tax is charged on it. Saved on the hub; every screen
/// offers the prices from its next delivery, and an order already taken keeps the fee it was given.
///
/// Miles may be a fraction of a mile, to a hundredth ("up to 0.25 mi"), and the prices keep themselves
/// nearest first: a row goes to its place as soon as whoever types is done with it (the owner's words,
/// 2026-11-27: "Allow fractional miles like 0.25 miles. Also the list of the delivery distance should auto
/// sort by distance").
///
/// A delivery that goes further than the last price reaches has no price on the list. A switch says whether
/// whoever takes the order may then type what it costs ("A custom fee for a delivery further away"; the
/// owner's words, 2026-11-27: "Allow custom delivery fee for distance more than the max delivery fee distance
/// in the delivery fee settings"). On unless it is turned off; a hub older than it shows no switch.
///
/// On a hub that can look a delivery's distance up ("Looking the distance up") the dialog also holds the
/// restaurant's own address, where every delivery starts, and says whether the hub has a map service.
///
/// Where the hub says which map services it can ask and in which order ([lookups], "Which service is asked
/// first"), they stand under that heading as rows: a drag by a row's handle puts a service earlier or
/// later, its switch turns it on or off, and its badge and the line under its name say how many of its
/// day's lookups are left (the owner's words, 2026-11-25: "Apply these concepts to other api services").
/// Save keeps the order with the prices.
class DeliveryFeeDialog extends StatefulWidget {
  const DeliveryFeeDialog({super.key, required this.api, required this.token, required this.fees, this.lookups});

  final PosApi api;
  final String token;
  final DeliveryFees fees;

  /// The map services the hub can ask how far a delivery goes, in the order it asks them; null from a hub
  /// older than the order, which shows none.
  final DriveOrder? lookups;

  @override
  State<DeliveryFeeDialog> createState() => _DeliveryFeeDialogState();
}

/// One price as the dialog edits it, with a key for its row.
class _Band {
  _Band(this.key, String upTo, String fee)
    : upTo = TextEditingController(text: upTo),
      fee = TextEditingController(text: fee);
  final int key;
  final TextEditingController upTo;
  final TextEditingController fee;
}

class _DeliveryFeeDialogState extends State<DeliveryFeeDialog> {
  late bool _enabled = widget.fees.enabled;
  late String _by = widget.fees.by;
  late bool _taxed = widget.fees.taxed;
  late bool? _custom = widget.fees.custom; // null: a hub older than the custom fee, which is not told of one
  late final _origin = TextEditingController(text: widget.fees.origin);

  /// The map services' names in the order they are asked, as a drag left it, and each one's switch.
  late final List<String> _order = [for (final service in widget.lookups?.services ?? const []) service.name];
  late final Map<String, bool> _on = {
    for (final service in widget.lookups?.services ?? const <DriveService>[]) service.name: service.on,
  };
  final _bands = <_Band>[];
  final _removed = <_Band>[]; // off the list, their text boxes still leaving the screen
  int _added = 0; // rows made so far: the next row's key, never one a removed row had
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final band in widget.fees.bands) {
      _bands.add(_Band(_added++, band.upTo, band.fee));
    }
    _place();
  }

  /// How far a row reaches as it stands, for its place in the list; null while it holds no distance (a row
  /// just added, a number half typed).
  static double? _far(_Band band) {
    final number = double.tryParse(band.upTo.text.trim());
    return number == null || number.isNaN || number <= 0 ? null : number;
  }

  /// Puts the rows nearest first, as the hub keeps them and every delivery offers them. A row with no
  /// distance yet waits under the ones that have one, and rows that reach the same stay as they stood.
  /// True when a row moved.
  bool _place() {
    final placed = [for (final (i, band) in _bands.indexed) (far: _far(band), at: i, band: band)]
      ..sort((a, b) {
        final (one, other) = (a.far, b.far);
        final byReach = one == null || other == null
            ? (one == null ? 1 : 0) - (other == null ? 1 : 0)
            : one.compareTo(other);
        return byReach != 0 ? byReach : a.at.compareTo(b.at);
      });
    if (placed.indexed.every((entry) => entry.$2.at == entry.$1)) return false;
    _bands.setAll(0, [for (final row in placed) row.band]);
    return true;
  }

  /// Whoever types has left a row (for another box, or the keyboard was put away): it goes to its place.
  /// Not while they are still in it, so no row moves under a number that is half typed.
  void _left() {
    if (mounted && _place()) setState(() {});
  }

  @override
  void dispose() {
    for (final band in [..._bands, ..._removed]) {
      band.upTo.dispose();
      band.fee.dispose();
    }
    _origin.dispose();
    super.dispose();
  }

  /// A reach as the hub takes it: miles to a hundredth (0.25, 2.5), whole minutes, above nothing.
  bool _reach(String text) {
    final number = double.tryParse(text);
    if (number == null || number.isNaN || number <= 0) return false;
    return _by == 'minutes'
        ? number == number.roundToDouble() && number <= 240
        : (number * 100 - (number * 100).roundToDouble()).abs() < 1e-9 && number <= 100;
  }

  /// A fee as the hub takes it: dollars and cents, nothing below zero.
  static bool _money(String text) => RegExp(r'^\d{1,3}(\.\d{1,2})?$').hasMatch(text);

  Future<void> _save() async {
    final reaches = [for (final band in _bands) band.upTo.text.trim()];
    final fees = [for (final band in _bands) band.fee.text.trim().replaceFirst(RegExp(r'^\$'), '')];
    final unit = _by == 'minutes' ? 'minutes' : 'miles';
    String? problem;
    if (_enabled && _bands.isEmpty) {
      problem = 'List at least one distance and what it costs, or turn the fee off';
    } else if (!reaches.every(_reach)) {
      problem = _by == 'minutes'
          ? 'How far a price reaches is a whole number of minutes, such as 15'
          : 'How far a price reaches is a number of miles, such as 2, 2.5 or 0.25';
    } else if (!fees.every(_money)) {
      problem = 'A fee is dollars and cents, such as 5 or 4.50';
    } else if (reaches.map(double.parse).toSet().length != reaches.length) {
      problem = 'Two prices reach the same number of $unit';
    }
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // the order first: the fee's answer then says who is asked now
      final lookups = widget.lookups, wanted = lookups?.turned(_on, _order);
      if (lookups != null && wanted != null && !wanted.sameAs(lookups)) {
        await widget.api.saveDriveLookups(widget.token, distance: wanted);
      }
      final saved = await widget.api.saveDeliveryFees(
        widget.token,
        DeliveryFees(
          enabled: _enabled,
          by: _by,
          taxed: _taxed,
          custom: _custom,
          bands: [for (final (i, reach) in reaches.indexed) FeeBand(upTo: reach, fee: fees[i])],
          // a hub older than the lookup shows no box for it: what it holds is left as it is
          origin: widget.fees.maps == null ? widget.fees.origin : oneLine(_origin.text),
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = err.detail?['message'] as String? ?? err.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unit = feeUnit(_by);
    final lookups = widget.lookups?.turned(_on, _order);
    // the ones that are asked the drive between two places, and so search for the address first
    final finds = lookups?.asking.any((service) => service.name == 'mapbox' || service.name == 'azure') ?? false;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return AlertDialog(
      title: const Text('Delivery fee'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('fee-enabled'),
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (on) => setState(() => _enabled = on),
                title: const Text('Charge for delivery'),
                subtitle: Text(
                  _enabled
                      ? 'Whoever takes a delivery picks its price, and it goes on the check as "Delivery fee"'
                      : 'Nothing is added to a delivery for the trip',
                ),
              ),
              const SizedBox(height: 8),
              Text('The fee goes by', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                key: const ValueKey('fee-by'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'miles', label: Text('Miles')),
                  ButtonSegment(value: 'minutes', label: Text('Minutes of the drive')),
                ],
                selected: {_by},
                onSelectionChanged: (to) => setState(() => _by = to.first),
              ),
              const SizedBox(height: 12),
              Text('The prices', style: theme.textTheme.titleSmall),
              Text(
                'Nearest first. Up to ${DeliveryFees.mostButtons} are a button each on a delivery; more are one line '
                'that opens the whole list. "No fee" is always a choice.',
                key: const ValueKey('fee-bands-says'),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final band in _bands)
                Focus(
                  key: ValueKey('fee-band-row:${band.key}'),
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: (inside) => inside ? null : _left(),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: ValueKey('fee-band-reach:${band.key}'),
                            controller: band.upTo,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(isDense: true, labelText: 'Up to', suffixText: unit),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            key: ValueKey('fee-band-fee:${band.key}'),
                            controller: band.fee,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(isDense: true, labelText: 'Fee', prefixText: '\$'),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('fee-band-remove:${band.key}'),
                          tooltip: 'Remove this price',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() {
                            _bands.remove(band);
                            _removed.add(band);
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('fee-band-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a price'),
                  onPressed: _bands.length >= DeliveryFees.mostBands
                      ? null
                      : () => setState(() {
                          _place(); // the row typed last goes to its place, and the new one waits under them all
                          _bands.add(_Band(_added++, '', ''));
                        }),
                ),
              ),
              if (_custom case final custom?)
                SwitchListTile(
                  key: const ValueKey('fee-custom'),
                  contentPadding: EdgeInsets.zero,
                  value: custom,
                  onChanged: (on) => setState(() => _custom = on),
                  title: const Text('Custom fee past the last distance'),
                  subtitle: Text(
                    custom
                        ? 'For a delivery further than the last price reaches, whoever takes the order types what '
                              'it costs'
                        : 'A delivery further than the last price reaches is charged one of the prices, or no fee',
                  ),
                ),
              SwitchListTile(
                key: const ValueKey('fee-taxed'),
                contentPadding: EdgeInsets.zero,
                value: _taxed,
                onChanged: (on) => setState(() => _taxed = on),
                title: const Text('Charge sales tax on the fee'),
                subtitle: Text(
                  _taxed
                      ? 'The fee is taxed like the food. Ask your accountant which is right for you'
                      : 'The fee is not taxed. Ask your accountant which is right for you',
                ),
              ),
              if (widget.fees.maps case final maps?) ...[
                const SizedBox(height: 8),
                Text('Looking the distance up', style: theme.textTheme.titleSmall),
                if (lookups != null && lookups.services.isNotEmpty) ...[
                  Text(
                    !lookups.services.any((service) => service.key)
                        ? 'This hub has no key for a map service yet, so the price is picked by hand (Keys and '
                              'connections, on this screen). The address can be typed now, and is used from the '
                              'day the hub has one.'
                        : 'With the address below, the hub asks a map service how far a delivery is and the form '
                              'picks the price. They are asked in this order: the next one only when the one '
                              'before it gives no distance. Drag one by its handle to put it earlier or later. '
                              'Each is sent the two addresses and nothing else.',
                    key: const ValueKey('fee-maps'),
                    style: quiet,
                  ),
                  DriveServicesList(
                    mark: 'fee-services',
                    services: lookups.services,
                    enabled: !_busy,
                    onMoved: (from, to) => setState(() => _order.insert(to, _order.removeAt(from))),
                    onTurned: (name, on) => setState(() => _on[name] = on),
                  ),
                  if (lookups.services.any((service) => service.key) && lookups.asking.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'None that is turned on has a key: the price is picked by hand.',
                        key: const ValueKey('fee-services-none'),
                        style: quiet?.copyWith(color: scheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'The hub counts what it asks each day and stops at each one\'s number, so a busy night '
                      'cannot run up a bill.${finds ? ' Mapbox and Azure Maps first look up where the address is, which uses the same free lookups as the Address list.' : ''}',
                      key: const ValueKey('fee-services-says'),
                      style: quiet,
                    ),
                  ),
                ] else
                  Text(
                    !maps
                        ? 'This hub has no map service yet, so the price is picked by hand (Keys and connections, on this screen). '
                              'The address can be typed now, and is used from the day the hub has one.'
                        : widget.fees.services.length < 2
                        ? 'With the address below, the hub asks its map service how far a delivery is and the '
                              'form picks the price. The service is sent the two addresses and nothing else.'
                        : 'With the address below, the hub asks ${mapServiceName(widget.fees.services[0])} how far '
                              'a delivery is, and ${mapServiceName(widget.fees.services[1])} when that gives no '
                              'distance. The form picks the price. Each is sent the two addresses and nothing else.',
                    key: const ValueKey('fee-maps'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 8),
                // the list under it holds no customer's delivery: a map service's answers, where that is on
                AddressBox(
                  fieldKey: const ValueKey('fee-origin'),
                  controller: _origin,
                  source: (typed) => widget.api.suggestAddresses(typed, own: false),
                  maxLength: 200,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Restaurant address',
                    hintText: 'Street, town, state',
                    counterText: '',
                  ),
                ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('fee-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('fee-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
