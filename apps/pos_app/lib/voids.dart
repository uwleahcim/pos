/// Voids of dishes the kitchen already has, as the location sets them (`GET /settings/voids`): whether a
/// manager's PIN is needed, and the short list of reasons the person voiding picks from. A manager edits both
/// under Location settings. A dish the kitchen has not seen simply comes off the check: none of this applies.
///
/// A void in the order log carries its reason's id and the name it had then, so a reason can be renamed or
/// dropped freely. The hub holds every void to these rules itself; the app only asks first.
library;

class VoidReason {
  const VoidReason({this.id, required this.name});
  factory VoidReason.fromJson(Map<String, dynamic> json) =>
      VoidReason(id: json['id'] as String?, name: json['name'] as String? ?? '');

  /// Null for a reason new on the settings screen: the hub names it from its name when it is saved.
  final String? id;
  final String name;

  Map<String, dynamic> toJson() => {'id': ?id, 'name': name};
}

class VoidRules {
  const VoidRules({this.needsManager = true, this.reasons = const []});
  factory VoidRules.fromJson(Map<String, dynamic> json) => VoidRules(
    needsManager: json['approval'] != 'none',
    reasons: [for (final r in json['reasons'] as List? ?? const []) VoidReason.fromJson(r as Map<String, dynamic>)],
  );

  /// A manager types their PIN for every void of a sent dish; off, the reason alone will do.
  final bool needsManager;
  final List<VoidReason> reasons;

  Map<String, dynamic> toJson() => {
    'approval': needsManager ? 'manager' : 'none',
    'reasons': [for (final r in reasons) r.toJson()],
  };
}

/// One line of a total in the report: a reason or a name, what it came to and how many times.
class ReportTotal {
  const ReportTotal({required this.key, required this.amount, this.count});
  factory ReportTotal.fromJson(Map<String, dynamic> json) => ReportTotal(
    key: json['key'] as String? ?? '',
    amount: json['amount']?.toString() ?? '0.00',
    count: json['count'] as int?,
  );

  final String key;
  final String amount;
  final int? count;
}

/// A dish voided after the kitchen had it: what, how many and what they were worth, why, who voided it, who
/// approved it and when.
class VoidRow {
  const VoidRow({
    required this.orderId,
    required this.item,
    required this.qty,
    required this.amount,
    required this.atMs,
    this.table,
    this.orderNo,
    this.reason = '',
    this.by = '',
    this.approvedBy = '',
  });
  factory VoidRow.fromJson(Map<String, dynamic> json) => VoidRow(
    orderId: json['order_id'] as String? ?? '',
    item: json['item'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    amount: json['amount']?.toString() ?? '0.00',
    atMs: json['at_ms'] as int? ?? 0,
    table: json['table']?.toString(),
    orderNo: json['order_no'] as int?,
    reason: json['reason_name'] as String? ?? '',
    by: json['by'] as String? ?? '',
    approvedBy: (json['approved_by'] as Map?)?['name'] as String? ?? '',
  );

  final String orderId;
  final String item;
  final int qty;
  final String amount;
  final int atMs;
  final String? table;
  final int? orderNo;
  final String reason;
  final String by;
  final String approvedBy;

  /// Where it was: the table, or the takeout order's number.
  String get where => checkName(table, orderNo);
}

/// A dish taken off a check before the kitchen saw it (or fewer of one kept): what, how many and what they
/// were worth, who took it off, who had rung it in, when, and how long it had been on the check.
class TakenOffRow {
  const TakenOffRow({
    required this.orderId,
    required this.item,
    required this.qty,
    required this.amount,
    required this.atMs,
    this.onCheckMs = 0,
    this.table,
    this.orderNo,
    this.by = '',
    this.rungBy = '',
  });
  factory TakenOffRow.fromJson(Map<String, dynamic> json) => TakenOffRow(
    orderId: json['order_id'] as String? ?? '',
    item: json['item'] as String? ?? '',
    qty: json['qty'] as int? ?? 1,
    amount: json['amount']?.toString() ?? '0.00',
    atMs: json['at_ms'] as int? ?? 0,
    onCheckMs: json['on_check_ms'] as int? ?? 0,
    table: json['table']?.toString(),
    orderNo: json['order_no'] as int?,
    by: json['by'] as String? ?? '',
    rungBy: json['rung_by'] as String? ?? '',
  );

  final String orderId;
  final String item;
  final int qty;
  final String amount;
  final int atMs;

  /// How long the dish had been on the check when it came off: seconds for a slip of the finger, a good
  /// while for a dish that was served first.
  final int onCheckMs;
  final String? table;
  final int? orderNo;

  /// Who took it off; empty from an app older than the question.
  final String by;
  final String rungBy;

  /// Where it was: the table, or the takeout order's number.
  String get where => checkName(table, orderNo);

  /// Who, as far as the log knows: whoever took it off, or at least whoever rang it in.
  String get who => by.isNotEmpty
      ? 'by $by'
      : rungBy.isNotEmpty
      ? 'rung in by $rungBy'
      : '';

  /// "under a minute on the check", "14 min on the check", "1 h 5 min on the check".
  String get onCheck {
    final minutes = onCheckMs ~/ 60000;
    if (minutes < 1) return 'under a minute on the check';
    return minutes < 60 ? '$minutes min on the check' : '${minutes ~/ 60} h ${minutes % 60} min on the check';
  }
}

/// A dish sold at a price somebody typed when it was rung: a market price, or an off-menu dish whose name
/// was typed too. What it was called, how many, at how much each, who rang it in, on which check and when.
class TypedRow {
  const TypedRow({
    required this.item,
    required this.qty,
    required this.unitPrice,
    required this.amount,
    required this.atMs,
    this.menuName = '',
    this.named = false,
    this.voided = false,
    this.table,
    this.orderNo,
    this.by = '',
  });
  factory TypedRow.fromJson(Map<String, dynamic> json) => TypedRow(
    item: json['item'] as String? ?? '',
    menuName: json['menu_name'] as String? ?? '',
    named: json['named'] as bool? ?? false,
    qty: json['qty'] as int? ?? 1,
    unitPrice: json['unit_price']?.toString() ?? '0.00',
    amount: json['amount']?.toString() ?? '0.00',
    voided: json['voided'] as bool? ?? false,
    atMs: json['at_ms'] as int? ?? 0,
    table: json['table']?.toString(),
    orderNo: json['order_no'] as int?,
    by: json['by'] as String? ?? '',
  );

  /// What the check calls it: what was typed for an off-menu dish, the dish's own name for a market price.
  final String item;

  /// What the menu calls the dish it was rung as ("Open Food"); the same as [item] unless [named].
  final String menuName;

  /// Its name was typed too: an off-menu dish.
  final bool named;
  final int qty;
  final String unitPrice;

  /// What it came to; nothing once it was voided, which the voids above value.
  final String amount;
  final bool voided;
  final int atMs;
  final String? table;
  final int? orderNo;
  final String by;

  /// Where it is: the table, or the takeout order's number.
  String get where => checkName(table, orderNo);
}

/// A check as a report names it: its table, or its takeout number; nothing when it has neither.
String checkName(String? table, int? orderNo) => table != null && table.isNotEmpty
    ? 'Table $table'
    : orderNo != null
    ? '#$orderNo'
    : '';

/// A discount or comp still on a check: what came off, why, who put it on and who approved it.
class DiscountRow {
  const DiscountRow({
    required this.amount,
    this.reasonId = '',
    this.reason = '',
    this.table,
    this.appliedBy = '',
    this.approvedBy = '',
  });
  factory DiscountRow.fromJson(Map<String, dynamic> json) => DiscountRow(
    amount: json['amount']?.toString() ?? '0.00',
    reasonId: json['reason'] as String? ?? '',
    reason: json['name'] as String? ?? json['reason'] as String? ?? '',
    table: json['table']?.toString(),
    appliedBy: json['applied_by'] as String? ?? '',
    approvedBy: (json['approved_by'] as Map?)?['name'] as String? ?? '',
  );

  final String amount;

  /// The reason as the pricing rules key it, and as they name it ("Manager comp").
  final String reasonId;
  final String reason;
  final String? table;
  final String appliedBy;
  final String approvedBy;
}

/// What came off the register and why (`GET /reports/adjustments`): the voids of sent dishes and the
/// discounts and comps, each added up by reason, by who did it and by who approved it; and the dishes taken
/// off before the kitchen saw them, which nothing else shows.
class AdjustmentsReport {
  const AdjustmentsReport({
    this.voids = const [],
    this.voidTotal = '0.00',
    this.voidsByReason = const [],
    this.voidsByStaff = const [],
    this.voidsByApprover = const [],
    this.discounts = const [],
    this.discountTotal = '0.00',
    this.discountsByReason = const [],
    this.discountsByStaff = const [],
    this.discountsByApprover = const [],
    this.hasVoids = true,
    this.takenOff = const [],
    this.takenOffTotal = '0.00',
    this.takenOffByStaff = const [],
    this.takenOffByCheck = const [],
    this.hasTakenOff = true,
    this.typed = const [],
    this.typedTotal = '0.00',
    this.typedByStaff = const [],
    this.hasTyped = false,
  });
  factory AdjustmentsReport.fromJson(Map<String, dynamic> json) {
    List<ReportTotal> totals(String name) => [
      for (final t in json[name] as List? ?? const []) ReportTotal.fromJson(t as Map<String, dynamic>),
    ];
    return AdjustmentsReport(
      voids: [for (final v in json['voids'] as List? ?? const []) VoidRow.fromJson(v as Map<String, dynamic>)],
      voidTotal: json['void_total']?.toString() ?? '0.00',
      voidsByReason: totals('voids_by_reason'),
      voidsByStaff: totals('voids_by_staff'),
      voidsByApprover: totals('voids_by_approver'),
      discounts: [
        for (final d in json['discounts'] as List? ?? const []) DiscountRow.fromJson(d as Map<String, dynamic>),
      ],
      discountTotal: json['discount_total']?.toString() ?? '0.00',
      discountsByReason: totals('by_reason'),
      discountsByStaff: totals('by_staff'),
      discountsByApprover: totals('by_approver'),
      hasVoids: json.containsKey('voids'),
      takenOff: [
        for (final t in json['taken_off'] as List? ?? const []) TakenOffRow.fromJson(t as Map<String, dynamic>),
      ],
      takenOffTotal: json['taken_off_total']?.toString() ?? '0.00',
      takenOffByStaff: totals('taken_off_by_staff'),
      takenOffByCheck: [
        for (final c in (json['taken_off_by_check'] as List? ?? const []).cast<Map<String, dynamic>>())
          ReportTotal(
            // a to-go check by its number and whose it is: "#41 Linda"
            key: [
              checkName(c['table']?.toString(), c['order_no'] as int?),
              if (c['table'] == null) c['customer_name']?.toString() ?? '',
            ].where((word) => word.isNotEmpty).join(' '),
            amount: c['amount']?.toString() ?? '0.00',
            count: c['count'] as int?,
          ),
      ],
      hasTakenOff: json.containsKey('taken_off'),
      typed: [for (final t in json['typed'] as List? ?? const []) TypedRow.fromJson(t as Map<String, dynamic>)],
      typedTotal: json['typed_total']?.toString() ?? '0.00',
      typedByStaff: totals('typed_by_staff'),
      hasTyped: json.containsKey('typed'),
    );
  }

  final List<VoidRow> voids;
  final String voidTotal;
  final List<ReportTotal> voidsByReason;
  final List<ReportTotal> voidsByStaff;
  final List<ReportTotal> voidsByApprover;
  final List<DiscountRow> discounts;
  final String discountTotal;
  final List<ReportTotal> discountsByReason;
  final List<ReportTotal> discountsByStaff;
  final List<ReportTotal> discountsByApprover;

  /// False from a hub older than the void report: its answer lists no voids at all.
  final bool hasVoids;

  /// The dishes taken off checks before the kitchen saw them, oldest first, what they came to, and the
  /// same added up by who took them off and by check.
  final List<TakenOffRow> takenOff;
  final String takenOffTotal;
  final List<ReportTotal> takenOffByStaff;
  final List<ReportTotal> takenOffByCheck;

  /// False from a hub older than that list.
  final bool hasTakenOff;

  /// The dishes sold at a typed price (market prices and off-menu dishes), oldest first, what they came to,
  /// and the same added up by who rang them in. One voided since is listed and counts for nothing.
  final List<TypedRow> typed;
  final String typedTotal;
  final List<ReportTotal> typedByStaff;

  /// False from a hub older than typed prices: it has no such dish, and the report says nothing of them.
  final bool hasTyped;

  /// How many dishes stand on checks at a typed price: a row of two is two, a voided row none.
  int get typedDishes => typed.fold(0, (sum, row) => sum + (row.voided ? 0 : row.qty));

  /// How many dishes came off before they were sent: a row of two teas is two.
  int get takenOffDishes => takenOff.fold(0, (sum, row) => sum + row.qty);

  /// The same rows, the dish that was longest on its check first: a slip of the finger sinks to the end.
  List<TakenOffRow> get takenOffLongestFirst =>
      [...takenOff]
        ..sort((a, b) => b.onCheckMs != a.onCheckMs ? b.onCheckMs.compareTo(a.onCheckMs) : a.atMs.compareTo(b.atMs));

  /// A discount reason's name for the key the totals carry (the rules' own word for it).
  String discountReason(String key) => discounts.where((d) => d.reasonId == key).firstOrNull?.reason ?? key;
}
