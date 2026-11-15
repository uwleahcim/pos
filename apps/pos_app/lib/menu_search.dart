import 'dart:typed_data';

/// What can be typed to find one dish: its number, the names on its button, and what the kitchen calls it
/// (the label on its ticket, as the original POS abbreviated it: `SHMP CASHEW`).
class SearchText {
  const SearchText({this.number, this.names = const [], this.labels = const []});
  final String? number;
  final List<String?> names;
  final List<String?> labels;
}

/// Finds dishes by what was typed, the best match first (Mike, 2026-11-15: "beef broccoli" finds "Beef with
/// Broccoli" first, then the other beef dishes).
///
/// What was typed is taken word by word, in any order; "with", "and", "&" and the like are not words to look
/// for. A dish is found when every word is somewhere in one of its names, each in a word of its own, be it
/// only how a word starts or letters inside one: what is still being typed finds already. A dish without
/// every word is found when it has at least half of them as whole words (`lo mein` finds the chow mein, not
/// the lobster; `pina colada` does not find the spinach). The order:
///
/// 1. the dish whose number was typed whole;
/// 2. the dishes with every word, then those with fewer of them;
/// 3. the names on the button before the kitchen's label, whose abbreviations would otherwise come before
///    the names while a word is still being typed (`SA` for sauce before the sake);
/// 4. how well the words were met: a whole word (one or several: `roll` is `rolls`) before the start of a
///    word (`broc`), that before letters inside one (`berry` in Strawberry), that before a slip of the
///    keyboard (`brocoli`), which is only looked for when the word typed is in no name on the menu at all,
///    so that `beef` never finds a beer;
/// 5. a word typed earlier before one typed later (the beef dishes before the broccoli dishes);
/// 6. the name with the least beside what was typed, the words in the order typed, the match nearest the
///    start of the name;
/// 7. the menu's own order.
///
/// Two words typed as one find the dish (`eggroll`, `lomein`), and so does one word typed as two (`won ton`
/// for Wonton). Accents and apostrophes need not be typed (`patron`, `tsos`).
///
/// Whatever the plain text match of before found is still found: letters that run across several words of a
/// name are each the end, the whole or the start of a word of their own.
///
/// The dishes are prepared once, when the menu is read: [find] only compares numbers, so that it can run on
/// every key pressed.
class MenuSearch<T> {
  MenuSearch(Iterable<T> dishes, SearchText Function(T dish) textOf) {
    for (final dish in dishes) {
      final text = textOf(dish);
      _entries.add(
        _Entry(
          dish,
          _entries.length,
          text.number?.trim().toLowerCase(),
          [
            for (final name in text.names)
              if (name != null) name.toLowerCase(),
          ],
          [
            for (final name in text.names)
              if (name != null) ?_field(wordsOf(name), 0),
            for (final label in text.labels)
              // the kitchen's marks are not words anyone types: what stands before a colon (`sa:`, `LUN:`),
              // and the single letters (r: comes with rice)
              if (label != null)
                ?_field(wordsOf(label.replaceAll(_mark, ' ')).where((w) => w.length > 1 || !_isAscii(w)).toList(), 1),
          ],
        ),
      );
    }
  }

  /// The most words of what was typed that are looked for: the rest is left out.
  static const _mostWords = 6;

  /// The most words of a name that are looked at: each is a bit of an `int`.
  static const _mostNameWords = 30;

  /// How far [_Matcher] looks for the best way to pair the words typed with a name's words before it keeps
  /// the best it has: only reached by the likes of "a a a a a a".
  static const _mostTries = 160;

  static final _mark = RegExp(r'[^\s:]+:');

  static const _fillers = {'with', 'and', 'w', 'in', 'of', 'the', 'a', 'an', 'or', 'on', 'n'};

  final _entries = <_Entry<T>>[];

  // Every word of every name, once: a word typed is compared with each word here, not with each dish.
  final _words = <String>[];
  final _wordIds = <String, int>{};
  final _named = <bool>[]; // the word is in a name on a button, not only in a kitchen label

  // Every two words that follow one another in a name, as one: `eggroll` for "Egg Roll".
  final _pairs = <String>[];
  final _pairIds = <String, int>{};
  final _pairNamed = <bool>[];

  _Field? _field(List<String> words, int rank) {
    if (words.isEmpty) return null;
    if (words.length > _mostNameWords) words = words.sublist(0, _mostNameWords);
    final ids = Int32List(words.length);
    var content = 0;
    for (var i = 0; i < words.length; i++) {
      final id = ids[i] = _wordIds.putIfAbsent(words[i], () {
        _words.add(words[i]);
        _named.add(false);
        return _words.length - 1;
      });
      if (rank == 0) _named[id] = true;
      if (!_fillers.contains(words[i])) content |= 1 << i;
    }
    final pairs = Int32List(words.length - 1);
    for (var i = 0; i < pairs.length; i++) {
      final pair = words[i] + words[i + 1];
      final id = pairs[i] = _pairIds.putIfAbsent(pair, () {
        _pairs.add(pair);
        _pairNamed.add(false);
        return _pairs.length - 1;
      });
      if (rank == 0) _pairNamed[id] = true;
    }
    return _Field(ids, pairs, content, rank);
  }

  /// The dishes that [typed] finds, the best match first.
  List<T> find(String typed) {
    final plain = typed.trim().toLowerCase();
    if (plain.isEmpty) return const [];
    final all = wordsOf(plain);
    if (all.isEmpty) {
      // nothing but signs ("&"): the text as typed, as the search always did
      return [
        for (final e in _entries)
          if (e.number == plain || e.raw.any((name) => name.contains(plain))) e.dish,
      ];
    }
    var typedWords = all.where((w) => !_fillers.contains(w)).toList();
    if (typedWords.isEmpty) typedWords = all; // "with" alone is looked up as typed
    if (typedWords.length > _mostWords) typedWords = typedWords.sublist(0, _mostWords);
    final matcher = _Matcher(_Typed(this, typedWords));
    final enough = (typedWords.length + 1) ~/ 2;
    final numbered = <T>[];
    final hits = <_Hit<T>>[];
    for (final entry in _entries) {
      if (entry.number == plain) {
        numbered.add(entry.dish);
        continue;
      }
      _Hit<T>? best;
      for (final field in entry.fields) {
        if (!matcher.match(field)) continue;
        if (best == null) {
          best = _Hit(entry)..take(matcher, field.rank);
        } else if (matcher.beats(best, field.rank)) {
          best.take(matcher, field.rank);
        }
      }
      if (best != null && best.count >= enough) hits.add(best);
    }
    hits.sort(_Hit.compare);
    return [...numbered, for (final hit in hits) hit.entry.dish];
  }

  /// The words of a name or of what was typed: lower case, without accents or apostrophes, split wherever
  /// something that is neither a letter nor a digit stands, and between Chinese and Latin writing.
  static List<String> wordsOf(String text) {
    final words = <String>[];
    final word = StringBuffer();
    var kind = 0;
    void end() {
      if (word.isNotEmpty) words.add(word.toString());
      word.clear();
      kind = 0;
    }

    for (final rune in text.toLowerCase().runes) {
      // an apostrophe joins (Tso's is `tsos`), and an accent written apart from its letter is no letter
      if (rune == 0x27 || rune == 0x2019 || rune == 0x2018 || rune == 0x02BC || (rune >= 0x300 && rune <= 0x36F)) {
        continue;
      }
      final unaccented = _unaccented[rune];
      final next = unaccented != null ? 1 : _kindOf(rune);
      if (next == 0) {
        end();
        continue;
      }
      if (next != kind) end();
      kind = next;
      unaccented != null ? word.write(unaccented) : word.writeCharCode(rune);
    }
    end();
    return words;
  }

  /// 0 for what separates words, 1 for letters and digits, 2 for Chinese, Japanese and Korean writing.
  static int _kindOf(int rune) {
    if (rune < 0x80) return (rune >= 0x61 && rune <= 0x7A) || (rune >= 0x30 && rune <= 0x39) ? 1 : 0;
    if (rune < 0xC0 || rune == 0xD7 || rune == 0xF7) return 0; // Latin-1 signs
    if (rune < 0x2000) return 1; // letters of other alphabets
    if (rune < 0x2E80) return 0; // punctuation, arrows, symbols
    if (rune >= 0x3000 && rune <= 0x303F) return 0; // Chinese punctuation
    if (rune >= 0xFE30 && rune <= 0xFE6F) return 0;
    if (rune >= 0xFF00 && rune <= 0xFF0F) return 0; // full-width punctuation
    if (rune >= 0xFF1A && rune <= 0xFF20) return 0;
    if (rune >= 0xFF3B && rune <= 0xFF40) return 0;
    if (rune >= 0xFF5B && rune <= 0xFF65) return 0;
    return 2;
  }

  static bool _isAscii(String word) => word.codeUnits.every((c) => c < 0x80);

  static const _accented = {
    'a': 'àáâãäåāăąǎ',
    'c': 'çćĉċč',
    'd': 'ďđ',
    'e': 'èéêëēĕėęěẽ',
    'g': 'ĝğġģ',
    'i': 'ìíîïĩīĭįıǐ',
    'l': 'ĺļľł',
    'n': 'ñńņňǹ',
    'o': 'òóôõöøōŏőǒ',
    'r': 'ŕŗř',
    's': 'śŝşšș',
    't': 'ţťț',
    'u': 'ùúûüũūŭůűųǔǖǘǚǜ',
    'y': 'ýÿŷ',
    'z': 'źżž',
    'ae': 'æ',
    'oe': 'œ',
    'ss': 'ß',
  };

  static final _unaccented = {
    for (final e in _accented.entries)
      for (final rune in e.value.runes) rune: e.key,
  };
}

/// One dish, prepared.
class _Entry<T> {
  _Entry(this.dish, this.order, this.number, this.raw, this.fields);
  final T dish;
  final int order;
  final String? number;
  final List<String> raw; // its names in lower case, for a search of signs only
  final List<_Field> fields;
}

/// One name of a dish, as the numbers of its words.
class _Field {
  _Field(this.words, this.pairs, this.content, this.rank);
  final Int32List words;
  final Int32List pairs; // each word with the next, as one
  final int content; // a bit for each word that is not a filler
  final int rank; // 0 for a name on the button, 1 for the kitchen's label
}

/// How well one word typed meets one word of a name.
abstract final class _Met {
  static const no = 0;
  static const slip = 1; // a letter wrong, missing, too many or swapped
  static const inside = 2;
  static const start = 3;
  static const whole = 4;

  static int of(String typed, String word) {
    if (same(typed, word)) return whole;
    if (word.startsWith(typed)) return start;
    if (word.contains(typed)) return inside;
    return no;
  }

  /// The same word, one of it or several: roll and rolls, tomato and tomatoes, berry and berries.
  static bool same(String a, String b) {
    if (a == b) return true;
    if (a.length > b.length) (a, b) = (b, a);
    if (a.length < 3) return false;
    return switch (b.length - a.length) {
      1 => b == '${a}s',
      2 => b == '${a}es' || (a.endsWith('y') && b == '${a.substring(0, a.length - 1)}ies'),
      _ => false,
    };
  }

  /// Whether [typed] is [word], or (with [starts]) how [word] starts, but for at most [most] slips: a letter
  /// wrong, missing or too many, or two letters swapped.
  static bool near(String typed, String word, int most, {required bool starts}) {
    final m = typed.length;
    if (word.length < m - most) return false;
    final whole = word.length <= m + most;
    if (!whole && !starts) return false;
    final w = whole ? word.length : m + most;
    var before = List<int>.filled(w + 1, 0),
        row = List<int>.generate(w + 1, (j) => j),
        next = List<int>.filled(w + 1, 0);
    for (var i = 1; i <= m; i++) {
      next[0] = i;
      var least = i;
      for (var j = 1; j <= w; j++) {
        final differ = typed.codeUnitAt(i - 1) == word.codeUnitAt(j - 1) ? 0 : 1;
        var d = row[j - 1] + differ;
        if (row[j] + 1 < d) d = row[j] + 1;
        if (next[j - 1] + 1 < d) d = next[j - 1] + 1;
        if (i > 1 &&
            j > 1 &&
            typed.codeUnitAt(i - 1) == word.codeUnitAt(j - 2) &&
            typed.codeUnitAt(i - 2) == word.codeUnitAt(j - 1) &&
            before[j - 2] + 1 < d) {
          d = before[j - 2] + 1;
        }
        next[j] = d;
        if (d < least) least = d;
      }
      if (least > most) return false;
      (before, row, next) = (row, next, before);
    }
    if (whole && row[word.length] <= most) return true;
    if (!starts) return false;
    for (var j = m - most < 1 ? 1 : m - most; j <= w; j++) {
      if (row[j] <= most) return true;
    }
    return false;
  }
}

/// What was typed, compared once with every word the menu has.
class _Typed {
  _Typed(this.menu, this.words) : met = [], asPair = [], joined = [] {
    final n = words.length;
    final known = List<bool>.filled(n, false); // the word is in some name on a button
    for (var i = 0; i < n; i++) {
      final typed = words[i];
      final each = Uint8List(menu._words.length);
      for (var id = 0; id < each.length; id++) {
        final how = each[id] = _Met.of(typed, menu._words[id]);
        if (how >= _Met.inside && menu._named[id]) known[i] = true;
      }
      met.add(each);

      // one word typed for two of the name: `eggroll`, `lomein`
      Uint8List? pairs;
      for (var id = 0; id < menu._pairs.length; id++) {
        final pair = menu._pairs[id];
        final how = _Met.same(typed, pair) ? _Met.whole : (pair.startsWith(typed) ? _Met.start : _Met.no);
        if (how == _Met.no) continue;
        (pairs ??= Uint8List(menu._pairs.length))[id] = how;
        if (menu._pairNamed[id]) known[i] = true;
      }
      asPair.add(pairs);

      // two words typed for one of the name: `won ton`
      Uint8List? both;
      if (i + 1 < n) {
        final two = typed + words[i + 1];
        for (var id = 0; id < menu._words.length; id++) {
          final word = menu._words[id];
          if (!word.startsWith(two)) continue;
          (both ??= Uint8List(menu._words.length))[id] = word.length == two.length ? _Met.whole : _Met.start;
          if (menu._named[id]) known[i] = known[i + 1] = true;
        }
      }
      joined.add(both);
    }
    for (var i = 0; i < n; i++) {
      // In no name on the menu: a slip of the keyboard, then. Only for a word long enough to guess at, and
      // whose first letter is right.
      final typed = words[i];
      if (known[i] || typed.length < 4 || !typed.codeUnits.every((c) => c >= 0x61 && c <= 0x7A)) continue;
      final most = typed.length >= 8 ? 2 : 1;
      final each = met[i];
      for (var id = 0; id < each.length; id++) {
        final word = menu._words[id];
        if (each[id] != _Met.no || !menu._named[id] || word.length < 3) continue;
        if (word.codeUnitAt(0) != typed.codeUnitAt(0)) continue;
        if (_Met.near(typed, word, most, starts: typed.length >= 5)) each[id] = _Met.slip;
      }
    }
  }

  final MenuSearch<Object?> menu;
  final List<String> words;
  final List<Uint8List> met; // for each word typed, how it meets each word the menu has
  final List<Uint8List?> asPair; // for each word typed, how it meets each two words that follow one another
  final List<Uint8List?> joined; // for each word typed, how it and the next, as one, meet each word
}

/// One way a word typed can be met in a name: by which of the name's words, how well.
class _Way {
  _Way(this.bits, this.at, this.how, {this.two = false});
  final int bits; // the name's words it takes
  final int at; // the first of them
  final int how;
  final bool two; // it takes the next word typed as well
}

/// Pairs the words typed with the words of one name, each word of the name used once, and keeps the best
/// pairing: the most words typed, then the best met, then the earlier words typed.
class _Matcher {
  _Matcher(this.typed)
    : _ways = [for (var i = 0; i < typed.words.length; i++) <_Way>[]],
      _at = List<int>.filled(typed.words.length, -1);

  final _Typed typed;
  final List<List<_Way>> _ways;
  final List<int> _at;
  late _Field _field;
  var _tries = 0;

  // the best pairing found for the field
  var count = 0;
  var quality = 0;
  var earlier = 0;
  var extras = 0;
  var ordered = false;
  var first = 0;

  /// Whether any word typed is in the field; then [count] and the rest say how well.
  bool match(_Field field) {
    final n = typed.words.length;
    final words = field.words;
    var any = false;
    for (var i = 0; i < n; i++) {
      final ways = _ways[i]..clear();
      final met = typed.met[i];
      for (var j = 0; j < words.length; j++) {
        final how = met[words[j]];
        if (how != _Met.no) ways.add(_Way(1 << j, j, how));
      }
      final pairs = typed.asPair[i];
      if (pairs != null) {
        for (var j = 0; j < field.pairs.length; j++) {
          final how = pairs[field.pairs[j]];
          // a word typed that only starts the first of the two is that word's, not the pair's
          if (how != _Met.no && typed.words[i].length > typed.menu._words[words[j]].length) {
            ways.add(_Way(3 << j, j, how));
          }
        }
      }
      final both = typed.joined[i];
      if (both != null) {
        for (var j = 0; j < words.length; j++) {
          final how = both[words[j]];
          if (how != _Met.no) ways.add(_Way(1 << j, j, how, two: true));
        }
      }
      if (ways.isEmpty) continue;
      any = true;
      if (ways.length > 1) ways.sort((a, b) => a.how != b.how ? b.how - a.how : a.at - b.at);
    }
    if (!any) return false;
    _field = field;
    _tries = 0;
    count = 0;
    _pair(0, 0, 0, 0, 0, 0);
    return count > 0;
  }

  /// [count] words typed are met so far, [solid] of them by a whole word.
  void _pair(int i, int used, int count, int solid, int quality, int earlier) {
    final n = typed.words.length;
    if (_tries++ > MenuSearch._mostTries || count + n - i < this.count) return;
    if (i == n) {
      // short of every word, only whole words count
      final counted = count == n ? n : solid;
      if (counted > 0) _keep(used, counted, quality, earlier);
      return;
    }
    for (final way in _ways[i]) {
      if (used & way.bits != 0) continue;
      final firm = way.how == _Met.whole || way.how == _Met.slip ? 1 : 0;
      _at[i] = way.at;
      if (way.two) {
        _at[i + 1] = way.at;
        _pair(i + 2, used | way.bits, count + 2, solid + 2 * firm, quality + 2 * way.how, earlier | (3 << (n - i - 2)));
      } else {
        _pair(i + 1, used | way.bits, count + 1, solid + firm, quality + way.how, earlier | (1 << (n - i - 1)));
      }
    }
    _at[i] = -1;
    _pair(i + 1, used, count, solid, quality, earlier);
  }

  void _keep(int used, int count, int quality, int earlier) {
    var left = _field.content & ~used, extras = 0;
    while (left != 0) {
      left &= left - 1;
      extras++;
    }
    var ordered = true, first = -1, last = -1;
    for (final at in _at) {
      if (at < 0) continue;
      if (at < last) ordered = false;
      last = at;
      if (first < 0 || at < first) first = at;
    }
    final better = this.count == 0
        ? true
        : count != this.count
        ? count > this.count
        : quality != this.quality
        ? quality > this.quality
        : earlier != this.earlier
        ? earlier > this.earlier
        : extras != this.extras
        ? extras < this.extras
        : ordered != this.ordered
        ? ordered
        : first < this.first;
    if (!better) return;
    this.count = count;
    this.quality = quality;
    this.earlier = earlier;
    this.extras = extras;
    this.ordered = ordered;
    this.first = first;
  }

  /// Whether what was just matched, in a field of [rank], is better than [hit].
  bool beats(_Hit<Object?> hit, int rank) => _Hit.order(count, quality, rank, earlier, extras, ordered, first, hit) < 0;
}

/// How well one dish was found, by its best name.
class _Hit<T> {
  _Hit(this.entry);
  final _Entry<T> entry;
  var count = 0;
  var quality = 0;
  var rank = 0;
  var earlier = 0;
  var extras = 0;
  var ordered = false;
  var first = 0;

  void take(_Matcher m, int rank) {
    count = m.count;
    quality = m.quality;
    this.rank = rank;
    earlier = m.earlier;
    extras = m.extras;
    ordered = m.ordered;
    first = m.first;
  }

  /// Negative when the first is the better match: see [MenuSearch] for the order.
  static int order(
    int count,
    int quality,
    int rank,
    int earlier,
    int extras,
    bool ordered,
    int first,
    _Hit<Object?> b,
  ) {
    if (count != b.count) return b.count - count;
    if (rank != b.rank) return rank - b.rank;
    if (quality != b.quality) return b.quality - quality;
    if (earlier != b.earlier) return b.earlier - earlier;
    if (extras != b.extras) return extras - b.extras;
    if (ordered != b.ordered) return ordered ? -1 : 1;
    return first - b.first;
  }

  static int compare(_Hit<Object?> a, _Hit<Object?> b) {
    final by = order(a.count, a.quality, a.rank, a.earlier, a.extras, a.ordered, a.first, b);
    return by != 0 ? by : a.entry.order - b.entry.order;
  }
}
