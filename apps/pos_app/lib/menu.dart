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
    this.linkedItem,
    this.groups = const [],
    this.maxQty,
  });

  factory OptionDetail.fromJson(Map<String, dynamic> json) => OptionDetail(
    maxQty: json['max_qty'] as int?,
    optionId: json['option_id'] as String,
    name: json['name'] as String? ?? '',
    price: json['price'] as String? ?? '0.00',
    isDefault: json['is_default'] as bool? ?? false,
    status: json['status'] as String? ?? 'available',
    linkedItem: json['linked_item'] as String?,
    groups: (json['groups'] as List? ?? const []).map((g) => GroupDetail.fromJson(g as Map<String, dynamic>)).toList(),
  );

  final String optionId;
  final String name;

  /// What choosing it adds to the dish: for a choice that is a dish, what the slot charges for it.
  final String price;
  final bool isDefault;
  final String status;

  /// The dish this choice is (the soup with a lunch special, a roll of the maki combination), when it is one.
  final String? linkedItem;

  /// That dish's own choices, asked one level down once the option is chosen.
  final List<GroupDetail> groups;

  /// How many of it one dish takes, in a group that takes several of the same choice; null for no limit.
  final int? maxQty;

  bool get available => status == 'available';
  bool get free => double.tryParse(price) == 0;
  bool get isDish => linkedItem != null;
}

class GroupDetail {
  const GroupDetail({
    required this.groupId,
    required this.name,
    required this.minSelect,
    required this.options,
    this.maxSelect,
    this.allowQuantity = false,
  });

  factory GroupDetail.fromJson(Map<String, dynamic> json) => GroupDetail(
    allowQuantity: json['allow_quantity'] as bool? ?? false,
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

  /// The same choice can go on a dish several times (two chicken fingers on an appetizer platter); each one
  /// counts toward [minSelect] and [maxSelect].
  final bool allowQuantity;

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

/// What was chosen on a dish: the options picked in each of its groups, the word on any of them, and, for a
/// choice that is itself a dish (the soup with a lunch special, each roll of a maki combination), the choices
/// made on that dish, one level down. A screen asks a dish's choices the same way at every level.
class Choices {
  Choices({
    Map<String, List<String>>? selections,
    Map<String, String>? prefixes,
    Map<String, Choices>? nested,
    Map<String, int>? quantities,
    this.notes,
  }) : selections = selections ?? {},
       prefixes = prefixes ?? {},
       nested = nested ?? {},
       quantities = quantities ?? {};

  final Map<String, List<String>> selections; // group id -> option ids

  /// An instruction on a chosen option (option id -> no | extra | side | light): "no peanuts" without an
  /// option of its own. The backend prints it in front of the kitchen label and makes a "no" free.
  final Map<String, String> prefixes;

  /// The choices on the dish behind a chosen option, by option id; sent as the selection's `children`.
  final Map<String, Choices> nested;

  /// A note to the kitchen on the dish these choices are on: the line's `notes` on the order line, a
  /// selection's `notes` on a dish chosen as a choice ("no sesame" on a roll of the maki combination). The
  /// kitchen prints it with that dish and the check shows it under it.
  String? notes;

  /// How many of a chosen option, where it is more than one (option id -> count): two chicken fingers on an
  /// appetizer platter. Sent as the selection's `qty`; only a group that takes quantities fills it.
  final Map<String, int> quantities;

  bool picked(String groupId, String optionId) => selections[groupId]?.contains(optionId) ?? false;

  /// How many of [optionId] are on the line once it is picked.
  int qty(String optionId) => quantities[optionId] ?? 1;

  /// What a group's picks count for toward its least and most: each choice times how many of it.
  int units(String groupId) => (selections[groupId] ?? const <String>[]).fold(0, (n, id) => n + qty(id));

  /// How many of a group's most its picks take up: a choice marked "no" takes no place, so the platter's crab
  /// rangoon marked "no" leaves room for a second chicken finger.
  int taken(String groupId) =>
      (selections[groupId] ?? const <String>[]).fold(0, (n, id) => n + (prefixes[id] == 'no' ? 0 : qty(id)));

  /// Whether [group] has room for one more pick.
  bool room(GroupDetail group) => group.maxSelect == null || taken(group.groupId) < group.maxSelect!;

  /// Whether one more of [option], already on the line, can go on it: the group takes quantities, has room,
  /// the option is under its own limit, and it is not marked "no" (none of it, however many).
  bool canAddOne(GroupDetail group, OptionDetail option) =>
      group.allowQuantity &&
      picked(group.groupId, option.optionId) &&
      prefixes[option.optionId] != 'no' &&
      (option.maxQty == null || qty(option.optionId) < option.maxQty!) &&
      room(group);

  /// One more of a choice already on the line; false when it cannot take another.
  bool addOne(GroupDetail group, OptionDetail option) {
    if (!canAddOne(group, option)) return false;
    quantities[option.optionId] = qty(option.optionId) + 1;
    return true;
  }

  /// One fewer of a choice on the line; the last one takes the choice, and its word, off.
  void removeOne(GroupDetail group, String optionId) {
    final n = qty(optionId);
    if (n > 2) {
      quantities[optionId] = n - 1;
    } else if (n == 2) {
      quantities.remove(optionId);
    } else {
      selections[group.groupId] = [...?selections[group.groupId]]..remove(optionId);
      prefixes.remove(optionId);
    }
  }

  /// Forgets the counts and words of the choices no longer on the line in [group].
  void settle(GroupDetail group) {
    final kept = selections[group.groupId] ?? const <String>[];
    for (final o in group.options) {
      if (!kept.contains(o.optionId)) {
        prefixes.remove(o.optionId);
        quantities.remove(o.optionId);
      } else if (prefixes[o.optionId] == 'no') {
        quantities.remove(o.optionId);
      }
    }
  }

  /// Puts [optionId] on the line in [group] as a tap does: a single-pick group takes it alone, a multi-pick
  /// group adds it while there is room. A word on a choice that leaves the line goes with it.
  void take(GroupDetail group, String optionId) {
    final current = selections[group.groupId] ?? const <String>[];
    if (group.single) {
      selections[group.groupId] = [optionId];
    } else if (!current.contains(optionId) && room(group)) {
      selections[group.groupId] = [...current, optionId];
    }
    settle(group);
  }

  /// The choices on the dish behind [optionId], started empty when there are none yet.
  Choices inside(String optionId) => nested.putIfAbsent(optionId, Choices.new);

  /// The backend's `selections`: one entry per chosen option, with its word and the choices on its dish.
  List<Map<String, dynamic>> selectionsJson() => [
    for (final e in selections.entries)
      for (final option in e.value)
        {
          'group_id': e.key,
          'option_id': option,
          if (qty(option) > 1) 'qty': qty(option),
          if (prefixes[option] != null) 'prefix': prefixes[option],
          if (nested[option] case final inside? when inside.selections.isNotEmpty) 'children': inside.selectionsJson(),
          if (nested[option]?.notes case final notes? when notes.isNotEmpty) 'notes': notes,
        },
  ];

  /// Reads the backend's `selections` into this, children and all.
  void readSelections(List<dynamic>? list) {
    for (final s in list ?? const []) {
      final m = s as Map<String, dynamic>;
      final option = m['option_id'] as String;
      selections.putIfAbsent(m['group_id'] as String, () => []).add(option);
      if (m['prefix'] != null) prefixes[option] = m['prefix'] as String;
      if (m['qty'] case final int n when n > 1) quantities[option] = n;
      final children = m['children'] as List?;
      if (children != null && children.isNotEmpty) inside(option).readSelections(children);
      if (m['notes'] case final String notes when notes.isNotEmpty) inside(option).notes = notes;
    }
  }

  /// A copy deep enough to edit without touching this.
  Choices copyChoices() => Choices(
    selections: {
      for (final e in selections.entries) e.key: [...e.value],
    },
    prefixes: {...prefixes},
    nested: {for (final e in nested.entries) e.key: e.value.copyChoices()},
    quantities: {...quantities},
    notes: notes,
  );
}

/// What the customer chose for one line; the backend's `request` on `add_line`.
class LineRequest extends Choices {
  LineRequest({
    required this.variantId,
    this.entryId,
    super.selections,
    super.prefixes,
    super.nested,
    super.quantities,
    super.notes,
  });

  factory LineRequest.fromJson(Map<String, dynamic> json) => LineRequest(
    variantId: json['variant_id'] as String,
    entryId: json['entry_id'] as String?,
    notes: json['notes'] as String?,
  )..readSelections(json['selections'] as List?);

  /// The same dish with the same choices, from a copy of [choices] when given (the tray's picks).
  factory LineRequest.withChoices(String variantId, String? entryId, Choices choices) {
    final copy = choices.copyChoices();
    return LineRequest(
      variantId: variantId,
      entryId: entryId,
      selections: copy.selections,
      prefixes: copy.prefixes,
      nested: copy.nested,
      quantities: copy.quantities,
      notes: copy.notes,
    );
  }

  LineRequest copy() => LineRequest.withChoices(variantId, entryId, this);

  String variantId;
  final String? entryId;

  Map<String, dynamic> toJson() => {
    'variant_id': variantId,
    'entry_id': ?entryId,
    'selections': selectionsJson(),
    if (notes != null && notes!.isNotEmpty) 'notes': notes,
  };
}

/// A fresh [Choices] holding the menu's defaults for [groups].
Choices defaultChoices(List<GroupDetail> groups) {
  final choices = Choices();
  fillDefaults(groups, choices);
  return choices;
}

/// The required groups on a dish chosen as a choice that the menu's defaults do not answer: what choosing the
/// dish still has to ask. A dish whose defaults answer everything is simply chosen, as its tile would be, and
/// everything else on it waits behind a hold.
List<GroupDetail> openGroups(OptionDetail option) => [
  for (final g in option.groups)
    if (g.required && g.options.where((o) => o.isDefault && o.available).length < g.minSelect) g,
];

/// Whether every required group in [groups] has its picks, down through the dishes chosen as choices.
bool choicesComplete(List<GroupDetail> groups, Choices choices) {
  for (final g in groups) {
    final picked = choices.selections[g.groupId] ?? const <String>[];
    if (choices.units(g.groupId) < g.minSelect) return false;
    for (final o in g.options) {
      if (o.groups.isEmpty || !picked.contains(o.optionId)) continue;
      if (!choicesComplete(o.groups, choices.nested[o.optionId] ?? defaultChoices(o.groups))) return false;
    }
  }
  return true;
}

/// Puts the menu's defaults into [choices] for [groups]: what a dish comes with before anyone changes anything.
/// A default that is a dish brings that dish's own defaults one level down, unless choices were made on it.
void fillDefaults(List<GroupDetail> groups, Choices choices) {
  for (final g in groups) {
    final defaults = [
      for (final o in g.options)
        if (o.isDefault && o.available) o.optionId,
    ];
    if (defaults.isEmpty) continue;
    choices.selections[g.groupId] = defaults;
    for (final o in g.options) {
      if (defaults.contains(o.optionId) && o.groups.isNotEmpty && !choices.nested.containsKey(o.optionId)) {
        fillDefaults(o.groups, choices.inside(o.optionId));
      }
    }
  }
}

/// The choices on a dish as the check lists them before the hub has priced the line: every choice that is not
/// the menu's default or carries a word, with the price of one (a choice marked "no" is free, as the hub makes
/// it). A choice that is a dish is followed by the changed choices on that dish and its note to the kitchen
/// one level deeper, and a dish the menu picked by default is listed when a choice on it changed, so the
/// change reads under its dish.
List<CheckModifier> pickedModifiers(List<GroupDetail> groups, Choices choices, {int depth = 0}) {
  final rows = <CheckModifier>[];
  for (final g in groups) {
    for (final o in g.options) {
      if (!choices.picked(g.groupId, o.optionId)) continue;
      final word = choices.prefixes[o.optionId];
      final dish = choices.nested[o.optionId];
      final inside = [
        if (o.groups.isNotEmpty) ...pickedModifiers(o.groups, dish ?? Choices(), depth: depth + 1),
        if (dish?.notes case final String notes when notes.isNotEmpty) CheckModifier(notes, depth: depth + 1),
      ];
      final n = choices.qty(o.optionId);
      if (word == null && o.isDefault && inside.isEmpty && n == 1) continue;
      final name = word == null ? o.name : '${instructions[word]} ${o.name}';
      rows.add(
        CheckModifier(
          n > 1 ? '${n}x $name' : name, // two of the same choice, as the hub lists them
          price: o.free || word == 'no' ? '0.00' : (double.parse(o.price) * n).toStringAsFixed(2),
          depth: depth,
        ),
      );
      rows.addAll(inside);
    }
  }
  return rows;
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

/// One choice on a check line as the hub lists it: what it is called, the price of one, and what it adds
/// for the line's quantity. A choice that costs nothing ("No scallions", the rice a dish comes with) has no
/// amount to show. An older hub sends the label alone.
class CheckModifier {
  const CheckModifier(this.label, {this.price = '0.00', this.amount = '0.00', this.depth = 0});

  factory CheckModifier.fromJson(Object? json) {
    if (json is! Map) return CheckModifier(json?.toString() ?? '');
    final price = json['price']?.toString() ?? '0.00';
    return CheckModifier(
      json['label'] as String? ?? '',
      price: price,
      amount: json['amount']?.toString() ?? price,
      depth: json['depth'] as int? ?? 0,
    );
  }

  final String label;

  /// Of one; [amount] is for the line's quantity.
  final String price;
  final String amount;

  /// 0 for a choice on the dish; 1 for a choice on a choice that is a dish (the sauce on a roll of the maki
  /// combination), listed under it; and so on. The check indents each level.
  final int depth;

  /// It costs something: the check shows its amount on its line.
  bool get charged => (double.tryParse(price) ?? 0) != 0;
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
    modifiers: [for (final m in json['modifiers'] as List? ?? const []) CheckModifier.fromJson(m)],
    discount: json['discount'] as String? ?? '0.00',
  );

  final String lineId;
  final String name;
  final int qty;
  final String total;
  final int? seat;

  /// Its choices, each its own line on the check under the dish; [total] includes what they add.
  final List<CheckModifier> modifiers;

  /// What came off this line itself (a comp, a percentage or an amount on it); a check discount is its own row.
  final String discount;

  bool get isDiscounted => discount != '0.00' && discount != '0';

  CheckLine withQty(int qty, String total, {String? discount, List<CheckModifier>? modifiers}) => CheckLine(
    lineId: lineId,
    name: name,
    qty: qty,
    total: total,
    seat: seat,
    modifiers: modifiers ?? this.modifiers,
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

  /// The same discount worked out again: its amount on the lines as they are now, and, after an edit, on
  /// the line that took its line's place.
  CheckDiscount withAmount(String amount, {String? lineId}) => CheckDiscount(
    discountId: discountId,
    reason: reason,
    name: name,
    kind: kind,
    value: value,
    amount: amount,
    lineId: lineId ?? this.lineId,
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
