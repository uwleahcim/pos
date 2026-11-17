import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';
import '../menu_search.dart';

/// Finds one dish of the menu by what is typed, away from the order screen: its name in any word order, its
/// number, or what the kitchen calls it, the best match first ([MenuSearch]). Pops the dish tapped. A dish
/// that is on two menus (lunch and dinner) is offered once.
class DishFinderDialog extends StatefulWidget {
  const DishFinderDialog({super.key, required this.api, required this.title, this.offered = 6});

  final PosApi api;

  /// What the dish is looked up for: "86 a dish".
  final String title;

  /// The most dishes offered under what is typed: the keyboard leaves a phone room for no more.
  final int offered;

  @override
  State<DishFinderDialog> createState() => _DishFinderDialogState();
}

class _DishFinderDialogState extends State<DishFinderDialog> {
  final _typed = TextEditingController();
  MenuSearch<MenuEntry>? _menu;
  String? _message;

  @override
  void initState() {
    super.initState();
    _readMenu();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _readMenu() async {
    try {
      final (_, menus) = await widget.api.menus();
      if (!mounted) return;
      final seen = <String>{};
      final dishes = [
        for (final menu in menus)
          for (final section in menu.sections)
            for (final entry in section.allEntries)
              // an off-menu dish is typed when it is rung: there is nothing of it to run out
              if (!entry.asksName && entry.variants.isNotEmpty && seen.add(_sizes(entry))) entry,
      ];
      setState(() {
        _menu = MenuSearch<MenuEntry>(
          dishes,
          (e) => SearchText(number: e.number, names: [e.name, e.secondName], labels: [e.kitchenName]),
        );
      });
    } on ApiException catch (err) {
      if (mounted) setState(() => _message = 'The menu could not be read: ${err.message}');
    }
  }

  /// What tells two entries of one dish apart from two dishes: the sizes it is sold in.
  static String _sizes(MenuEntry entry) => entry.variants.map((v) => v.variantId).join('|');

  List<MenuEntry> get _found {
    final typed = _typed.text.trim();
    final menu = _menu;
    if (menu == null || typed.isEmpty) return const [];
    return menu.find(typed).take(widget.offered).toList();
  }

  /// What the menu says of a dish right now: sold out, or how many are left.
  static String _state(MenuEntry entry) {
    final out = entry.variants.where((v) => !v.available).length;
    if (out == entry.variants.length) return 'Sold out';
    if (out > 0) return '$out of ${entry.variants.length} sizes sold out';
    final left = [
      for (final v in entry.variants)
        if (v.left != null) v.left!,
    ];
    if (left.isEmpty) return '';
    left.sort();
    return '${left.first} left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final found = _found;
    final typed = _typed.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('dish-finder-typed'),
                controller: _typed,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Dish',
                  hintText: 'A name or a number',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_message!, style: TextStyle(color: scheme.error)),
                )
              else if (_menu == null)
                const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator())
              else if (typed && found.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'No dish on the menu is called that.',
                    key: const ValueKey('dish-finder-none'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final entry in found)
                ListTile(
                  key: ValueKey('dish-found:${entry.variants.first.variantId}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(entry.number == null ? entry.name : '${entry.number} · ${entry.name}'),
                  subtitle: _state(entry).isEmpty ? null : Text(_state(entry)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pop(entry),
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}
