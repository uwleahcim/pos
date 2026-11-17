import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../dish_names.dart';
import '../menu.dart';
import '../menu_search.dart';
import '../waste.dart';

/// One size of one dish, as the search offers it.
class _Dish {
  const _Dish(this.entry, this.variant);
  final MenuEntry entry;
  final VariantOffer variant;

  /// The dish as a check names it: its size after it when it has several.
  String get name => entry.variants.length > 1 ? '${entry.name} (${variant.name})' : entry.name;
}

/// Writes one entry into the waste log (docs/waste-log.md): what it was, how many, and why. What it was is
/// found on the menu by typing, as a dish is on the order screen, or is simply what was typed when it is no
/// dish (a tray of rice). The reason is one of the location's. The entry is no sale and changes no check.
/// Pops the entry the hub wrote.
class WasteDialog extends StatefulWidget {
  const WasteDialog({super.key, required this.api, required this.staffId, required this.day, this.device});

  final PosApi api;

  /// Who is writing it: the person signed in at this screen.
  final String staffId;

  /// The day as the hub told it: the reasons to pick from, and how long a name and a note may be.
  final WasteDay day;
  final String? device;

  @override
  State<WasteDialog> createState() => _WasteDialogState();
}

class _WasteDialogState extends State<WasteDialog> {
  final _what = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _note = TextEditingController();
  MenuSearch<MenuEntry>? _menu;
  _Dish? _picked;
  String? _reason;
  String? _message;
  bool _busy = false;

  /// The most dishes offered under what is typed: the keyboard leaves a phone room for no more.
  static const _offered = 5;

  @override
  void initState() {
    super.initState();
    _readMenu();
  }

  @override
  void dispose() {
    _what.dispose();
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  /// The menu as this screen last read it: the dishes the search looks through. Without one (the hub
  /// away, and never read here) what was wasted is typed.
  Future<void> _readMenu() async {
    try {
      final (_, menus) = await widget.api.menus();
      if (!mounted) return;
      final dishes = [
        for (final menu in menus)
          for (final section in menu.sections)
            for (final entry in section.allEntries)
              if (!entry.asksName) entry, // an off-menu dish has no name of its own: it is typed here too
      ];
      setState(() {
        _menu = MenuSearch<MenuEntry>(
          dishes,
          (e) => SearchText(number: e.number, names: [e.name, e.secondName], labels: [e.kitchenName]),
        );
      });
    } on ApiException {
      // no menu: typed only
    }
  }

  /// The sizes of the dishes found for what is typed, each size once (a dish is on the lunch menu and the
  /// dinner menu), the best match first.
  List<_Dish> get _found {
    final typed = _what.text.trim();
    final menu = _menu;
    if (menu == null || typed.isEmpty || _picked != null) return const [];
    final seen = <String>{};
    final found = <_Dish>[];
    for (final entry in menu.find(typed)) {
      for (final variant in entry.variants) {
        if (seen.add(variant.variantId)) found.add(_Dish(entry, variant));
        if (found.length == _offered) return found;
      }
    }
    return found;
  }

  int? get _count {
    final qty = int.tryParse(_qty.text.trim());
    return qty == null || qty < 1 || qty > widget.day.qtyMax ? null : qty;
  }

  bool get _ready => (_picked != null || _what.text.trim().isNotEmpty) && _count != null && _reason != null;

  void _step(int by) {
    final next = ((_count ?? 1) + by).clamp(1, widget.day.qtyMax);
    setState(() => _qty.text = '$next');
  }

  Future<void> _save() async {
    final qty = _count, reason = _reason;
    if (qty == null || reason == null) return;
    final picked = _picked;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final entry = await widget.api.logWaste(
        staffId: widget.staffId,
        variantId: picked?.variant.variantId,
        entryId: picked?.entry.entryId,
        name: picked?.name ?? _what.text.trim(),
        qty: qty,
        reason: reason,
        note: _note.text.trim(),
        device: widget.device,
      );
      if (mounted) Navigator.of(context).pop(entry);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = switch (err.status) {
          null => 'The hub is not answering, so this was not written down. Try again.',
          404 when err.detail?['error'] != 'unknown_staff' => 'This hub is older than the waste log.',
          _ => err.detail?['message'] as String? ?? err.message,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final picked = _picked;
    final found = _found;
    final chinese = DishLanguage.chineseOf(context);
    final typedOnly = picked == null && _what.text.trim().isNotEmpty && found.isEmpty;
    return AlertDialog(
      title: const Text('Log waste'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // a phone keeps its width
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8), // room for the label of the first box
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (picked == null)
                TextField(
                  key: const ValueKey('waste-what'),
                  controller: _what,
                  autofocus: true,
                  maxLength: widget.day.nameMax,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What was wasted',
                    hintText: 'A dish, or what it was',
                    counterText: '',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                )
              else
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'What was wasted',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.fromLTRB(12, 6, 4, 6),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          picked.name,
                          key: const ValueKey('waste-picked'),
                          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('waste-unpick'),
                        tooltip: 'Another dish',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _picked = null),
                      ),
                    ],
                  ),
                ),
              for (final dish in found)
                InkWell(
                  key: ValueKey('waste-dish:${dish.variant.variantId}'),
                  onTap: () => setState(() {
                    _picked = dish;
                    FocusManager.instance.primaryFocus?.unfocus();
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final (name, other) = namesShown(
                                dish.entry.name,
                                dish.entry.secondName,
                                chineseFirst: chinese,
                              );
                              final size = dish.entry.variants.length > 1 ? ' (${dish.variant.name})' : '';
                              // the other name goes under whole where the two do not fit side by side
                              return Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('$name$size'),
                                  if (other != null) Text(other, style: small),
                                ],
                              );
                            },
                          ),
                        ),
                        if (!dish.entry.asksPrice) Text('\$${dish.variant.price}', style: small),
                      ],
                    ),
                  ),
                ),
              if (typedOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Not a dish of the menu: it is written as typed, with no price.',
                    key: const ValueKey('waste-typed'),
                    style: small,
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text('How many', style: theme.textTheme.titleSmall)),
                  IconButton.filledTonal(
                    key: const ValueKey('waste-fewer'),
                    tooltip: 'One fewer',
                    icon: const Icon(Icons.remove),
                    onPressed: (_count ?? 1) > 1 ? () => _step(-1) : null,
                  ),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      key: const ValueKey('waste-qty'),
                      controller: _qty,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                      decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                      style: theme.textTheme.titleLarge,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton.filledTonal(
                    key: const ValueKey('waste-more'),
                    tooltip: 'One more',
                    icon: const Icon(Icons.add),
                    onPressed: (_count ?? 0) < widget.day.qtyMax ? () => _step(1) : null,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Why', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final reason in widget.day.reasons)
                    ChoiceChip(
                      key: ValueKey('waste-reason:$reason'),
                      label: Text(reason),
                      selected: _reason == reason,
                      onSelected: (_) => setState(() => _reason = reason),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('waste-note'),
                controller: _note,
                maxLength: widget.day.noteMax,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note (if it helps)',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'This is not a sale and changes no check. A dish given to a guest is a comp, on the check.',
                  style: small,
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('waste-problem'),
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
          key: const ValueKey('waste-save'),
          onPressed: _busy || !_ready ? null : _save,
          child: const Text('Log'),
        ),
      ],
    );
  }
}
