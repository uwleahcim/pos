import 'package:flutter/material.dart';

import '../api.dart';
import '../day_report.dart' show dollars, isMoney;
import '../dishes_report.dart';
import '../sales_report.dart';
import 'span_report.dart';
import 'theme.dart';

/// Dishes sold over any days, best to worst, for a manager (docs/dishes-sold.md): every dish with how many
/// were sold and for how much, beside the same days whole weeks earlier, by how many or by the money, best
/// or worst first, for all the menu or one category of it, or the dishes whose name is typed. A dish opens
/// to the sizes it went out in and every choice made on it. Every dish the menu shows is in the list, so
/// worst first begins with what nobody ordered. The hub does every sum; this only puts them in order.
class DishesScreen extends StatefulWidget {
  const DishesScreen({
    super.key,
    required this.api,
    required this.token,
    this.now = DateTime.now,
    this.pickSpan = deviceSpan,
    this.choice = SalesChoice.week,
    this.other,
  });

  final PosApi api;

  /// The manager's session (`POST /admin/session`): every call here carries it.
  final String token;

  /// The time on this device: which day yesterday was.
  final DateTime Function() now;
  final PickSpan pickSpan;

  /// The days it opens on: the ones Sales was reading, when it is opened from there.
  final SalesChoice choice;
  final DateTimeRange? other;

  @override
  State<DishesScreen> createState() => _DishesScreenState();
}

class _DishesScreenState extends State<DishesScreen> {
  late SalesChoice _choice = widget.choice;
  late DateTimeRange? _other = widget.other;
  DishesReport? _report;
  String? _error;
  int _asked = 0;
  int _maxDays = 92;

  /// How many times the list was put in another order or read for other days: each time it is a new list,
  /// laid out from its top.
  int _laid = 0;
  bool _byMoney = false;
  bool _worstFirst = false;

  /// The category shown ([DishCategory.id]); null for all the menu.
  String? _category;
  final _find = TextEditingController();
  final _open = <String>{};
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _find.dispose();
    _scroll.dispose();
    super.dispose();
  }

  DishSort get _sort => _byMoney
      ? (_worstFirst ? DishSort.leastMoney : DishSort.mostMoney)
      : (_worstFirst ? DishSort.least : DishSort.most);

  Future<void> _load() async {
    final ask = ++_asked;
    setState(() => _error = null);
    final (from, to) = spanOf(_choice, widget.now(), first: _other?.start, last: _other?.end);
    try {
      final report = await widget.api.dishesReport(widget.token, from: from, to: to);
      if (!mounted || ask != _asked) return;
      setState(() {
        _report = report;
        _maxDays = report.maxDays;
        // a category the menu no longer has cannot be the one shown
        if (report.categories.every((category) => category.id != _category)) _category = null;
      });
    } on ApiException catch (err) {
      if (!mounted || ask != _asked) return;
      setState(() => _error = reportError(err, 'the list of dishes sold'));
    }
  }

  /// Another order, category or name: the list starts again from its top.
  void _relay(VoidCallback change) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      change();
      _laid++;
    });
  }

  void _pick(SalesChoice choice) {
    _relay(() {
      _choice = choice;
      _report = null;
      _open.clear();
    });
    _load();
  }

  Future<void> _pickOther() async {
    final picked = await askOtherDays(context, widget.pickSpan, _other, maxDays: _maxDays, prefix: 'dishes');
    if (picked == null || !mounted) return;
    _other = picked;
    _pick(SalesChoice.other);
  }

  static String _many(int n) {
    final digits = '$n';
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return grouped.toString();
  }

  static String _count(int n, String one, String more) => '${_many(n)} ${n == 1 ? one : more}';

  /// The figure before and how far the two are apart, by how many or by the money.
  static ({String before, Change change}) _beside(SoldRow row, {required bool byMoney}) {
    final change = byMoney ? changeWords(row.money, row.beforeMoney) : changeWords(row.count, row.beforeCount);
    final said = byMoney ? dollars(row.beforeAmount) : _many(row.beforeCount);
    return (before: change.words == 'nothing before' || change.words.isEmpty ? '' : '$said before', change: change);
  }

  Future<void> _pickCategory(DishesReport report) async {
    final menus = <String>[];
    for (final category in report.categories) {
      if (!menus.contains(category.menu)) menus.add(category.menu);
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        final label = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary);
        Widget row(String id, String name, String under, int count, String amount) => InkWell(
          key: ValueKey('dishes-category:$id'),
          onTap: () => Navigator.of(context).pop(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: ReportLine(
              name,
              dollars(amount),
              count: '${_many(count)}×',
              under: under,
              strong: (_category ?? 'all') == id, // the one the list is showing
            ),
          ),
        );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
            child: ListView(
              key: const ValueKey('dishes-categories'),
              shrinkWrap: true,
              children: [
                row(
                  'all',
                  'All dishes',
                  _count(report.dishes.length, 'dish', 'dishes'),
                  report.span.count,
                  report.span.amount,
                ),
                for (final menu in menus) ...[
                  // what the menu no longer has is one line, and says so itself
                  if (menus.length > 1 && menu.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                      child: Text(report.categories.firstWhere((c) => c.menu == menu).menuName, style: label),
                    ),
                  for (final category in report.categories.where((c) => c.menu == menu))
                    row(
                      category.id,
                      category.name,
                      _count(category.dishes, 'dish', 'dishes'),
                      category.count,
                      category.amount,
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    _relay(() => _category = picked == 'all' ? null : picked);
  }

  /// What stands over the list: the days, what all the dishes came to, and how the list is ordered.
  Widget _head(BuildContext context, DishesReport report, List<DishSold> shown) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final span = report.span, before = report.before;
    final category = report.categories.where((one) => one.id == _category).firstOrNull;
    final all = SoldRow(
      name: '',
      count: span.count,
      amount: span.amount,
      beforeCount: before.count,
      beforeAmount: before.amount,
    );
    final byCount = _beside(all, byMoney: false), byMoney = _beside(all, byMoney: true);
    final none = shown.where((dish) => dish.onMenu && dish.count == 0).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SpanHeading(
          prefix: 'dishes',
          first: span.first,
          last: span.last,
          beforeFirst: before.first,
          beforeLast: before.last,
          running: span.running,
          nowMs: report.nowMs,
        ),
        const SizedBox(height: 6),
        ReportLine(
          key: const ValueKey('dishes-total'),
          'Dishes sold',
          _many(span.count),
          under: byCount.before,
          change: byCount.change,
          strong: true,
        ),
        ReportLine(
          key: const ValueKey('dishes-money'),
          'They were sold for',
          dollars(span.amount),
          under: byMoney.before,
          change: byMoney.change,
          strong: true,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: false, label: Text('How many', key: ValueKey('dishes-by:count'))),
                ButtonSegment(value: true, label: Text('Money', key: ValueKey('dishes-by:money'))),
              ],
              selected: {_byMoney},
              onSelectionChanged: (picked) => _relay(() => _byMoney = picked.first),
            ),
            FilterChip(
              key: const ValueKey('dishes-worst'),
              label: const Text('Worst first'),
              selected: _worstFirst,
              onSelected: (on) => _relay(() => _worstFirst = on),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  key: const ValueKey('dishes-category'),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.filter_list, size: 18),
                  label: Text(category?.name ?? 'All dishes', maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: () => _pickCategory(report),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('dishes-find'),
                controller: _find,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find a dish',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                  suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  border: const OutlineInputBorder(),
                  suffixIcon: _find.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('dishes-find-clear'),
                          tooltip: 'Every dish again',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => _relay(_find.clear),
                        ),
                ),
                // the list is not laid out anew: that would take the keyboard from the field
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            shown.isEmpty
                ? (_find.text.trim().isEmpty ? 'No dish here.' : 'No dish by that name.')
                : [
                    _count(shown.length, 'dish', 'dishes'),
                    if (none > 0) '${_many(none)} on the menu sold none',
                  ].join(' · '),
            key: const ValueKey('dishes-shown'),
            style: small,
          ),
        ),
      ],
    );
  }

  Widget _dish(BuildContext context, DishSold dish, int rank, num most) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final open = _open.contains(dish.id);
    final beside = _beside(dish, byMoney: _byMoney);
    final measure = _byMoney ? dish.money : dish.count;
    final where = _category == null ? dish.categoryName : (dish.onMenu ? '' : 'Off the menu now');
    final sold = dish.count == 0 && dish.beforeCount == 0 ? 'none sold' : beside.before;
    final groups = <String>[];
    for (final option in dish.options) {
      if (!groups.contains(option.group)) groups.add(option.group);
    }
    // A size is the dish sold, so more of it is green. A choice is how the dish went out (more "Mild" is
    // not better than more "Medium"), so its change is said in plain letters.
    Widget part(String key, SoldRow row, {bool before = true, bool judged = true}) {
      final beside = _beside(row, byMoney: false);
      return ReportLine(
        key: ValueKey(key),
        row.name,
        isMoney(row.amount) ? dollars(row.amount) : '',
        count: '${_many(row.count)}×',
        under: before ? beside.before : '',
        change: before ? beside.change : null,
        judged: judged,
      );
    }

    Widget label(String words) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(words, style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
    );

    return Column(
      key: ValueKey('dish:${dish.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('dish-row:${dish.id}'),
          onTap: dish.hasMore ? () => setState(() => open ? _open.remove(dish.id) : _open.add(dish.id)) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('$rank', style: small?.copyWith(fontFeatures: PosTheme.tabular)),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ReportLine(
                        dish.name,
                        dollars(dish.amount),
                        count: '${_many(dish.count)}×',
                        under: [if (where.isNotEmpty) where, if (sold.isNotEmpty) sold].join(' · '),
                        change: beside.change,
                        underWide: true,
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: most <= 0 ? 0 : (measure / most).clamp(0.0, 1.0).toDouble(),
                          child: Container(
                            key: ValueKey('dish-bar:${dish.id}'),
                            height: 4,
                            decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: dish.hasMore
                      ? Padding(
                          padding: const EdgeInsets.only(top: 3, left: 4),
                          child: Icon(
                            open ? Icons.expand_less : Icons.expand_more,
                            size: 22,
                            color: scheme.onSurfaceVariant,
                            semanticLabel: open ? 'Close' : 'Sizes and options',
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            key: ValueKey('dish-more:${dish.id}'),
            padding: const EdgeInsets.only(left: 30, right: 28, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (dish.sizes.isNotEmpty) ...[
                  label('Sizes'),
                  for (final size in dish.sizes) part('dish-size:${dish.id}:${size.name}', size),
                ],
                if (dish.typed.isNotEmpty) ...[
                  label('As it was typed'),
                  for (final typed in dish.typed) part('dish-typed:${dish.id}:${typed.name}', typed, before: false),
                ],
                for (final group in groups) ...[
                  label(group.isEmpty ? 'Options' : group),
                  for (final option in dish.options.where((option) => option.group == group))
                    part('dish-option:${dish.id}:$group:${option.name}', option, judged: false),
                ],
              ],
            ),
          ),
        const Divider(height: 9),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final Widget body;
    if (_error != null) {
      body = SpanError(prefix: 'dishes', message: _error!, onRetry: _load);
    } else if (report == null) {
      body = SpanReading(prefix: 'dishes', many: _choice == SalesChoice.fourWeeks || _choice == SalesChoice.other);
    } else {
      final category = report.categories.where((one) => one.id == _category).firstOrNull;
      final shown = sortedDishes(
        dishesNamed(
          report.dishes.where(
            (dish) => category == null || (dish.menu == category.menu && dish.category == category.code),
          ),
          _find.text,
        ),
        _sort,
      );
      var most = 0.0;
      for (final dish in shown) {
        final measure = _byMoney ? dish.money : dish.count;
        if (measure > most) most = measure.toDouble();
      }
      final small = Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
      body = KeyedSubtree(
        key: ValueKey(_laid),
        child: ListView.builder(
          key: const ValueKey('dishes-list'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: shown.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return _head(context, report, shown);
            if (index <= shown.length) return _dish(context, shown[index - 1], index, most);
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'What a dish was sold for has its options in it and is before comps and discounts: together the '
                'dishes are the "Dishes sold" of Sales. Under a dish, an option counts what the dish comes with '
                'as well as what was picked, and its money is part of the dish\'s, not on top. A dish chosen '
                'inside another (the soup of a lunch special) is counted under that dish. A dish voided or taken '
                'off is not counted. A day runs from 4 AM to 4 AM.',
                key: const ValueKey('dishes-note'),
                style: small,
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dishes sold'),
        actions: [
          IconButton(
            key: const ValueKey('dishes-refresh'),
            tooltip: 'Read again',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              SpanChips(prefix: 'dishes', choice: _choice, other: _other, onPick: _pick, onOther: _pickOther),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
