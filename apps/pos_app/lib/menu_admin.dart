/// The menu as the editor holds it: every definition the backend sent, by kind and key, plus the edits made
/// since. Nothing is checked or saved here. `changes()` lists what differs, and the backend runs its own
/// checks on the whole menu before it saves anything.
library;

import 'dart:convert';

/// The kinds the editor writes, in the order the backend's catalog lists them.
const kinds = [
  'unit',
  'allergen',
  'station',
  'category',
  'item',
  'variant',
  'group',
  'option',
  'attachment',
  'menu',
  'section',
  'entry',
  'ingredient',
  'override',
  'recipe',
];

/// A definition's key, the same way the backend names it (pos.menu.admin.KINDS).
String keyOf(String kind, Map<String, dynamic> row) => switch (kind) {
  'variant' || 'option' || 'section' || 'entry' || 'recipe' => row['id'] as String,
  'attachment' => '${row['owner_kind']}:${row['owner']}/${row['group']}',
  'override' => '${row['owner_kind']}:${row['owner']}/${row['allergen']}',
  _ => row['code'] as String,
};

/// A copy deep enough to edit without touching the original.
Map<String, dynamic> copyRow(Map<String, dynamic> row) => jsonDecode(jsonEncode(row)) as Map<String, dynamic>;

class Problem {
  const Problem(this.code, this.message);
  factory Problem.fromJson(Map<String, dynamic> json) =>
      Problem(json['code'] as String? ?? '', json['message'] as String? ?? '');
  final String code;
  final String message;
}

List<Problem> problemsFrom(Object? list) => [
  for (final p in list as List? ?? const []) Problem.fromJson((p as Map).cast<String, dynamic>()),
];

class MenuCatalog {
  MenuCatalog({required this.revision, required Map<String, Map<String, Map<String, dynamic>>> rows})
    : _original = rows,
      _rows = {
        for (final kind in kinds) kind: {for (final e in (rows[kind] ?? const {}).entries) e.key: copyRow(e.value)},
      };

  factory MenuCatalog.fromJson(Map<String, dynamic> json) {
    final catalog = (json['catalog'] as Map).cast<String, dynamic>();
    return MenuCatalog(
      revision: json['revision'] as int? ?? 0,
      rows: {
        for (final kind in kinds)
          kind: {
            for (final raw in catalog[kind] as List? ?? const [])
              (raw as Map)['key'] as String: Map<String, dynamic>.from(raw)..remove('key'),
          },
      },
    )..warnings = problemsFrom(json['warnings']);
  }

  final int revision;
  final Map<String, Map<String, Map<String, dynamic>>> _original;
  final Map<String, Map<String, Map<String, dynamic>>> _rows;
  List<Problem> warnings = const [];

  Map<String, dynamic>? get(String kind, String key) => _rows[kind]?[key];
  Iterable<Map<String, dynamic>> all(String kind) => _rows[kind]!.values;

  /// Adds or replaces a definition. Changing what its key is made of (an item's code) is a new definition:
  /// pass the key it had as `replacing` and the old one goes.
  void put(String kind, Map<String, dynamic> row, {String? replacing}) {
    final key = keyOf(kind, row);
    if (replacing != null && replacing != key) _rows[kind]!.remove(replacing);
    _rows[kind]![key] = row;
  }

  void delete(String kind, String key) => _rows[kind]!.remove(key);

  bool isChanged(String kind, String key) {
    final now = _rows[kind]![key], was = _original[kind]?[key];
    if (now == null || was == null) return now != was;
    return !_same(now, was);
  }

  /// What the backend needs to make its menu this one: a put for every new or changed definition, a delete
  /// for every one that went.
  List<Map<String, dynamic>> changes() => [
    for (final kind in kinds)
      for (final e in _rows[kind]!.entries)
        if (isChanged(kind, e.key)) {'kind': kind, 'op': 'put', 'data': e.value},
    for (final kind in kinds.reversed)
      for (final key in (_original[kind] ?? const {}).keys)
        if (!_rows[kind]!.containsKey(key)) {'kind': kind, 'op': 'delete', 'key': key},
  ];

  bool get dirty => changes().isNotEmpty;

  // --- the shapes the screens list ---------------------------------------------------------------------

  List<Map<String, dynamic>> categories() => _sorted(all('category'));

  List<Map<String, dynamic>> itemsIn(String category) => _sorted(all('item').where((i) => i['category'] == category));

  /// A category with the categories above it, nearest first.
  List<String> categoryChain(String categoryKey) {
    final chain = <String>[];
    String? key = categoryKey;
    while (key != null && !chain.contains(key)) {
      chain.add(key);
      key = get('category', key)?['parent'] as String?;
    }
    return chain;
  }

  /// Every dish in a category or in the categories under it, in menu order (the backend's `items_in`).
  List<Map<String, dynamic>> itemsUnder(String categoryKey) =>
      _sorted(all('item').where((i) => categoryChain(i['category'] as String).contains(categoryKey)));

  List<Map<String, dynamic>> variantsOf(String item) => _sorted(all('variant').where((v) => v['item'] == item));

  List<Map<String, dynamic>> entriesOf(String item) => all('entry').where((e) => e['item'] == item).toList();

  List<Map<String, dynamic>> optionsOf(String group) => _sorted(all('option').where((o) => o['group'] == group));

  /// The groups an item asks for: its own attachments, then its category's (shown but edited on the category).
  List<Map<String, dynamic>> attachmentsOf(String ownerKind, String owner) => _sorted(
    all('attachment').where((a) => a['owner_kind'] == ownerKind && a['owner'] == owner && a['excluded'] != true),
  );

  List<Map<String, dynamic>> groups() => _sorted(all('group'));

  /// Every menu section, for the "on the menu at" picker.
  List<Map<String, dynamic>> sections() => _sorted(all('section'));

  /// The menus (Food, Lunch, Drinks) as the order screen tabs them: by priority, highest first.
  List<Map<String, dynamic>> menus() => all('menu').toList()
    ..sort((a, b) {
      final byPriority = ((b['priority'] as int?) ?? 0).compareTo((a['priority'] as int?) ?? 0);
      return byPriority != 0 ? byPriority : '${a['code']}'.compareTo('${b['code']}');
    });

  /// Whether a category is on a menu: the import and the editor both name its section there `menu/category`.
  bool categoryOn(String categoryKey, String menu) => get('section', '$menu/$categoryKey') != null;

  List<Map<String, dynamic>> stations() => all('station').toList();

  static List<Map<String, dynamic>> _sorted(Iterable<Map<String, dynamic>> rows) => rows.toList()
    ..sort((a, b) {
      final bySort = ((a['sort'] as int?) ?? 0).compareTo((b['sort'] as int?) ?? 0);
      return bySort != 0 ? bySort : '${a['code'] ?? a['id']}'.compareTo('${b['code'] ?? b['id']}');
    });
}

/// A name in the editor's language, falling back to any name it has.
String nameOf(Map<String, dynamic>? row, [String locale = 'en']) {
  final names = (row?['names'] as Map?)?.cast<String, dynamic>() ?? const {};
  final own = names[locale] as String?;
  if (own != null && own.isNotEmpty) return own;
  for (final e in names.entries) {
    if (e.key != 'kitchen' && (e.value as String? ?? '').isNotEmpty) return e.value as String;
  }
  return '${row?['code'] ?? row?['id'] ?? ''}';
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
