/// A delivery's address in the parts a form asks for (docs/delivery.md, "The address in its parts"): the
/// number and the street, the apartment or unit, the town, the state and the ZIP.
///
/// An order carries its address as one line, as it always did, and everything that reads an order reads
/// that line: the bill, the bag labels, the driver's list, the map service that says how far it is. The
/// parts are that line written one way, [AddressParts.line] ("12 Elm St #3B, Winchester, MA 01890"), and
/// read back off it, [AddressParts.parse]. A line somebody typed whole before there were parts, or that a
/// website sent, is read as far as it can be told apart and otherwise stands in the street's box as it is.
library;

import 'takeout.dart';

/// The states by their two letters, as an address names them, and by their names in small letters.
const _states = {
  'alabama': 'AL',
  'alaska': 'AK',
  'arizona': 'AZ',
  'arkansas': 'AR',
  'california': 'CA',
  'colorado': 'CO',
  'connecticut': 'CT',
  'delaware': 'DE',
  'district of columbia': 'DC',
  'florida': 'FL',
  'georgia': 'GA',
  'hawaii': 'HI',
  'idaho': 'ID',
  'illinois': 'IL',
  'indiana': 'IN',
  'iowa': 'IA',
  'kansas': 'KS',
  'kentucky': 'KY',
  'louisiana': 'LA',
  'maine': 'ME',
  'maryland': 'MD',
  'massachusetts': 'MA',
  'michigan': 'MI',
  'minnesota': 'MN',
  'mississippi': 'MS',
  'missouri': 'MO',
  'montana': 'MT',
  'nebraska': 'NE',
  'nevada': 'NV',
  'new hampshire': 'NH',
  'new jersey': 'NJ',
  'new mexico': 'NM',
  'new york': 'NY',
  'north carolina': 'NC',
  'north dakota': 'ND',
  'ohio': 'OH',
  'oklahoma': 'OK',
  'oregon': 'OR',
  'pennsylvania': 'PA',
  'rhode island': 'RI',
  'south carolina': 'SC',
  'south dakota': 'SD',
  'tennessee': 'TN',
  'texas': 'TX',
  'utah': 'UT',
  'vermont': 'VT',
  'virginia': 'VA',
  'washington': 'WA',
  'west virginia': 'WV',
  'wisconsin': 'WI',
  'wyoming': 'WY',
};

final _codes = _states.values.toSet();

/// A state's two letters for what an address says of it: its letters in any case, or with [names] its name
/// spelled out. Null for what is neither.
String? _stateOf(String said, {bool names = false}) {
  final plain = said.trim().replaceAll('.', '');
  final code = plain.toUpperCase();
  if (_codes.contains(code)) return code;
  return names ? _states[plain.toLowerCase()] : null;
}

const _zipShape = r'\d{5}(?:-\d{4})?';
final _zipAtEnd = RegExp('(?:^|\\s)($_zipShape)\$');

/// The words an apartment or a unit is named with: "Apt 3B", "Unit 12", "Ste 200", "Fl 2".
const _unitWords = 'apt|apartment|unit|suite|ste|rm|room|fl|floor|bldg|building|lot|ph|penthouse';

/// A part that names a unit by one of those words, or by a number sign ("Florence" is a town).
final _unitNamed = RegExp('^(?:(?:$_unitWords)(?![A-Za-z])|#)', caseSensitive: false);

/// A unit that is its number or letter alone: "3", "3B", "B", "12-A".
final _unitAlone = RegExp(r'^(?=[A-Za-z0-9-]*\d|[A-Za-z]$)[A-Za-z0-9-]+$');

/// A unit at the end of a street's line: "12 Elm St Apt 3B", "12 Elm St #3B". What follows the word is a
/// number or one letter: "12 Unit Rd" is a street.
final _unitAtEnd = RegExp(
  '^(.*\\S)\\s+((?:$_unitWords)(?![A-Za-z])\\.?\\s*#?\\s*(?=[A-Za-z0-9-]*\\d|[A-Za-z]\$)[A-Za-z0-9-]+'
  '|#\\s*[A-Za-z0-9-]+)\$',
  caseSensitive: false,
);

/// Whether a part between two commas is a unit: named by its word, or its number or letter alone.
bool _unitLike(String part) => _unitNamed.hasMatch(part) || _unitAlone.hasMatch(part);

/// The countries an address here may end with: every address is in this one.
const _countries = {'usa', 'us', 'united states', 'united states of america'};

class AddressParts {
  const AddressParts({this.street = '', this.unit = '', this.city = '', this.state = '', this.zip = ''});

  /// The parts as the hub says a map service told them (`parts` of a line of the list); null for what is
  /// none, and for parts that name no street.
  static AddressParts? of(Object? json) {
    if (json is! Map) return null;
    String part(String name) => json[name] is String ? oneLine(json[name]) : '';
    final state = _stateOf(part('state')) ?? '';
    final zip = part('zip');
    final parts = AddressParts(
      street: part('street'),
      unit: _bare(part('unit')),
      city: part('city'),
      state: state,
      zip: RegExp('^$_zipShape\$').hasMatch(zip) ? zip : '',
    );
    return parts.street.isEmpty ? null : parts;
  }

  /// An address that is one line, read into its parts as far as they can be told apart:
  ///
  /// - The parts are what stands between its commas. The last one is the state and the ZIP ("MA 01890",
  ///   "MA", "01890", "Massachusetts 01890"), or the town with them ("Winchester MA 01890"); the one before
  ///   it the town; the first one the street. A country at the very end is left off.
  /// - A unit is told apart where it is named by its word or a number sign: at the end of the street
  ///   ("12 Elm St Apt 3B", "12 Elm St #3B") or between two commas ("12 Elm St, Apt 3B, Winchester").
  /// - A line with no comma is a street and nothing else: "12 Elm Ct" does not end with Connecticut.
  ///
  /// What cannot be told apart stays in the street, in the words it came in, so nothing of a line is ever
  /// lost: [line] of what was read says the same address again.
  factory AddressParts.parse(String address) {
    final text = oneLine(address);
    if (text.isEmpty) return const AddressParts();
    final parts = [
      for (final part in text.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (parts.isEmpty) return const AddressParts();
    if (parts.length > 1 && _countries.contains(parts.last.toLowerCase().replaceAll('.', ''))) parts.removeLast();
    var state = '', zip = '', city = '', unit = '';
    if (parts.length > 1) {
      var last = parts.last;
      final zipped = _zipAtEnd.firstMatch(last);
      if (zipped != null) {
        zip = zipped.group(1)!;
        last = last.substring(0, zipped.start).trim();
      }
      if (last.isEmpty) {
        parts.removeLast(); // the ZIP by itself: "…, MA, 01890"
        final before = parts.length > 1 ? _stateOf(parts.last, names: true) : null;
        if (before != null) {
          state = before;
          parts.removeLast();
        }
      } else if (_stateOf(last, names: zip.isNotEmpty || parts.length > 2) case final code?) {
        // a state's name alone after one comma could as well be a town: "12 W 4th St, New York"
        state = code;
        parts.removeLast();
      } else {
        // the town and the state with no comma between them: "Winchester MA 01890"
        final words = last.split(' ');
        final code = words.length > 1 ? _stateOf(words.last) : null;
        if (code != null) {
          state = code;
          parts[parts.length - 1] = words.sublist(0, words.length - 1).join(' ');
        } else if (zip.isNotEmpty) {
          final name = _states.keys.where((name) => last.toLowerCase().endsWith(' $name')).firstOrNull;
          if (name != null) {
            state = _states[name]!;
            last = last.substring(0, last.length - name.length).trim();
          }
          parts[parts.length - 1] = last;
        }
      }
    }
    // what is left: the street, perhaps a unit between two commas, and the town
    if (parts.length == 2) {
      if (_unitLike(parts.last)) {
        unit = parts.removeLast(); // "12 Elm St, Apt 3B": no town was said
      } else {
        city = parts.removeLast();
      }
    } else if (parts.length > 2) {
      if (_unitNamed.hasMatch(parts.last)) {
        unit = parts.removeLast(); // "12 Elm St, Winchester, Apt 3B": the unit said last
        city = parts.removeLast();
      } else {
        city = parts.removeLast();
        if (parts.length == 2 && _unitLike(parts.last)) unit = parts.removeLast();
      }
    }
    var street = parts.join(', '); // anything else between commas stays with the street, as it was written
    if (unit.isEmpty) {
      final ends = _unitAtEnd.firstMatch(street);
      if (ends != null) {
        street = ends.group(1)!;
        unit = ends.group(2)!;
      }
    }
    return AddressParts(street: street, unit: _bare(unit), city: city, state: state, zip: zip);
  }

  /// A unit without the number sign before it: the box holds "3B", and [line] writes "#3B".
  static String _bare(String unit) {
    final plain = unit.trim();
    return plain.startsWith('#') ? plain.substring(1).trim() : plain;
  }

  /// The state an address names, for the state a form starts on (the restaurant's own): as [parse] reads
  /// it, or the two letters before a ZIP at the end of a line with no commas ("1 Main St Winchester MA
  /// 01890"). Empty where it names none.
  static String stateOf(String address) {
    final read = AddressParts.parse(address).state;
    if (read.isNotEmpty) return read;
    final ends = RegExp('\\b([A-Za-z]{2})\\s+$_zipShape\$').firstMatch(oneLine(address));
    return ends == null ? '' : _stateOf(ends.group(1)!) ?? '';
  }

  final String street;

  /// The apartment or unit, as it is said: "Apt 3B", "Ste 200", or the number alone, "3B".
  final String unit;
  final String city;

  /// The state by its two letters.
  final String state;
  final String zip;

  /// Nothing is in any part.
  bool get isEmpty => street.isEmpty && unit.isEmpty && city.isEmpty && state.isEmpty && zip.isEmpty;

  /// The unit as the line says it: by its word where it has one ("Apt 3B"), and with a number sign where it
  /// is its number or letter alone ("#3B"). Anything else as it was typed ("2nd floor", "rear").
  String get unitWords => _unitAlone.hasMatch(unit) && !_unitNamed.hasMatch(unit) ? '#$unit' : unit;

  /// The address on one line, as an order carries it: "12 Elm St #3B, Winchester, MA 01890". A part that is
  /// empty is left out with its comma. A state by itself is no address: a form starts with the
  /// restaurant's own state in its box, and that is nowhere to go yet.
  String get line {
    final first = [street, unitWords].where((part) => part.isNotEmpty).join(' ');
    if (first.isEmpty && city.isEmpty && zip.isEmpty) return '';
    final last = [state, zip].where((part) => part.isNotEmpty).join(' ');
    return [first, city, last].where((part) => part.isNotEmpty).join(', ');
  }

  AddressParts copyWith({String? street, String? unit, String? city, String? state, String? zip}) => AddressParts(
    street: street ?? this.street,
    unit: unit ?? this.unit,
    city: city ?? this.city,
    state: state ?? this.state,
    zip: zip ?? this.zip,
  );

  @override
  bool operator ==(Object other) =>
      other is AddressParts &&
      other.street == street &&
      other.unit == unit &&
      other.city == city &&
      other.state == state &&
      other.zip == zip;

  @override
  int get hashCode => Object.hash(street, unit, city, state, zip);

  @override
  String toString() => 'AddressParts($street | $unit | $city | $state | $zip)';
}
