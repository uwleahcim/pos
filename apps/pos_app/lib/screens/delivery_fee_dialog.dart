import 'package:flutter/material.dart';

import '../api.dart';
import '../delivery_fee.dart';
import '../takeout.dart';

/// What a delivery costs the customer, as a manager sets it for the location (docs/delivery.md, "The
/// delivery fee"): whether a fee is charged at all, whether it goes by miles or by the minutes of the drive,
/// the prices ("up to 2.5 mi, $5.00") and whether sales tax is charged on it. Saved on the hub; every screen
/// offers the prices from its next delivery, and an order already taken keeps the fee it was given.
///
/// On a hub that can look a delivery's distance up ("Looking the distance up") the dialog also holds the
/// restaurant's own address, where every delivery starts, and says whether the hub has a map service.
class DeliveryFeeDialog extends StatefulWidget {
  const DeliveryFeeDialog({super.key, required this.api, required this.token, required this.fees});

  final PosApi api;
  final String token;
  final DeliveryFees fees;

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
  late final _origin = TextEditingController(text: widget.fees.origin);
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

  /// A reach as the hub takes it: miles to a tenth, whole minutes, above nothing.
  bool _reach(String text) {
    final number = double.tryParse(text);
    if (number == null || number <= 0) return false;
    return _by == 'minutes'
        ? number == number.roundToDouble() && number <= 240
        : (number * 10 - (number * 10).roundToDouble()).abs() < 1e-9 && number <= 100;
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
          : 'How far a price reaches is a number of miles, such as 2 or 2.5';
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
      final saved = await widget.api.saveDeliveryFees(
        widget.token,
        DeliveryFees(
          enabled: _enabled,
          by: _by,
          taxed: _taxed,
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
                'One button each on a delivery, nearest first. "No fee" is always a button.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final band in _bands)
                Padding(
                  key: ValueKey('fee-band-row:${band.key}'),
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
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('fee-band-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a price'),
                  onPressed: _bands.length >= DeliveryFees.mostBands
                      ? null
                      : () => setState(() => _bands.add(_Band(_added++, '', ''))),
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
                Text(
                  !maps
                      ? 'This hub has no map service yet, so the price is picked by hand (hubctl maps key). '
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
                TextField(
                  key: const ValueKey('fee-origin'),
                  controller: _origin,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.words,
                  keyboardType: TextInputType.streetAddress,
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
