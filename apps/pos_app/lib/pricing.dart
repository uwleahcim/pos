/// The discount reasons and service charges a location allows (`GET /pricing/rules`). The hub owns them and
/// enforces them again when an operation arrives; the discount sheet shows them so an operator is not
/// offered what the hub would refuse.
library;

/// A reason a price may come down, and its limits.
class DiscountRule {
  const DiscountRule({
    required this.code,
    required this.name,
    this.kinds = const ['percent', 'amount'],
    this.scopes = const ['line', 'check'],
    this.maxPercent,
    this.maxAmount,
    this.fixedPercent,
    this.approval = 'manager',
    this.stacks = false,
  });

  factory DiscountRule.fromJson(Map<String, dynamic> json) => DiscountRule(
    code: json['code'] as String,
    name: json['name'] as String? ?? json['code'] as String,
    kinds: List<String>.from(json['kinds'] as List? ?? const ['percent', 'amount']),
    scopes: List<String>.from(json['scopes'] as List? ?? const ['line', 'check']),
    maxPercent: json['max_percent'] as String?,
    maxAmount: json['max_amount'] as String?,
    fixedPercent: json['fixed_percent'] as String?,
    approval: json['approval'] as String? ?? 'manager',
    stacks: json['stacks'] as bool? ?? false,
  );

  final String code;
  final String name;
  final List<String> kinds; // percent | amount | comp
  final List<String> scopes; // line | check
  final String? maxPercent;
  final String? maxAmount;
  final String? fixedPercent; // a staff meal is always its percentage
  final String approval; // none | manager
  final bool stacks;

  bool get needsManager => approval == 'manager';
  bool get onLines => scopes.contains('line');
  bool get onCheck => scopes.contains('check');

  /// Why this value is not allowed for `kind`, or null when it is: the hub's own checks, made here first.
  String? problem(String kind, String value) {
    if (!kinds.contains(kind)) return '$name cannot be a $kind discount';
    if (kind == 'comp') return null;
    final number = double.tryParse(value);
    if (number == null || number <= 0) return kind == 'percent' ? 'Enter a percentage' : 'Enter an amount';
    if (kind == 'percent') {
      if (number > 100) return 'At most 100%';
      final fixed = fixedPercent;
      if (fixed != null && number != double.parse(fixed)) return '$name is always $fixed%';
      final max = maxPercent;
      if (max != null && number > double.parse(max)) return 'At most $max%';
    } else {
      final max = maxAmount;
      if (max != null && number > double.parse(max)) return 'At most \$$max';
    }
    return null;
  }
}

/// A service charge: automatic when its conditions hold (a party's gratuity, a delivery fee), or put on by staff.
class ChargeRule {
  const ChargeRule({
    required this.code,
    required this.name,
    required this.kind,
    required this.value,
    this.gratuity = false,
    this.automatic = false,
    this.removal = 'manager',
  });

  factory ChargeRule.fromJson(Map<String, dynamic> json) => ChargeRule(
    code: json['code'] as String,
    name: json['name'] as String? ?? json['code'] as String,
    kind: json['kind'] as String? ?? 'percent',
    value: json['value']?.toString() ?? '0',
    gratuity: json['gratuity'] as bool? ?? false,
    automatic: json['automatic'] as bool? ?? false,
    removal: json['removal'] as String? ?? 'manager',
  );

  final String code;
  final String name;
  final String kind; // percent | amount
  final String value;
  final bool gratuity;
  final bool automatic;
  final String removal; // none | manager: who may take an automatic one off

  bool get needsManagerToRemove => automatic && removal == 'manager';
  String get label => kind == 'percent' ? '$name · $value%' : '$name · \$$value';
}

class PricingRules {
  const PricingRules({this.discounts = const [], this.charges = const []});

  factory PricingRules.fromJson(Map<String, dynamic> json) => PricingRules(
    discounts: (json['discounts'] as List? ?? const [])
        .map((d) => DiscountRule.fromJson(d as Map<String, dynamic>))
        .toList(),
    charges: (json['charges'] as List? ?? const []).map((c) => ChargeRule.fromJson(c as Map<String, dynamic>)).toList(),
  );

  final List<DiscountRule> discounts;
  final List<ChargeRule> charges;

  /// Charges staff put on themselves; the automatic ones the hub applies by itself.
  List<ChargeRule> get manualCharges => charges.where((c) => !c.automatic).toList();

  ChargeRule? charge(String code) => charges.where((c) => c.code == code).firstOrNull;
}

/// What the discount sheet hands back: the operation to send, its data without an id, and whether a
/// manager has to put in a PIN first.
class Adjustment {
  const Adjustment({required this.op, required this.data, required this.needsManager, required this.label});

  final String op; // discount | charge
  final Map<String, dynamic> data;
  final bool needsManager;
  final String label;
}
