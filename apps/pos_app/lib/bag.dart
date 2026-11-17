/// What goes in the bag with a to-go order (docs/to-go-question.md): the one question asked before the order
/// is sent, as the location set it, and its answer as the order carries it.
library;

/// One thing the customer may want in the bag: chopsticks, forks, napkins.
class BagChoice {
  const BagChoice({this.id, required this.name});
  factory BagChoice.fromJson(Map<String, dynamic> json) =>
      BagChoice(id: json['id'] as String?, name: json['name']?.toString() ?? '');

  /// Null for a choice new on the manager's screen: the hub names it from its name.
  final String? id;
  final String name;

  Map<String, dynamic> toJson() => {'id': ?id, 'name': name};
}

/// The question as the location set it: whether it is asked, its words and its choices in the order the
/// buttons show. "Nothing" is always an answer.
class BagQuestion {
  const BagQuestion({this.enabled = true, this.question = standardWords, this.choices = const []});
  factory BagQuestion.fromJson(Map<String, dynamic> json) => BagQuestion(
    enabled: json['enabled'] != false,
    question: (json['question']?.toString() ?? '').trim().isEmpty ? standardWords : json['question'].toString(),
    choices: [for (final c in json['choices'] as List? ?? const []) BagChoice.fromJson(c as Map<String, dynamic>)],
  );

  static const standardWords = 'What goes in the bag?';

  /// The most choices a location lists, as the hub holds it: one screenful of buttons.
  static const mostChoices = 8;

  /// How long a choice's name may be: a button on a phone and a line of the ticket.
  static const nameMax = 24;
  static const questionMax = 60;

  final bool enabled;
  final String question;
  final List<BagChoice> choices;

  /// Whether a to-go order is asked about before it is sent: turned on, with something to offer.
  bool get asks => enabled && choices.any((c) => c.id != null);

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'question': question,
    'choices': [for (final c in choices) c.toJson()],
  };
}

/// One thing in the bag and how many: the name it was offered under goes with it, so a choice renamed or
/// dropped later still reads as it was asked.
class BagItem {
  const BagItem({required this.id, required this.name, this.qty = 1});

  final String id;
  final String name;
  final int qty;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'qty': qty};

  @override
  bool operator ==(Object other) => other is BagItem && other.id == id && other.name == name && other.qty == qty;

  @override
  int get hashCode => Object.hash(id, name, qty);

  @override
  String toString() => qty > 1 ? '${qty}x $name' : name;
}

/// The most of one thing: what the hub takes.
const bagQtyMax = 99;

/// The answer an order carries, read from its `bag` field: the things in the bag in the order they were
/// picked (none: nothing was wanted), or null while nobody was asked. An answer this build cannot read is
/// as good as none.
List<BagItem>? bagAnswer(Map<String, dynamic> fields) {
  final value = fields['bag'];
  if (value is! Map) return null;
  final listed = value['items'];
  if (listed is! List) return null;
  final items = <BagItem>[];
  for (final entry in listed) {
    if (entry is! Map || entry['id'] is! String) return null;
    final qty = entry['qty'];
    items.add(
      BagItem(
        id: entry['id'] as String,
        name: entry['name']?.toString() ?? entry['id'] as String,
        qty: qty is int && qty > 0 ? qty : 1,
      ),
    );
  }
  return items;
}

/// The answer as an order's `bag` field takes it.
Map<String, dynamic> bagField(List<BagItem> items) => {
  'items': [for (final item in items) item.toJson()],
};

/// The answer in a line: "2x Chopsticks, Forks", or "Nothing".
String bagWords(List<BagItem> items) => items.isEmpty ? 'Nothing' : items.join(', ');
