import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../menu.dart';

/// A line the operator configured: what to send in `add_line`.
class ChosenLine {
  const ChosenLine({required this.name, required this.request, this.qty = 1, this.note = ''});
  final String name;
  final LineRequest request;
  final int qty;
  final String note;
}

/// The menu as buttons: sections across the top, dishes in a grid, a search box. A dish with nothing to ask
/// is added with one tap; anything else opens [ItemSheet].
class MenuPanel extends StatefulWidget {
  const MenuPanel({super.key, required this.api, required this.onChosen});

  final PosApi api;
  final ValueChanged<ChosenLine> onChosen;

  @override
  State<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<MenuPanel> {
  List<Menu>? _menus;
  String? _error;
  int _section = 0;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final menus = await widget.api.menus();
      if (mounted) {
        setState(() {
          _menus = menus;
          _error = null;
        });
      }
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  List<MenuSection> get _sections => [for (final m in _menus ?? const <Menu>[]) ...m.sections];

  List<MenuEntry> get _shown {
    final q = _search.text.trim().toLowerCase();
    final sections = _sections;
    if (q.isEmpty) return sections.isEmpty ? const [] : sections[_section.clamp(0, sections.length - 1)].allEntries;
    return [
      for (final s in sections)
        for (final e in s.allEntries)
          if (e.number?.toLowerCase() == q ||
              e.name.toLowerCase().contains(q) ||
              (e.secondName ?? '').toLowerCase().contains(q))
            e,
    ];
  }

  Future<void> _tap(MenuEntry entry) async {
    if (!entry.available) return;
    if (entry.quickAdd) {
      widget.onChosen(
        ChosenLine(
          name: entry.name,
          request: LineRequest(variantId: entry.variants.first.variantId, entryId: entry.entryId),
        ),
      );
      return;
    }
    final chosen = await showDialog<ChosenLine>(
      context: context,
      builder: (_) => ItemSheet(api: widget.api, entry: entry),
    );
    if (chosen != null) widget.onChosen(chosen);
  }

  @override
  Widget build(BuildContext context) {
    if (_menus == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Menu not loaded: $_error'),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
      );
    }
    final sections = _sections;
    final shown = _shown;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Number or name',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (var i = 0; i < sections.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: Text(sections[i].name),
                    selected: _search.text.isEmpty && i == _section,
                    onSelected: (_) => setState(() {
                      _section = i;
                      _search.clear();
                    }),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.extent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 1.35,
            padding: const EdgeInsets.all(8),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [for (final e in shown) _EntryButton(entry: e, onTap: () => _tap(e))],
          ),
        ),
      ],
    );
  }
}

class _EntryButton extends StatelessWidget {
  const _EntryButton({required this.entry, required this.onTap});

  final MenuEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = entry.available;
    return Material(
      color: available ? theme.colorScheme.secondaryContainer : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: available ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (entry.number != null) Text(entry.number!, style: theme.textTheme.labelMedium),
                  const Spacer(),
                  Text(available ? entry.priceLabel : '86', style: theme.textTheme.labelLarge),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                entry.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(decoration: available ? null : TextDecoration.lineThrough),
              ),
              if (entry.secondName != null)
                Text(entry.secondName!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              const Spacer(),
              if (!entry.quickAdd) Icon(Icons.tune, size: 14, color: theme.colorScheme.onSecondaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

/// Size, choices, quantity and a note for one dish, with the backend's price shown as they change.
class ItemSheet extends StatefulWidget {
  const ItemSheet({super.key, required this.api, required this.entry});

  final PosApi api;
  final MenuEntry entry;

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
  ItemDetail? _detail;
  late final LineRequest _request;
  Priced? _priced;
  int _qty = 1;
  final _note = TextEditingController();
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    final first = widget.entry.variants.firstWhere((v) => v.available, orElse: () => widget.entry.variants.first);
    _request = LineRequest(variantId: first.variantId, entryId: widget.entry.entryId);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.api.item(widget.entry.item, entryId: widget.entry.entryId);
      for (final g in detail.groups) {
        final defaults = [
          for (final o in g.options)
            if (o.isDefault && o.available) o.optionId,
        ];
        if (defaults.isNotEmpty) _request.selections[g.groupId] = defaults;
      }
      if (mounted) setState(() => _detail = detail);
      _reprice();
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  void _reprice() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        final priced = await widget.api.price(_request);
        if (mounted) setState(() => _priced = priced);
      } on ApiException catch (err) {
        if (mounted) setState(() => _error = err.toString());
      }
    });
  }

  void _toggle(GroupDetail group, OptionDetail option) {
    setState(() {
      final current = _request.selections[group.groupId] ?? [];
      if (group.single) {
        _request.selections[group.groupId] = current.contains(option.optionId) && !group.required
            ? []
            : [option.optionId];
      } else if (current.contains(option.optionId)) {
        _request.selections[group.groupId] = [...current]..remove(option.optionId);
      } else if (group.maxSelect == null || current.length < group.maxSelect!) {
        _request.selections[group.groupId] = [...current, option.optionId];
      }
    });
    _reprice();
  }

  String get _lineName {
    final variant = widget.entry.variants.firstWhere((v) => v.variantId == _request.variantId);
    return widget.entry.variants.length > 1 ? '${widget.entry.name} (${variant.name})' : widget.entry.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final priced = _priced;
    final total = priced == null ? null : (double.parse(priced.unitPrice) * _qty).toStringAsFixed(2);
    return AlertDialog(
      title: Text(
        widget.entry.secondName == null ? widget.entry.name : '${widget.entry.name}  ${widget.entry.secondName}',
      ),
      content: SizedBox(
        width: 480,
        child: detail == null
            ? Center(heightFactor: 2, child: _error == null ? const CircularProgressIndicator() : Text(_error!))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.entry.variants.length > 1) ...[
                      Text('Size', style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final v in widget.entry.variants)
                            ChoiceChip(
                              label: Text('${v.name} ${v.price}'),
                              selected: _request.variantId == v.variantId,
                              onSelected: v.available
                                  ? (_) {
                                      setState(() => _request.variantId = v.variantId);
                                      _reprice();
                                    }
                                  : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    for (final g in detail.groups) ...[
                      Text(g.required ? '${g.name} (required)' : g.name, style: theme.textTheme.titleSmall),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final o in g.options)
                            FilterChip(
                              label: Text(o.free ? o.name : '${o.name} +${o.price}'),
                              selected: (_request.selections[g.groupId] ?? const []).contains(o.optionId),
                              onSelected: o.available ? (_) => _toggle(g, o) : null,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _note,
                      decoration: const InputDecoration(labelText: 'Note to the kitchen', isDense: true),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        IconButton(
                          onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Text('$_qty', style: theme.textTheme.titleLarge),
                        IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
                        const Spacer(),
                        if (total != null) Text('\$$total', style: theme.textTheme.titleLarge),
                      ],
                    ),
                    if (priced != null && !priced.ok)
                      for (final p in priced.problems) Text(p, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: priced != null && priced.ok
              ? () =>
                    Navigator.of(context)
                        .pop(ChosenLine(name: _lineName, request: _request, qty: _qty, note: _note.text.trim()))
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
