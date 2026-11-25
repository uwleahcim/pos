import 'package:flutter/material.dart';

import '../address_list.dart';
import '../api.dart';
import 'service_badge.dart';

/// The list of addresses under a box that is being typed in, as a manager sets it for the location
/// (docs/delivery.md, "A list of addresses while typing"): which map services are asked as well as the
/// restaurant's own earlier deliveries. Saved on the hub; every screen lists by it from the next letter.
///
/// The services stand in the order they are asked: the first that is turned on and has a key, and the next
/// one only once the one before it has used up its free lookups for the month, or is not answering. Each
/// has its own switch, a line on how it stands (what it has left free this month, or that the hub has no
/// key for it) and, where the hub has a key, a button that tries it before it is turned on.
class AddressListDialog extends StatefulWidget {
  const AddressListDialog({super.key, required this.api, required this.token, required this.setting});

  final PosApi api;
  final String token;
  final AddressListSetting setting;

  /// One line on the list for the Location screen.
  static String summary(AddressListSetting? setting) {
    if (setting == null) return 'The hub has not answered about the list of addresses (an older hub: update it)';
    final on = setting.on, asking = setting.asking;
    if (on.isEmpty) return 'Your own earlier deliveries are listed while an address is typed';
    if (asking.isEmpty) {
      final missing = [for (final service in on) service.title].join(' or ');
      return on.length == 1 && on.single.name == 'google'
          ? 'On, but not used yet: this hub has no Google Maps key'
          : 'On, but not used yet: this hub has no key for $missing';
    }
    final after = [for (final service in asking.skip(1)) service.title];
    final first = 'Your own earlier deliveries, then ${asking.first.title}, are listed while an address is typed';
    if (after.isEmpty) return first;
    return '$first. ${after.join(' and ')} ${after.length == 1 ? 'takes' : 'take'} over when it gives no list';
  }

  @override
  State<AddressListDialog> createState() => _AddressListDialogState();
}

class _AddressListDialogState extends State<AddressListDialog> {
  late final Map<String, bool> _on = {for (final service in widget.setting.services) service.name: service.on};

  /// How far around the restaurant addresses come first; null on a hub that does not say, which is offered
  /// no choice.
  late double? _near = widget.setting.nearMiles;

  /// What the hub said the lookups left free are, where a try just told it anew.
  final Map<String, int> _left = {};
  final Map<String, ({String words, bool well})> _tried = {};
  String? _message;
  String? _busy; // the service that is being tried, or `save`

  Future<void> _save() async {
    setState(() {
      _busy = 'save';
      _message = null;
    });
    try {
      final saved = await widget.api.saveAddressList(widget.token, widget.setting.turned(_on, near: _near));
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _busy = null;
          _message = err.detail?['message'] as String? ?? err.message;
        });
      }
    }
  }

  Future<void> _try(AddressService service) async {
    final who = service.title;
    setState(() {
      _busy = service.name;
      _tried.remove(service.name);
    });
    String said;
    var well = false;
    int? left;
    try {
      final tried = await widget.api.tryAddressList(widget.token, service: service.name);
      well = tried.ok;
      left = tried.left;
      said = tried.ok
          ? tried.found == 0
                ? '$who answered, and listed nothing for the restaurant\'s own address.'
                : '$who answered: it lists addresses for this hub.'
          : tried.message.isEmpty
          ? '$who gave no list.'
          : tried.message;
    } on ApiException catch (err) {
      said = err.status == null
          ? 'The hub is not answering.'
          : err.detail?['message'] as String? ?? 'It could not be tried.';
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _tried[service.name] = (words: said, well: well);
      if (left != null) _left[service.name] = left;
    });
  }

  /// One service: its place in the order and its name with the switch, how it stands, and the button that
  /// tries it where the hub has a key for it.
  Widget _service(BuildContext context, int place, AddressService service) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = _on[service.name] ?? false;
    final left = _left[service.name];
    final now = AddressService(
      name: service.name,
      title: service.title,
      credit: service.credit,
      on: on,
      key: service.key,
      left: left ?? service.left,
      monthlyMost: service.monthlyMost,
      usedUp: left == null ? service.usedUp : left < 1,
      resting: service.resting && !(_tried[service.name]?.well ?? false),
    );
    final tried = _tried[service.name];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: ValueKey('address-list-${service.name}'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          // the badge a list shows when this service answered it, with the same ring
          secondary: ServiceBadge(
            key: ValueKey('address-list-badge:${service.name}'),
            service: service.name,
            title: service.title,
            share: !service.key || now.left == null || now.monthlyMost == null
                ? null
                : (now.left! / now.monthlyMost!).clamp(0.0, 1.0),
            words: service.key ? now.words : null,
          ),
          value: on,
          onChanged: (to) => setState(() => _on[service.name] = to),
          title: Text('$place. ${service.title}'),
          subtitle: Text(
            now.words,
            key: ValueKey('address-list-state:${service.name}'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: service.key && (now.usedUp || (on && now.resting)) ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (service.key)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: ValueKey('address-list-try:${service.name}'),
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: _busy != null ? null : () => _try(service),
                icon: const Icon(Icons.play_arrow_outlined, size: 18),
                label: const Text('Try it'),
              ),
              if (_busy == service.name)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        if (tried != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tried.words,
              key: ValueKey('address-list-tried:${service.name}'),
              style: theme.textTheme.bodyMedium?.copyWith(color: tried.well ? null : scheme.error),
            ),
          ),
      ],
    );
  }

  /// How far "nearby" reaches: a row of distances to tap, and a line on what it does. What is saved stands
  /// among them even where it is none of the usual ones.
  Widget _nearby(BuildContext context, double near) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final saved = widget.setting.nearMiles;
    final choices = {...AddressListSetting.nearChoices, ?saved}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Nearby first', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final miles in choices)
              ChoiceChip(
                key: ValueKey('address-list-near:${miles == miles.roundToDouble() ? miles.round() : miles}'),
                label: Text(AddressListSetting.miles(miles)),
                selected: miles == near,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _near = miles),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.setting.originSet == false
              ? 'Addresses within ${AddressListSetting.miles(near)} of the restaurant come first, once its own '
                    'address is set under Location, Delivery fee. Until then a service goes by where the '
                    'hub\'s internet connection is.'
              : 'Addresses within ${AddressListSetting.miles(near)} of the restaurant come first. Ones further '
                    'out are still listed when the letters fit them.',
          key: const ValueKey('address-list-near-says'),
          style: widget.setting.originSet == false ? quiet?.copyWith(color: scheme.error) : quiet,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final near = _near;
    final services = widget.setting.services;
    final several = services.length > 1;
    final any = _on.values.any((on) => on);
    return AlertDialog(
      title: const Text('Address list'),
      content: SizedBox(
        width: 380,
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
              const SizedBox(height: 8),
              Text(
                several
                    ? 'For new addresses a map service is asked. They are asked in this order: the next one '
                          'only once the one before it has used up its free lookups for the month, or is not '
                          'answering.'
                    : 'For new addresses a map service is asked.',
                key: const ValueKey('address-list-order'),
                style: theme.textTheme.bodyMedium,
              ),
              for (final (index, service) in services.indexed) ...[
                if (index > 0) const Divider(height: 12),
                _service(context, index + 1, service),
              ],
              if (near != null) ...[const Divider(height: 16), _nearby(context, near)],
              const SizedBox(height: 8),
              Text(
                !any
                    ? 'All off: nothing that is typed leaves the building.'
                    : 'Whichever is asked is sent the letters typed, from the fourth letter, and nothing else: '
                          'no name, no phone number, nothing of the order. Each also learns where the '
                          'restaurant is, so that streets nearby come first. Answers are shown with the '
                          'service\'s name and are not kept. The hub counts what it asks and stops a little '
                          'short of what each gives away free each month, so the list costs nothing. The '
                          'badge at the top of a list says who answered and what it has left.',
                key: const ValueKey('address-list-sent'),
                style: quiet,
              ),
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
          onPressed: _busy != null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
