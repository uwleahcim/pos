/// The menu as the backend shows it. The app displays it and sends choices back; it never prices anything.
library;

class VariantOffer {
  const VariantOffer({required this.variantId, required this.name, required this.price, required this.status});

  factory VariantOffer.fromJson(Map<String, dynamic> json) => VariantOffer(
    variantId: json['variant_id'] as String,
    name: json['name'] as String? ?? '',
    price: json['price'] as String? ?? '0.00',
    status: json['status'] as String? ?? 'available',
  );

  final String variantId;
  final String name;
  final String price;
  final String status;

  bool get available => status == 'available';
}

class MenuEntry {
  const MenuEntry({
    required this.entryId,
    required this.item,
    required this.name,
    required this.variants,
    this.number,
    this.secondName,
    this.hasOptions = false,
    this.tags = const [],
  });

  factory MenuEntry.fromJson(Map<String, dynamic> json) => MenuEntry(
    entryId: json['entry_id'] as String,
    item: json['item'] as String,
    name: json['name'] as String? ?? '',
    number: json['number'] as String?,
    secondName: json['second_name'] as String?,
    hasOptions: json['has_options'] as bool? ?? false,
    tags: List<String>.from(json['tags'] as List? ?? const []),
    variants: (json['variants'] as List? ?? const [])
        .map((v) => VariantOffer.fromJson(v as Map<String, dynamic>))
        .toList(),
  );

  final String entryId;
  final String item;
  final String name;
  final String? number;
  final String? secondName;
  final bool hasOptions;
  final List<String> tags;
  final List<VariantOffer> variants;

  /// One tap adds it: a single variant and no questions to ask.
  bool get quickAdd => !hasOptions && variants.length == 1;
  bool get available => variants.any((v) => v.available);
  String get priceLabel {
    if (variants.isEmpty) return '';
    if (variants.length == 1) return variants.first.price;
    return '${variants.first.price}+';
  }
}

class MenuSection {
  const MenuSection({required this.sectionId, required this.name, required this.entries, this.sections = const []});

  factory MenuSection.fromJson(Map<String, dynamic> json) => MenuSection(
    sectionId: json['section_id'] as String,
    name: json['name'] as String? ?? '',
    entries: (json['entries'] as List? ?? const []).map((e) => MenuEntry.fromJson(e as Map<String, dynamic>)).toList(),
    sections: (json['sections'] as List? ?? const [])
        .map((s) => MenuSection.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  final String sectionId;
  final String name;
  final List<MenuEntry> entries;
  final List<MenuSection> sections;

  /// This section's entries followed by its subsections', for a flat grid.
  List<MenuEntry> get allEntries => [...entries, for (final s in sections) ...s.allEntries];
}

class Menu {
  const Menu({required this.menu, required this.name, required this.sections});

  factory Menu.fromJson(Map<String, dynamic> json) => Menu(
    menu: json['menu'] as String,
    name: json['name'] as String? ?? '',
    sections: (json['sections'] as List? ?? const [])
        .map((s) => MenuSection.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  final String menu;
  final String name;
  final List<MenuSection> sections;
}

class OptionDetail {
  const OptionDetail({
    required this.optionId,
    required this.name,
    required this.price,
    required this.isDefault,
    required this.status,
  });

  factory OptionDetail.fromJson(Map<String, dynamic> json) => OptionDetail(
    optionId: json['option_id'] as String,
    name: json['name'] as String? ?? '',
    price: json['price'] as String? ?? '0.00',
    isDefault: json['is_default'] as bool? ?? false,
    status: json['status'] as String? ?? 'available',
  );

  final String optionId;
  final String name;
  final String price;
  final bool isDefault;
  final String status;

  bool get available => status == 'available';
  bool get free => double.tryParse(price) == 0;
}

class GroupDetail {
  const GroupDetail({
    required this.groupId,
    required this.name,
    required this.minSelect,
    required this.options,
    this.maxSelect,
  });

  factory GroupDetail.fromJson(Map<String, dynamic> json) => GroupDetail(
    groupId: json['group_id'] as String,
    name: json['name'] as String? ?? '',
    minSelect: json['min_select'] as int? ?? 0,
    maxSelect: json['max_select'] as int?,
    options: (json['options'] as List? ?? const [])
        .map((o) => OptionDetail.fromJson(o as Map<String, dynamic>))
        .toList(),
  );

  final String groupId;
  final String name;
  final int minSelect;
  final int? maxSelect;
  final List<OptionDetail> options;

  bool get single => maxSelect == 1;
  bool get required => minSelect > 0;
}

class ItemDetail {
  const ItemDetail({
    required this.item,
    required this.name,
    required this.variants,
    required this.groups,
    this.secondName,
  });

  factory ItemDetail.fromJson(Map<String, dynamic> json) => ItemDetail(
    item: json['item'] as String,
    name: json['name'] as String? ?? '',
    secondName: json['second_name'] as String?,
    variants: (json['variants'] as List? ?? const [])
        .map((v) => VariantOffer.fromJson(v as Map<String, dynamic>))
        .toList(),
    groups: (json['groups'] as List? ?? const []).map((g) => GroupDetail.fromJson(g as Map<String, dynamic>)).toList(),
  );

  final String item;
  final String name;
  final String? secondName;
  final List<VariantOffer> variants;
  final List<GroupDetail> groups;
}

/// What the customer chose for one line; the backend's `request` on `add_line`.
class LineRequest {
  LineRequest({required this.variantId, this.entryId, Map<String, List<String>>? selections, this.notes})
    : selections = selections ?? {};

  String variantId;
  final String? entryId;
  final Map<String, List<String>> selections; // group id -> option ids
  String? notes;

  Map<String, dynamic> toJson() => {
    'variant_id': variantId,
    'entry_id': ?entryId,
    'selections': [
      for (final e in selections.entries)
        for (final option in e.value) {'group_id': e.key, 'option_id': option},
    ],
    if (notes != null && notes!.isNotEmpty) 'notes': notes,
  };
}

/// The backend's price for a configured line: what it costs and anything wrong with it.
class Priced {
  const Priced({required this.name, required this.unitPrice, required this.problems});

  factory Priced.fromJson(Map<String, dynamic> json) => Priced(
    name: json['name'] as String? ?? '',
    unitPrice: json['unit_price'] as String? ?? '0.00',
    problems: (json['problems'] as List? ?? const [])
        .map((p) => (p as Map<String, dynamic>)['message'] as String? ?? '')
        .toList(),
  );

  final String name;
  final String unitPrice;
  final List<String> problems;

  bool get ok => problems.isEmpty;
}

class CheckLine {
  const CheckLine({
    required this.lineId,
    required this.name,
    required this.qty,
    required this.total,
    this.seat,
    this.modifiers = const [],
  });

  factory CheckLine.fromJson(Map<String, dynamic> json) => CheckLine(
    lineId: json['line_id'] as String,
    name: json['name'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    total: json['total'] as String? ?? '0.00',
    seat: json['seat'] as int?,
    modifiers: List<String>.from(json['modifiers'] as List? ?? const []),
  );

  final String lineId;
  final String name;
  final int qty;
  final String total;
  final int? seat;
  final List<String> modifiers;
}

class TaxLine {
  const TaxLine({required this.name, required this.ratePct, required this.amount});

  factory TaxLine.fromJson(Map<String, dynamic> json) => TaxLine(
    name: json['name'] as String? ?? '',
    ratePct: json['rate_pct'] as String? ?? '',
    amount: json['amount'] as String? ?? '0.00',
  );

  final String name;
  final String ratePct;
  final String amount;
}

/// What the table owes, as the backend adds it up.
class Check {
  const Check({
    required this.lines,
    required this.subtotal,
    required this.taxLines,
    required this.tax,
    required this.total,
  });

  factory Check.fromJson(Map<String, dynamic> json) => Check(
    lines: (json['lines'] as List? ?? const []).map((l) => CheckLine.fromJson(l as Map<String, dynamic>)).toList(),
    subtotal: json['subtotal'] as String? ?? '0.00',
    taxLines: (json['tax_lines'] as List? ?? const []).map((t) => TaxLine.fromJson(t as Map<String, dynamic>)).toList(),
    tax: json['tax'] as String? ?? '0.00',
    total: json['total'] as String? ?? '0.00',
  );

  final List<CheckLine> lines;
  final String subtotal;
  final List<TaxLine> taxLines;
  final String tax;
  final String total;

  CheckLine? line(String lineId) {
    for (final l in lines) {
      if (l.lineId == lineId) return l;
    }
    return null;
  }
}
