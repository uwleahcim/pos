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
  String get where => table != null && table!.isNotEmpty
      ? 'Table $table'
      : orderNo != null
      ? '#$orderNo'
      : '';
}

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
/// discounts and comps, each added up by reason, by who did it and by who approved it.
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

  /// A discount reason's name for the key the totals carry (the rules' own word for it).
  String discountReason(String key) => discounts.where((d) => d.reasonId == key).firstOrNull?.reason ?? key;
}
