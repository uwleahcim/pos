import 'package:flutter/material.dart';

import '../address_list.dart';
import '../api.dart';
import 'fee_lookup.dart';

/// The list of addresses under a box that is being typed in, as a manager sets it for the location
/// (docs/delivery.md, "A list of addresses while typing"): whether a map service is asked as well as the
/// restaurant's own earlier deliveries. Saved on the hub; every screen lists by it from the next letter.
///
/// It says what leaves the building when it is on, lets the manager try the service before turning it on,
/// and says what is missing when the hub has no key for it.
class AddressListDialog extends StatefulWidget {
  const AddressListDialog({super.key, required this.api, required this.token, required this.setting});

  final PosApi api;
  final String token;
  final AddressListSetting setting;

  /// One line on the list for the Location screen.
  static String summary(AddressListSetting? setting) {
    if (setting == null) return 'The hub has not answered about the list of addresses (an older hub: update it)';
    if (!setting.google) return 'Your own earlier deliveries are listed while an address is typed';
    if (!setting.service) return 'On, but not used yet: this hub has no Google Maps key';
    return 'Your own earlier deliveries, then ${setting.credit}, are listed while an address is typed';
  }

  @override
  State<AddressListDialog> createState() => _AddressListDialogState();
}

class _AddressListDialogState extends State<AddressListDialog> {
  late bool _google = widget.setting.google;
  String? _message;
  String? _tried;
  bool _triedWell = false;
  bool _busy = false;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveAddressList(widget.token, AddressListSetting(google: _google));
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

  Future<void> _try() async {
    setState(() {
      _busy = true;
      _tried = null;
    });
    String said;
    var well = false;
    try {
      final tried = await widget.api.tryAddressList(widget.token);
      well = tried.ok;
      said = tried.ok
          ? tried.found == 0
                ? 'Google answered, and listed nothing for the restaurant\'s own address.'
                : 'Google answered: it lists addresses for this hub.'
          : tried.message.isEmpty
          ? 'Google gave no list.'
          : tried.message;
    } on ApiException catch (err) {
      said = err.status == null
          ? 'The hub is not answering.'
          : err.detail?['message'] as String? ?? 'It could not be tried.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _tried = said;
      _triedWell = well;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final service = widget.setting.service;
    final name = widget.setting.credit;
    return AlertDialog(
      title: const Text('Address list'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'While somebody types an address, a list under the box says what it could become. A tap puts '
                'one in. The addresses your own deliveries went to in the past year are always listed: that '
                'costs nothing and asks nobody.',
                key: const ValueKey('address-list-says'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey('address-list-google'),
                contentPadding: EdgeInsets.zero,
                value: _google,
                onChanged: (on) => setState(() => _google = on),
                title: Text('Ask $name for new addresses'),
                subtitle: Text(
                  _google
                      ? 'What is typed in an address box is sent to Google, from the fourth letter'
                      : 'Off: nothing that is typed leaves the building',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                !service
                    ? 'This hub has no Google Maps key yet (Keys and connections, on this screen). It can be '
                          'turned on now, and is used from the day the key is there. The key has to be allowed '
                          'to use Places API (New).'
                    : 'Google is sent the letters typed, and once the restaurant\'s own address so that streets '
                          'nearby come first. Nothing else: no name, no phone number, nothing of the order. Its '
                          'answers are shown with its name and are not kept. Google may charge for it beyond '
                          'what it gives away each month, so the hub asks at most a few hundred times a day. '
                          'The hub\'s Google key has to be allowed to use Places API (New).',
                key: const ValueKey('address-list-sent'),
                style: quiet,
              ),
              if (service) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('address-list-try'),
                      onPressed: _busy ? null : _try,
                      icon: const Icon(Icons.play_arrow_outlined, size: 18),
                      label: const Text('Try it'),
                    ),
                    MapCredit(name, mark: const ValueKey('address-list-credit')),
                  ],
                ),
                if (_tried != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _tried!,
                      key: const ValueKey('address-list-tried'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: _triedWell ? null : scheme.error),
                    ),
                  ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('address-list-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('address-list-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
