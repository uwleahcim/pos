/// An allergy a guest told the server of, kept on the order for one seat or for the whole table (an `allergy`
/// operation in the order log; the latest word on each seat stands, and one with nothing in it takes the
/// allergy off). The hub prints it on every station's ticket and says which dishes the menu lists as
/// containing it; the app notes it and shows what the hub says.
///
/// A dish with no mark is not a promise: the mark only knows what the menu data says a dish contains.
library;

/// How long the words typed beside the allergens may be, as the hub cuts them.
const allergyNoteMax = 80;

/// An allergen the menu names (`GET /menu/allergens`): one of the buttons the server picks from.
class Allergen {
  const Allergen({required this.code, required this.name});
  factory Allergen.fromJson(Map<String, dynamic> json) {
    final code = json['code'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    return Allergen(code: code, name: name.isEmpty ? code : name);
  }

  final String code;
  final String name;
}

/// The allergens by code, to name the ones an order carries.
Map<String, String> allergenNames(List<Allergen> allergens) => {for (final a in allergens) a.code: a.name};

class Allergy {
  const Allergy({this.seat, this.allergens = const [], this.note = ''});

  /// Read the way the hub reads it, from its answer or from an operation this screen has yet to send: a seat
  /// that is no seat is the table, each allergen once, the words on one line and no longer than the hub keeps.
  factory Allergy.fromJson(Map<String, dynamic> json) {
    final seat = json['seat'];
    final allergens = json['allergens'];
    final note = json['note'];
    return Allergy(
      seat: seat is int && seat > 0 ? seat : null,
      allergens: <String>{
        if (allergens is List)
          for (final a in allergens)
            if (a is String && a.trim().isNotEmpty) a.trim(),
      }.toList(),
      note: note is String ? cleanNote(note) : '',
    );
  }

  /// The seat it was told for; null for the whole table, and for a to-go order.
  final int? seat;

  /// The menu's codes for what the guest cannot have.
  final List<String> allergens;

  /// Whatever else was said ("no oyster sauce", "severe").
  final String note;

  /// Nothing in it: sent, it takes the seat's allergy off.
  bool get isEmpty => allergens.isEmpty && note.isEmpty;

  static String cleanNote(String note) {
    final oneLine = note.trim().replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length <= allergyNoteMax ? oneLine : oneLine.substring(0, allergyNoteMax).trimRight();
  }

  /// "Peanuts, Sesame - no oyster sauce", the way the kitchen's ticket words it. An allergen the menu no
  /// longer names shows by its code, never dropped.
  String words(Map<String, String> names) => [
    if (allergens.isNotEmpty) [for (final code in allergens) names[code] ?? code].join(', '),
    if (note.isNotEmpty) note,
  ].join(' - ');

  /// The `allergy` operation's data, signed by who noted it.
  Map<String, dynamic> toOp({String? by, String? byId}) => {
    'seat': ?seat,
    'allergens': allergens,
    'note': note,
    'by': ?by,
    'by_id': ?byId,
  };

  bool same(Allergy other) =>
      seat == other.seat && note == other.note && allergens.join('\n') == other.allergens.join('\n');
}

/// Every allergy on an order on one line: "Table: Peanuts · Seat 2: Sesame - no oyster sauce". A to-go order
/// has no seats, so its one allergy stands alone.
String allergySummary(List<Allergy> told, Map<String, String> names, {required bool seated}) => [
  for (final a in told)
    if (!seated) a.words(names) else '${a.seat == null ? 'Table' : 'Seat ${a.seat}'}: ${a.words(names)}',
].join(' · ');

/// What the menu says a dish has in it that its seat cannot have: "contains Wheat, Soybeans".
String containsWords(List<String> codes, Map<String, String> names) =>
    'contains ${[for (final code in codes) names[code] ?? code].join(', ')}';
