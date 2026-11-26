import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/address_parts.dart';

/// A delivery's address in its parts (docs/delivery.md, "The address in its parts"): an order carries one
/// line, and a form shows it in five boxes. These tests are about reading a line into the boxes and writing
/// the boxes as a line. The boxes themselves are test/address_fields_test.dart.

AddressParts read(String line) => AddressParts.parse(line);

AddressParts parts(String street, [String unit = '', String city = '', String state = '', String zip = '']) =>
    AddressParts(street: street, unit: unit, city: city, state: state, zip: zip);

void main() {
  group('the boxes as one line', () {
    test('the street and its unit, the town, the state and the ZIP', () {
      expect(parts('12 Elm St', '', 'Winchester', 'MA', '01890').line, '12 Elm St, Winchester, MA 01890');
      expect(parts('12 Elm St', 'Apt 3B', 'Winchester', 'MA', '01890').line, '12 Elm St Apt 3B, Winchester, MA 01890');
      // a unit that is its number alone is written with a number sign; one in words as it was typed
      expect(parts('12 Elm St', '3B', 'Winchester', 'MA').line, '12 Elm St #3B, Winchester, MA');
      expect(parts('12 Elm St', 'B').line, '12 Elm St #B');
      expect(parts('12 Elm St', 'Ste 200').line, '12 Elm St Ste 200');
      expect(parts('12 Elm St', 'Apt3B').line, '12 Elm St Apt3B');
      expect(parts('12 Elm St', '2nd floor', 'Woburn').line, '12 Elm St 2nd floor, Woburn');
      expect(parts('12 Elm St', '#3B').line, '12 Elm St #3B');
    });

    test('a box left empty is left out with its comma', () {
      expect(parts('12 Elm St').line, '12 Elm St');
      expect(parts('12 Elm St', '', 'Winchester').line, '12 Elm St, Winchester');
      expect(parts('12 Elm St', '', '', 'MA').line, '12 Elm St, MA');
      expect(parts('12 Elm St', '', 'Winchester', '', '01890').line, '12 Elm St, Winchester, 01890');
      expect(parts('', '', 'Winchester', 'MA').line, 'Winchester, MA');
      expect(parts('', '', '', '', '01890').line, '01890');
    });

    test('a state by itself is no address: a form starts with the restaurant\'s own in its box', () {
      expect(parts('', '', '', 'MA').line, '');
      expect(const AddressParts().line, '');
      expect(const AddressParts().isEmpty, isTrue);
      expect(parts('', '', '', 'MA').isEmpty, isFalse);
    });
  });

  group('one line read into the boxes', () {
    test('the street, the town, the state and the ZIP stand between its commas', () {
      expect(read('12 Elm St, Winchester, MA 01890'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      expect(read('12 Elm St, Winchester, MA'), parts('12 Elm St', '', 'Winchester', 'MA'));
      expect(read('12 Elm St, Winchester'), parts('12 Elm St', '', 'Winchester'));
      expect(read('12 Elm St, MA'), parts('12 Elm St', '', '', 'MA'));
      expect(read('12 Elm St, Winchester, 01890'), parts('12 Elm St', '', 'Winchester', '', '01890'));
      expect(read('12 Elm St, 01890-1234'), parts('12 Elm St', '', '', '', '01890-1234'));
      expect(read('12 Elm St, Winchester, MA, 01890'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      // any case, any spaces, a comma too many
      expect(read('  12  elm st ,winchester ,ma  01890 ,'), parts('12 elm st', '', 'winchester', 'MA', '01890'));
    });

    test('the town and the state with no comma between them, and a state spelled out', () {
      expect(read('12 Elm St, Winchester MA 01890'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      expect(read('12 Elm St, Winchester Ma'), parts('12 Elm St', '', 'Winchester', 'MA'));
      expect(read('12 Elm St, North Reading MA'), parts('12 Elm St', '', 'North Reading', 'MA'));
      // as Mapbox writes it, and a state of two words
      expect(read('12 Elm St, Winchester, Massachusetts 01890'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      expect(read('12 Elm St, Winchester Massachusetts 01890'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      expect(read('9 Main St, Salem, New Hampshire 03079'), parts('9 Main St', '', 'Salem', 'NH', '03079'));
      expect(read('9 Main St, Salem New Hampshire 03079'), parts('9 Main St', '', 'Salem', 'NH', '03079'));
      expect(read('12 Elm St, Winchester, Massachusetts'), parts('12 Elm St', '', 'Winchester', 'MA'));
      // a state's name alone after one comma could as well be a town
      expect(read('12 W 4th St, New York'), parts('12 W 4th St', '', 'New York'));
      expect(read('12 W 4th St, New York, NY 10012'), parts('12 W 4th St', '', 'New York', 'NY', '10012'));
    });

    test('a country at the end is left off', () {
      for (final country in ['USA', 'United States', 'US', 'U.S.A.']) {
        expect(read('12 Elm St, Winchester, MA 01890, $country'), parts('12 Elm St', '', 'Winchester', 'MA', '01890'));
      }
      expect(read('12 Elm St, Winchester, MA, USA'), parts('12 Elm St', '', 'Winchester', 'MA'));
    });

    test('a unit is told apart where it is named', () {
      expect(read('12 Elm St Apt 3B, Winchester, MA 01890'), parts('12 Elm St', 'Apt 3B', 'Winchester', 'MA', '01890'));
      expect(read('12 Elm St #3B, Winchester, MA'), parts('12 Elm St', '3B', 'Winchester', 'MA'));
      expect(read('12 Elm St # 3, Winchester'), parts('12 Elm St', '3', 'Winchester'));
      expect(read('12 Elm St, Apt 3B, Winchester, MA'), parts('12 Elm St', 'Apt 3B', 'Winchester', 'MA'));
      expect(read('12 Elm St, #3B, Winchester'), parts('12 Elm St', '3B', 'Winchester'));
      expect(read('12 Elm St, 3B, Winchester'), parts('12 Elm St', '3B', 'Winchester'));
      expect(read('12 Elm St, Apt 3B'), parts('12 Elm St', 'Apt 3B'));
      expect(read('12 Elm St, Winchester, Apt 3B'), parts('12 Elm St', 'Apt 3B', 'Winchester'));
      expect(read('4 Oak Rd Apt 12, Woburn'), parts('4 Oak Rd', 'Apt 12', 'Woburn'));
      expect(read('4 Oak Rd unit B'), parts('4 Oak Rd', 'unit B'));
      expect(read('100 Main St Ste. 200, Woburn'), parts('100 Main St', 'Ste. 200', 'Woburn'));
      expect(read('100 Main St Floor 2'), parts('100 Main St', 'Floor 2'));
      expect(read('100 Main St Apt3B'), parts('100 Main St', 'Apt3B'));
    });

    test('a street that only looks like one keeps its words', () {
      expect(read('12 Unit Rd, Woburn'), parts('12 Unit Rd', '', 'Woburn'));
      expect(read('12 Floor St'), parts('12 Floor St'));
      expect(read('12 Phelps St, Florence, MA'), parts('12 Phelps St', '', 'Florence', 'MA'));
      expect(read('12 Elm St 2nd Floor, Woburn'), parts('12 Elm St 2nd Floor', '', 'Woburn'));
      // what stands between commas and is no unit stays with the street, as it was written
      expect(read('12 Elm St, side door, Winchester, MA'), parts('12 Elm St, side door', '', 'Winchester', 'MA'));
    });

    test('a line with no comma is a street and nothing else', () {
      expect(read('12 Elm St'), parts('12 Elm St'));
      expect(read('12 Elm Ct'), parts('12 Elm Ct')); // a court, not Connecticut
      expect(read('12 Elm St Winchester MA 01890'), parts('12 Elm St Winchester MA 01890'));
      expect(read('Winchester'), parts('Winchester'));
      expect(read('01890'), parts('01890'));
      expect(read(''), const AddressParts());
      expect(read('  ,  , '), const AddressParts());
    });

    test('what was read says the same address again, and reads the same again', () {
      const written = [
        '12 Elm St, Winchester, MA 01890',
        '12 Elm St, Winchester, MA',
        '12 Elm St, Winchester',
        '12 Elm St',
        '12 Elm St #3B, Winchester, MA 01890',
        '12 Elm St Apt 3B, Winchester, MA 01890',
        '4 Oak Rd Apt 12, Woburn',
        '12 Elm St, side door, Winchester, MA',
        '12 Elm St Winchester MA 01890',
        '12 Elm St, 01890',
        '120 Elmwood Ave, Woburn',
        '5 Broadway, New York, NY 10004',
      ];
      for (final line in written) {
        expect(read(line).line, line, reason: line);
      }
      // a line written another way says the same address in the one way, and that reads the same
      const loose = [
        '12 elm st,winchester ,ma 01890',
        '12 Elm St, Apt 3B, Winchester, Massachusetts 01890, USA',
        '12 Elm St, Winchester MA',
        'Winchester, 12 Elm St',
        '12 Elm St, Winchester, Apt 3B',
        '100 Main St Ste. 200, Woburn',
        '12 W 4th St, New York',
      ];
      for (final line in [...written, ...loose]) {
        final once = read(line);
        expect(read(once.line), once, reason: line);
      }
    });
  });

  group('what the hub says of a line\'s parts', () {
    test('each part on one line; a state by its two letters and a ZIP that is one', () {
      expect(
        AddressParts.of(const {
          'street': ' 12  Elm St ',
          'unit': '#3B',
          'city': 'Winchester',
          'state': 'ma',
          'zip': '01890',
        }),
        parts('12 Elm St', '3B', 'Winchester', 'MA', '01890'),
      );
      expect(
        AddressParts.of(const {'street': '12 Elm St', 'city': 7, 'state': 'Mass', 'zip': '1890'}),
        parts('12 Elm St'),
      );
      expect(AddressParts.of(const {'street': '12 Elm St'}), parts('12 Elm St'));
    });

    test('parts that name no street are none', () {
      for (final odd in <Object?>[
        null,
        'parts',
        const <String, dynamic>{},
        const {'city': 'Winchester'},
        const {'street': ' '},
      ]) {
        expect(AddressParts.of(odd), isNull, reason: '$odd');
      }
    });
  });

  test('the state a form starts on is the one the restaurant\'s own address names', () {
    expect(AddressParts.stateOf('1 Restaurant Row, Winchester, MA'), 'MA');
    expect(AddressParts.stateOf('1 Restaurant Row, Winchester, MA 01890'), 'MA');
    expect(AddressParts.stateOf('1 Restaurant Row Winchester ma 01890'), 'MA');
    expect(AddressParts.stateOf('1 Restaurant Row, Winchester'), '');
    expect(AddressParts.stateOf('1 Elm Ct'), '');
    expect(AddressParts.stateOf(''), '');
  });
}
