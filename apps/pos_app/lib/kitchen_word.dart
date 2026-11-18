/// What the kitchen has said of a dish, for the people who carry the food (docs/kitchen-screens.md).
///
/// A cook marks a dish made at a station's screen, and the pass marks it gone out. The hub reads those marks
/// for the floor (`pos.printing.made`): a dish is ready once every station that cooks it has made its part,
/// and it went out once the pass, or the server who carried it, said so. A dish the kitchen said nothing of
/// has no word, so a kitchen that works off paper shows nothing here.
library;

import 'takeout.dart' show clockTime;

/// How long a dish that is ready stays pointed at (the badge on its table, the strip over its check) when
/// nobody says it went out: a kitchen with no screen at the pass has nobody to say so, and a table is not
/// marked for the rest of the evening over food that was eaten long ago. The dish itself keeps its words.
const readyShownMs = 15 * Duration.millisecondsPerMinute;

/// What a `done` of the pass names in place of a station: the dish went out. A server who carried the dish
/// says the same word.
const passStation = '*pass';

class KitchenWord {
  const KitchenWord({this.readyMs, this.outMs, this.cooks = const []});

  /// Null for anything that is not a word: a dish nobody marked, a hub older than these words.
  static KitchenWord? fromJson(Object? json) {
    if (json is! Map) return null;
    return KitchenWord(
      readyMs: (json['ready_ms'] as num?)?.toInt(),
      outMs: (json['out_ms'] as num?)?.toInt(),
      cooks: [
        for (final cook in json['cooks'] as List? ?? const [])
          if (cook is Map) (name: cook['name']?.toString() ?? '', made: cook['made'] == true),
      ],
    );
  }

  /// When the last of its stations made its part; null while one of them still works on it.
  final int? readyMs;

  /// When it went out to the guest; null while it has not.
  final int? outMs;

  /// The stations that cook it, by name, and whether each has made its part.
  final List<({String name, bool made})> cooks;

  bool get isOut => outMs != null;

  /// Made at every station that cooks it and not gone out: it waits for someone to carry it.
  bool get isReady => readyMs != null && outMs == null;

  /// Ready, and made so lately that it is still pointed at ([readyShownMs]).
  bool waitsAt(int nowMs) => isReady && nowMs - readyMs! < readyShownMs;

  /// The line under the dish on its check: "went out 18:52", "ready 18:50", or for a dish of two stations
  /// with one still cooking, "Wok ready · waiting on Sushi bar". Null when there is nothing to say.
  String? get words {
    if (outMs case final at?) return 'went out ${clockTime(at)}';
    if (readyMs case final at?) return 'ready ${clockTime(at)}';
    final made = [
      for (final cook in cooks)
        if (cook.made) cook.name,
    ];
    final waits = [
      for (final cook in cooks)
        if (!cook.made) cook.name,
    ];
    if (made.isEmpty || waits.isEmpty) return null;
    return '${made.join(', ')} ready · waiting on ${waits.join(', ')}';
  }

  /// The same word once the dish went out at [at], or with that taken back ([at] null).
  KitchenWord out(int? at) => KitchenWord(readyMs: readyMs, outMs: at, cooks: cooks);
}
