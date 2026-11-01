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
    this.needsChoice = false,
    this.tags = const [],
  });

  factory MenuEntry.fromJson(Map<String, dynamic> json) {
    final variants = (json['variants'] as List? ?? const [])
        .map((v) => VariantOffer.fromJson(v as Map<String, dynamic>))
        .toList();
    final hasOptions = json['has_options'] as bool? ?? false;
    return MenuEntry(
      entryId: json['entry_id'] as String,
      item: json['item'] as String,
      name: json['name'] as String? ?? '',
      number: json['number'] as String?,
      secondName: json['second_name'] as String?,
      hasOptions: hasOptions,
      // an older hub does not say: then assume a tap asks whenever there is anything to ask
      needsChoice: json['needs_choice'] as bool? ?? (hasOptions || variants.length > 1),
      tags: List<String>.from(json['tags'] as List? ?? const []),
      variants: variants,
    );
  }

  /// A line's dish when only its item is known (reopening a line from an order).
  factory MenuEntry.fromDetail(ItemDetail detail, {String? entryId}) => MenuEntry(
    entryId: entryId ?? '',
    item: detail.item,
    name: detail.name,
    secondName: detail.secondName,
    hasOptions: true,
    needsChoice: true,
    variants: detail.variants,
  );

  final String entryId;
  final String item;
  final String name;
  final String? number;
  final String? secondName;
  final bool hasOptions;

  /// A tap has to ask something (a size, a required choice with no default) before the dish can go on the
  /// check. The tile shows its customize mark only then: a dish whose rice simply defaults says nothing.
  final bool needsChoice;
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
  const MenuSection({
    required this.sectionId,
    required this.name,
    required this.entries,
    this.sections = const [],
    this.color,
  });

  factory MenuSection.fromJson(Map<String, dynamic> json) => MenuSection(
    sectionId: json['section_id'] as String,
    name: json['name'] as String? ?? '',
    color: json['color'] as String?,
    entries: (json['entries'] as List? ?? const []).map((e) => MenuEntry.fromJson(e as Map<String, dynamic>)).toList(),
    sections: (json['sections'] as List? ?? const [])
        .map((s) => MenuSection.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  final String sectionId;
  final String name;

  /// The tile colour the menu gives this category (`#RRGGBB`), or null for one from the app's palette.
  final String? color;
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

/// The one-tap instructions a choice can carry, as the backend spells them, with the word shown for each.
const instructions = {'no': 'No', 'extra': 'Extra', 'side': 'On the side', 'light': 'Light'};

/// What the customer chose for one line; the backend's `request` on `add_line`.
class LineRequest {
  LineRequest({
    required this.variantId,
    this.entryId,
    Map<String, List<String>>? selections,
    Map<String, String>? prefixes,
    this.notes,
  }) : selections = selections ?? {},
       prefixes = prefixes ?? {};

  factory LineRequest.fromJson(Map<String, dynamic> json) {
    final selections = <String, List<String>>{};
    final prefixes = <String, String>{};
    for (final s in json['selections'] as List? ?? const []) {
      final m = s as Map<String, dynamic>;
      selections.putIfAbsent(m['group_id'] as String, () => []).add(m['option_id'] as String);
      if (m['prefix'] != null) prefixes[m['option_id'] as String] = m['prefix'] as String;
    }
    return LineRequest(
      variantId: json['variant_id'] as String,
      entryId: json['entry_id'] as String?,
      selections: selections,
      prefixes: prefixes,
      notes: json['notes'] as String?,
    );
  }

  LineRequest copy() => LineRequest(
    variantId: variantId,
    entryId: entryId,
    selections: {
      for (final e in selections.entries) e.key: [...e.value],
    },
    prefixes: {...prefixes},
    notes: notes,
  );

  String variantId;
  final String? entryId;
  final Map<String, List<String>> selections; // group id -> option ids

  /// An instruction on a chosen option (option id -> no | extra | side | light): "no peanuts" without an
  /// option of its own. The backend prints it in front of the kitchen label and makes a "no" free.
  final Map<String, String> prefixes;
  String? notes;

  Map<String, dynamic> toJson() => {
    'variant_id': variantId,
    'entry_id': ?entryId,
    'selections': [
      for (final e in selections.entries)
        for (final option in e.value)
          {'group_id': e.key, 'option_id': option, if (prefixes[option] != null) 'prefix': prefixes[option]},
    ],
    if (notes != null && notes!.isNotEmpty) 'notes': notes,
  };
}

/// The backend's price for a configured line: what it costs and anything wrong with it.
class Priced {
  const Priced({required this.name, required this.unitPrice, required this.problems, this.estimated = false});

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

  /// Worked out on this screen from the menu it has, because no backend answered (ADR 6).
  final bool estimated;

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
    this.discount = '0.00',
  });

  factory CheckLine.fromJson(Map<String, dynamic> json) => CheckLine(
    lineId: json['line_id'] as String,
    name: json['name'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    total: json['total'] as String? ?? '0.00',
    seat: json['seat'] as int?,
    modifiers: List<String>.from(json['modifiers'] as List? ?? const []),
    discount: json['discount'] as String? ?? '0.00',
  );

  final String lineId;
  final String name;
  final int qty;
  final String total;
  final int? seat;
  final List<String> modifiers;

  /// What came off this line itself (a comp, a percentage or an amount on it); a check discount is its own row.
  final String discount;

  bool get isDiscounted => discount != '0.00' && discount != '0';

  CheckLine withQty(int qty, String total, {String? discount}) => CheckLine(
    lineId: lineId,
    name: name,
    qty: qty,
    total: total,
    seat: seat,
    modifiers: modifiers,
    discount: discount ?? this.discount,
  );
}

/// A discount on the check as the backend applied it: its reason, who put it on and who approved it.
class CheckDiscount {
  const CheckDiscount({
    required this.discountId,
    required this.reason,
    required this.name,
    required this.kind,
    required this.value,
    required this.amount,
    this.lineId,
    this.note = '',
    this.appliedBy = '',
    this.approvedBy,
  });

  factory CheckDiscount.fromJson(Map<String, dynamic> json) => CheckDiscount(
    discountId: json['discount_id'] as String,
    reason: json['reason'] as String? ?? '',
    name: json['name'] as String? ?? json['reason'] as String? ?? '',
    kind: json['kind'] as String? ?? 'percent',
    value: json['value']?.toString() ?? '0',
    amount: json['amount'] as String? ?? '0.00',
    lineId: json['line_id'] as String?,
    note: json['note'] as String? ?? '',
    appliedBy: json['applied_by'] as String? ?? '',
    approvedBy: (json['approved_by'] as Map?)?['name'] as String?,
  );

  final String discountId;
  final String reason;
  final String name;
  final String kind; // percent | amount | comp
  final String value;
  final String amount;
  final String? lineId;
  final String note;
  final String appliedBy;
  final String? approvedBy;

  CheckDiscount withAmount(String amount) => CheckDiscount(
    discountId: discountId,
    reason: reason,
    name: name,
    kind: kind,
    value: value,
    amount: amount,
    lineId: lineId,
    note: note,
    appliedBy: appliedBy,
    approvedBy: approvedBy,
  );
}

/// A service charge on the check: automatic from the rules (a party's gratuity, a delivery fee) or put on by staff.
class CheckCharge {
  const CheckCharge({
    required this.chargeId,
    required this.name,
    required this.kind,
    required this.value,
    required this.amount,
    this.gratuity = false,
    this.automatic = false,
    this.taxed = false,
    this.appliedBy,
  });

  factory CheckCharge.fromJson(Map<String, dynamic> json) => CheckCharge(
    chargeId: json['charge_id'] as String,
    name: json['name'] as String? ?? '',
    kind: json['kind'] as String? ?? 'amount',
    value: json['value']?.toString() ?? '0',
    amount: json['amount'] as String? ?? '0.00',
    gratuity: json['gratuity'] as bool? ?? false,
    automatic: json['automatic'] as bool? ?? false,
    taxed: json['taxed'] as bool? ?? false,
    appliedBy: json['applied_by'] as String?,
  );

  final String chargeId;
  final String name;
  final String kind; // percent | amount
  final String value;
  final String amount;
  final bool gratuity;
  final bool automatic;
  final bool taxed;
  final String? appliedBy;

  CheckCharge withAmount(String amount) => CheckCharge(
    chargeId: chargeId,
    name: name,
    kind: kind,
    value: value,
    amount: amount,
    gratuity: gratuity,
    automatic: automatic,
    taxed: taxed,
    appliedBy: appliedBy,
  );
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

/// A payment as the backend's check lists it.
class CheckPayment {
  const CheckPayment({
    required this.paymentId,
    required this.method,
    required this.amount,
    this.tendered,
    this.by = '',
  });

  factory CheckPayment.fromJson(Map<String, dynamic> json) => CheckPayment(
    paymentId: json['payment_id'] as String,
    method: json['method'] as String? ?? 'cash',
    amount: json['amount']?.toString() ?? '0',
    tendered: json['tendered']?.toString(),
    by: json['by'] as String? ?? '',
  );

  final String paymentId;
  final String method;
  final String amount;
  final String? tendered;
  final String by;
}

/// What the table owes, as the backend adds it up. `taxLines` split the tax by jurisdiction for the back
/// office; screens and receipts show the single `tax` line.
class Check {
  const Check({
    required this.lines,
    required this.subtotal,
    required this.taxLines,
    required this.tax,
    required this.taxRatePct,
    required this.total,
    this.discounts = const [],
    this.discountTotal = '0.00',
    this.charges = const [],
    this.chargeTotal = '0.00',
    this.payments = const [],
    this.paid = '0.00',
    this.due = '0.00',
    this.estimated = false,
  });

  factory Check.fromJson(Map<String, dynamic> json) => Check(
    lines: (json['lines'] as List? ?? const []).map((l) => CheckLine.fromJson(l as Map<String, dynamic>)).toList(),
    subtotal: json['subtotal'] as String? ?? '0.00',
    discounts: (json['discounts'] as List? ?? const [])
        .map((d) => CheckDiscount.fromJson(d as Map<String, dynamic>))
        .toList(),
    discountTotal: json['discount_total'] as String? ?? '0.00',
    charges: (json['charges'] as List? ?? const [])
        .map((c) => CheckCharge.fromJson(c as Map<String, dynamic>))
        .toList(),
    chargeTotal: json['charge_total'] as String? ?? '0.00',
    taxLines: (json['tax_lines'] as List? ?? const []).map((t) => TaxLine.fromJson(t as Map<String, dynamic>)).toList(),
    tax: json['tax'] as String? ?? '0.00',
    taxRatePct: json['tax_rate_pct'] as String? ?? '',
    total: json['total'] as String? ?? '0.00',
    payments: (json['payments'] as List? ?? const [])
        .map((p) => CheckPayment.fromJson(p as Map<String, dynamic>))
        .toList(),
    paid: json['paid'] as String? ?? '0.00',
    due: json['due'] as String? ?? json['total'] as String? ?? '0.00',
  );

  final List<CheckLine> lines;
  final String subtotal; // the lines before any discount
  final List<CheckDiscount> discounts;
  final String discountTotal;
  final List<CheckCharge> charges;
  final String chargeTotal;
  final List<TaxLine> taxLines;
  final String tax;
  final String taxRatePct; // the combined rate, e.g. 7.00: customers see one tax line
  final String total;

  /// Counter mode pays before the kitchen sees the order; `due` is what is still owed.
  final List<CheckPayment> payments;
  final String paid;
  final String due;

  /// Worked out on this device for lines the backend has not priced yet; replaced by its next answer.
  final bool estimated;

  CheckLine? line(String lineId) {
    for (final l in lines) {
      if (l.lineId == lineId) return l;
    }
    return null;
  }
}
