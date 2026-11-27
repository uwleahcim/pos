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
/// key for it) and, where the hub has a key, a button that tries it before it is turned on. Where the hub
/// keeps the order as the location's own, each also has a handle, and a drag by it puts the service earlier
/// or later (the owner's words, 2026-11-25: "dragging provider arrangements/order to determine the priority
/// of which service is used first").
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

  /// The services' names in the order they are asked, as a drag left it.
  late final List<String> _order = [for (final service in widget.setting.services) service.name];

  /// A drag changes the order: the hub keeps one, and there is more than one service to put in it.
  bool get _drags => widget.setting.ordered && widget.setting.services.length > 1;

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
      final saved = await widget.api.saveAddressList(
        widget.token,
        widget.setting.turned(_on, near: _near, order: _order),
      );
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

  /// One service: its name with the switch, how it stands, and the button that tries it where the hub has a
  /// key for it. Where it stands in the list says when it is asked, so no number is put before its name.
  /// [index] is where it stands in the order, from 0. With [handle], a handle before its badge moves it in
  /// the order.
  Widget _service(BuildContext context, int index, AddressService service, {bool handle = false}) {
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
    final tile = SwitchListTile(
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
      title: Text(service.title, key: ValueKey('address-list-name:${service.name}')),
      subtitle: Text(
        now.words,
        key: ValueKey('address-list-state:${service.name}'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: service.key && (now.usedUp || (on && now.resting)) ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (handle)
          Row(
            children: [
              // flush with the words above and below it; the room to its right and above and below is its too
              ReorderableDragStartListener(
                index: index,
                enabled: _busy != 'save',
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    key: ValueKey('address-list-handle:${service.name}'),
                    padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                    child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              Expanded(child: tile),
            ],
          )
        else
          tile,
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

  /// How much room the slider keeps on either side of its track, for its thumb.
  static const _trackSide = 16.0;

  /// How far "nearby" reaches: a slider, the distance in words beside its name, and a line on what it does.
  /// Its stops are not evenly far apart in miles (`AddressListSetting.nearStops`): a quarter of a mile up
  /// close, then half a mile, a mile and two, so what is close by takes most of it; a few distances are named
  /// under it. What is saved is said as it is even where the slider has no such stop (a distance set some
  /// other way, like 2.6 or 25 miles): the slider then stands at its nearest stop, and a save keeps what was
  /// saved until somebody moves it.
  Widget _nearby(BuildContext context, double near) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final last = AddressListSetting.nearStops.length - 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text('Nearby first', style: theme.textTheme.titleSmall)),
            Text(
              AddressListSetting.miles(near),
              key: const ValueKey('address-list-near-miles'),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context)
              .copyWith(overlayShape: const RoundSliderOverlayShape(overlayRadius: _trackSide)),
          child: Slider(
            key: const ValueKey('address-list-near'),
            value: AddressListSetting.nearPlace(near),
            max: last,
            divisions: last.round(),
            label: AddressListSetting.miles(near),
            semanticFormatterCallback: (place) => AddressListSetting.miles(AddressListSetting.nearAt(place)),
            onChanged: _busy == 'save' ? null : (to) => setState(() => _near = AddressListSetting.nearAt(to)),
          ),
        ),
        _scale(context, last),
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

  /// The slider's scale: a few distances in miles, each under its stop, which shows how much of the slider
  /// the first miles take.
  Widget _scale(BuildContext context, double last) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final high = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 11) * 1.4;
    const wide = 36.0;
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, box) {
          final track = box.maxWidth - 2 * _trackSide;
          return SizedBox(
            height: high,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (final miles in AddressListSetting.nearMarks)
                  Positioned(
                    left: _trackSide + track * AddressListSetting.nearPlace(miles) / last - wide / 2,
                    width: wide,
                    top: 0,
                    child: Text(
                      '${miles.round()}',
                      key: ValueKey('address-list-near-mark:${miles.round()}'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      style: style,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A service's row while it is dragged: lifted off the dialog, on the dialog's own ground.
  Widget _dragged(Widget child, int index, Animation<double> animation) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Material(
        elevation: 6 * Curves.easeInOut.transform(animation.value),
        color: theme.dialogTheme.backgroundColor ?? theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final near = _near;
    final services = [for (final name in _order) ?widget.setting.named(name)];
    final several = services.length > 1;
    final drags = _drags;
    final any = _on.values.any((on) => on);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24), // a phone keeps its width
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
                          'answering.${drags ? ' Drag one by its handle to put it earlier or later.' : ''}'
                    : 'For new addresses a map service is asked.',
                key: const ValueKey('address-list-order'),
                style: theme.textTheme.bodyMedium,
              ),
              if (drags)
                // each with the line under it, so a row that is being dragged looks like one that is not
                ReorderableListView.builder(
                  key: const ValueKey('address-list-services'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  proxyDecorator: _dragged,
                  itemCount: services.length,
                  onReorderItem: (from, to) => setState(() => _order.insert(to, _order.removeAt(from))),
                  itemBuilder: (context, index) => Column(
                    key: ValueKey('address-list-row:${services[index].name}'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [_service(context, index, services[index], handle: true), const Divider(height: 12)],
                  ),
                )
              else
                for (final (index, service) in services.indexed) ...[
                  if (index > 0) const Divider(height: 12),
                  _service(context, index, service),
                ],
              if (near != null) ...[if (!drags) const Divider(height: 16), _nearby(context, near)],
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
