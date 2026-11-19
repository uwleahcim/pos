import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../delivery_fee.dart';

/// Live traffic for deliveries, as a manager sets it for the location (docs/delivery.md, "Live traffic"):
/// whether a delivery for now is promised by the roads as they are, and the minutes the kitchen needs
/// before the drive. Saved on the hub; every screen promises by it from its next delivery, and an order
/// already taken keeps the time it was promised.
///
/// It says what is still missing for it: a map service on the hub that knows the roads right now, the
/// restaurant's own address, or a delivery fee with prices ([priced]), whose distance lookup the drive is
/// asked beside.
class LiveDriveDialog extends StatefulWidget {
  const LiveDriveDialog({
    super.key,
    required this.api,
    required this.token,
    required this.setting,
    this.priced = true,
    this.delivery = 45,
  });

  final PosApi api;
  final String token;
  final LiveDrive setting;

  /// Whether the location charges a delivery fee with prices to pick from: only then a form asks the hub
  /// about an address at all.
  final bool priced;

  /// The minutes set for Delivery under Quote times: what a delivery is promised while this is off, and
  /// whenever nobody can say how the roads are.
  final int delivery;

  /// What is still missing before a delivery is promised by the roads, in words; null when nothing is.
  static String? missing(LiveDrive setting, {required bool priced}) => !setting.traffic
      ? 'This hub has no Google Maps key yet, and only Google Maps knows the roads right now (hubctl maps google).'
      : !setting.origin
      ? 'The restaurant\'s address is not set yet (Delivery fee, on this screen).'
      : !priced
      ? 'The delivery fee is off or has no prices (Delivery fee, on this screen). The drive is asked about '
            'together with the distance for the fee.'
      : null;

  @override
  State<LiveDriveDialog> createState() => _LiveDriveDialogState();
}

class _LiveDriveDialogState extends State<LiveDriveDialog> {
  late bool _enabled = widget.setting.enabled;
  late final _before = TextEditingController(text: '${widget.setting.before}');
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _before.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final before = int.tryParse(_before.text.trim());
    if (before == null || before < 0 || before > LiveDrive.mostBefore) {
      setState(() => _message = 'The minutes are a whole number from 0 to ${LiveDrive.mostBefore}');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveLiveDrive(widget.token, LiveDrive(enabled: _enabled, before: before));
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
    final missing = LiveDriveDialog.missing(widget.setting, priced: widget.priced);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return AlertDialog(
      title: const Text('Live traffic'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('live-enabled'),
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (on) => setState(() => _enabled = on),
                title: const Text('Promise a delivery by the roads right now'),
                subtitle: Text(
                  _enabled
                      ? 'A delivery for now is promised the minutes below and the drive as it is at that minute'
                      : 'Off: a delivery is promised the ${widget.delivery} minutes set for Delivery (Quote times)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('live-before'),
                controller: _before,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Before the drive',
                  helperText: 'Minutes for the cooking, and getting it out of the door',
                  helperMaxLines: 3,
                  suffixText: 'min',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                missing != null
                    ? '$missing It can be turned on now, and is used from the day that is there. Until then a '
                          'delivery is promised the ${widget.delivery} minutes set for Delivery.'
                    : 'Each delivery for now asks Google Maps once how long the drive is at that minute. It is '
                          'sent the two addresses and nothing else, and Google may charge for it beyond what it '
                          'gives away each month. The fee does not change, and an order for later is not asked '
                          'about. When nobody can say, a delivery is promised the ${widget.delivery} minutes set '
                          'for Delivery.',
                key: const ValueKey('live-says'),
                style: quiet,
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('live-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('live-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
