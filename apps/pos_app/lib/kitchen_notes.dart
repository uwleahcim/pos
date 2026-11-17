/// One-tap notes to the kitchen (docs/kitchen-notes.md): the short list of words a location sets, such as
/// "Rush" or "Split for 2", and how a tap on one puts it in a dish's note or takes it out again.
library;

/// The notes as the location lists them, in the order the buttons show.
class KitchenNotes {
  const KitchenNotes([this.notes = const []]);
  factory KitchenNotes.fromJson(Map<String, dynamic> json) => KitchenNotes([
    for (final note in json['notes'] as List? ?? const [])
      if (note is String && note.trim().isNotEmpty) note.trim(),
  ]);

  /// The most notes a location lists, as the hub holds it: two or three rows of buttons on a phone.
  static const most = 12;

  /// How long a note may be: a button on a phone, and words a cook reads at a glance.
  static const noteMax = 24;

  final List<String> notes;

  Map<String, dynamic> toJson() => {'notes': notes};
}

/// A dish's note in its parts: what was tapped and what was typed, told apart by the commas between them.
List<String> noteParts(String note) => [
  for (final part in note.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Whether [note] already says [words], whatever the capitals.
bool hasNote(String note, String words) =>
    noteParts(note).any((part) => part.toLowerCase() == words.trim().toLowerCase());

/// [note] after a tap on [words]: with them at the end, or without them when they were there. What was typed
/// around them stays.
String toggleNote(String note, String words) {
  final parts = noteParts(note);
  final said = words.trim();
  if (said.isEmpty) return parts.join(', ');
  final without = [
    for (final part in parts)
      if (part.toLowerCase() != said.toLowerCase()) part,
  ];
  return (without.length < parts.length ? without : [...parts, said]).join(', ');
}
