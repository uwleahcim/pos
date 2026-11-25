import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../delivery_fee.dart';
import '../drive_lookups.dart';
import 'drive_services.dart';

/// Live traffic for deliveries, as a manager sets it for the location (docs/delivery.md, "Live traffic"):
/// whether a delivery for now is promised by the roads as they are, and the minutes the kitchen needs
/// before the drive. Saved on the hub; every screen promises by it from its next delivery, and an order
/// already taken keeps the time it was promised.
///
/// It says what is still missing for it: a map service on the hub that knows the roads right now, the
/// restaurant's own address, or a delivery fee with prices ([priced]), whose distance lookup the drive is
/// asked beside.
///
/// Where the hub says which map services know the roads right now and in which order it asks them
/// ([lookups], "Which service is asked first"), they stand in the dialog as rows: a drag by a row's handle
/// puts a service earlier or later, its switch turns it on or off, and its badge and the line under its
/// name say how many of its day's lookups are left. Save keeps the order with the rest.
class LiveDriveDialog extends StatefulWidget {
  const LiveDriveDialog({
    super.key,
    required this.api,
    required this.token,
    required this.setting,
    this.priced = true,
    this.delivery = 45,
    this.lookups,
  });

  final PosApi api;
  final String token;
  final LiveDrive setting;

  /// The map services the hub can ask about the roads right now, in the order it asks them; null from a
  /// hub older than the order, which asks Google Maps alone and shows no list.
  final DriveOrder? lookups;

  /// Whether the location charges a delivery fee with prices to pick from: only then a form asks the hub
  /// about an address at all.
  final bool priced;

  /// The minutes set for Delivery under Quote times: what a delivery is promised while this is off, and
  /// whenever nobody can say how the roads are.
  final int delivery;

  /// What is still missing before a delivery is promised by the roads, in words; null when nothing is.
  /// With [lookups], the services that know the roads as the hub lists them, the words say which of the
  /// two a service lacks: a key, or being turned on.
  static String? missing(LiveDrive setting, {required bool priced, DriveOrder? lookups}) => !setting.traffic
      ? lookups == null || lookups.services.isEmpty
            ? 'This hub has no Google Maps key yet, and only Google Maps knows the roads right now (Keys and connections, on this screen).'
            : lookups.services.any((service) => service.key)
            ? 'No map service that has a key on this hub is turned on for the roads (Live traffic, on this screen).'
            : 'This hub has no key yet for a map service that knows the roads right now: '
                  '${_or([for (final service in lookups.services) service.title])} (Keys and connections, on this screen).'
      : !setting.origin
      ? 'The restaurant\'s address is not set yet (Delivery fee, on this screen).'
      : !priced
      ? 'The delivery fee is off or has no prices (Delivery fee, on this screen). The drive is asked about '
            'together with the distance for the fee.'
      : null;

  /// "Google Maps, Mapbox or Azure Maps".
  static String _or(List<String> names) =>
      names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}';

  @override
  State<LiveDriveDialog> createState() => _LiveDriveDialogState();
}

class _LiveDriveDialogState extends State<LiveDriveDialog> {
  late bool _enabled = widget.setting.enabled;
  late final _before = TextEditingController(text: '${widget.setting.before}');

  /// The map services' names in the order they are asked, as a drag left it, and each one's switch.
  late final List<String> _order = [for (final service in widget.lookups?.services ?? const []) service.name];
  late final Map<String, bool> _on = {
    for (final service in widget.lookups?.services ?? const <DriveService>[]) service.name: service.on,
  };
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
      // the order first: live traffic's answer then says whether there is somebody to ask
      final lookups = widget.lookups, wanted = lookups?.turned(_on, _order);
      if (lookups != null && wanted != null && !wanted.sameAs(lookups)) {
        await widget.api.saveDriveLookups(widget.token, traffic: wanted);
      }
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
    final lookups = widget.lookups?.turned(_on, _order);
    final listed = lookups != null && lookups.services.isNotEmpty;
    // as the dialog stands now: a switch that was just turned says whether there is somebody to ask
    final setting = !listed
        ? widget.setting
        : LiveDrive(
            enabled: widget.setting.enabled,
            before: widget.setting.before,
            traffic: lookups.asking.isNotEmpty,
            origin: widget.setting.origin,
          );
    final missing = LiveDriveDialog.missing(setting, priced: widget.priced, lookups: lookups);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return AlertDialog(
      title: const Text('Live traffic'),
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
              if (listed) ...[
                Text('Who is asked about the roads', style: theme.textTheme.titleSmall),
                Text(
                  'In this order: the next one only when the one before it gives no answer. Drag one by its '
                  'handle to put it earlier or later.',
                  key: const ValueKey('live-services-order'),
                  style: quiet,
                ),
                DriveServicesList(
                  mark: 'live-services',
                  services: lookups.services,
                  enabled: !_busy,
                  onMoved: (from, to) => setState(() => _order.insert(to, _order.removeAt(from))),
                  onTurned: (name, on) => setState(() => _on[name] = on),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                missing != null
                    ? '$missing It can be turned on now, and is used from the day that is there. Until then a '
                          'delivery is promised the ${widget.delivery} minutes set for Delivery.'
                    : listed
                    ? 'Each delivery for now asks one of them once how long the drive is at that minute. It is '
                          'sent the two addresses and nothing else. The hub counts what it asks each day and '
                          'stops at each one\'s number, so a busy night cannot run up a bill. The fee does not '
                          'change, and an order for later is not asked about. When nobody can say, a delivery '
                          'is promised the ${widget.delivery} minutes set for Delivery.'
                    : 'Each delivery for now asks Google Maps once how long the drive is at that minute. It is '
                          'sent the two addresses and nothing else, and Google may charge for it beyond what it '
                          'gives away each month. The fee does not change, and an order for later is not asked '
                          'about. When nobody can say, a delivery is promised the ${widget.delivery} minutes set '
                          'for Delivery.',
                key: const ValueKey('live-says'),
                style: quiet?.copyWith(color: missing != null && listed ? scheme.error : null),
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
