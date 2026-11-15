import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/menu_search.dart';

/// A dish as the search sees it: `number|name|second name|kitchen label`, the last three optional.
typedef Dish = ({String? number, String name, String? second, String? kitchen});

Dish dish(String line) {
  final parts = line.split('|');
  String? at(int i) => parts.length > i && parts[i].isNotEmpty ? parts[i] : null;
  return (number: at(0), name: parts[1], second: at(2), kitchen: at(3));
}

/// Names as the restaurant's menu has them, in the menu's own order.
final menu = [
  'A1|Egg Roll|春卷',
  'A2|Spring Rolls (2)',
  'A4|Chicken Wings|雞翼',
  'A5|Boneless Spare Ribs',
  'A7|Pan Fried Dumplings (6)|鍋貼',
  'A9|Crab Rangoons (6)',
  '805|Wonton Soup|雲吞湯',
  '806|Hot & Sour Soup|酸辣湯',
  'F1|Pork Fried Rice',
  'F2|Chicken Fried Rice',
  'F3|Beef Fried Rice',
  'F7|House Special Fried Rice',
  'N1|Chicken Lo Mein',
  'N2|Beef Lo Mein',
  'N5|Beef Chow Fun',
  'C1|General Tso\'s Chicken|左宗雞|左宗雞 GEN TSO CHKN r',
  'C2|Sweet & Sour Chicken|甜酸雞',
  'C3|Chicken with Broccoli|芥蘭雞|芥蘭雞 CHKN/ BROCCOLI r',
  'C4|Sliced Chicken with Broccoli',
  'C5|Steamed Chicken with Broccoli',
  'C6|Kung Pao Chicken',
  'C9|Chicken with Cashew Nuts|腰果雞|腰果雞 CHKN/ CASHEW NUTS r',
  'B1|Beef with Snow Peas',
  'B2|Beef with Broccoli|芥蘭牛|芥蘭牛 BEEF/ BROCCOLI r',
  'B3|Beef with Mushrooms',
  'B4|Hunan Beef',
  'B5|Mongolian Beef (House)',
  'B6|Pepper Steak|青椒牛|青椒牛 PEPPER BEEF r',
  'P1|Sliced Pork with Broccoli',
  'S1|Shrimp with Broccoli|芥蘭蝦|芥蘭蝦 SHMP/ BROCCOLI r',
  'S2|Shrimp with Cashew Nuts|腰果蝦|腰果蝦 SHMP CASHEW r',
  'S3|Shrimp in Lobster Sauce',
  'V1|Steamed Broccoli',
  'V2|Broccoli with Garlic Sauce',
  'V3|Sautéed String Beans',
  'V4|Sautéed Spinach',
  'M1|Moo Shu Pork',
  'W1|Beefeater',
  'W2|Patrón Silver',
  'W3|Mai Tai',
  'W4|Strawberry Daiquiri',
  'W5|Piña Colada',
  'W6|Tito\'s',
  'W7|Sex on the Beach',
  'W8|7 Up',
  'W9|Root Beer',
  'J1|Maguro||sa:MAGURO',
  'J2|Sake||su:SAKE',
  'K1|Salmon Roll||sr:SALMON ROLL s',
].map(dish).toList();

MenuSearch<Dish> searchOf(List<Dish> dishes) =>
    MenuSearch<Dish>(dishes, (d) => SearchText(number: d.number, names: [d.name, d.second], labels: [d.kitchen]));

final search = searchOf(menu);

List<String> find(String typed) => [for (final d in search.find(typed)) d.name];

void main() {
  test('Mike’s example: "beef broccoli" finds Beef with Broccoli first, then the other beef dishes', () {
    final found = find('beef broccoli');
    expect(found.first, 'Beef with Broccoli');
    // then what has one of the two words as a whole word: the first word typed before the second
    final beef = found.indexOf('Hunan Beef'), broccoli = found.indexOf('Chicken with Broccoli');
    expect(beef, greaterThan(0));
    expect(broccoli, greaterThan(beef));
    expect(found, isNot(contains('Egg Roll')));
    // with one word of the two, only a whole word counts: "Beefeater" merely starts with one
    expect(found, isNot(contains('Beefeater')));
    expect(find('beef'), contains('Beefeater'));
  });

  test('the words can come in any order, and "with", "and", "&" and the like do not count', () {
    expect(find('broccoli beef').first, 'Beef with Broccoli');
    expect(find('beef with broccoli').first, 'Beef with Broccoli');
    expect(find('beef and broccoli').first, 'Beef with Broccoli');
    expect(find('beef & broccoli').first, 'Beef with Broccoli');
    expect(find('sweet sour chicken').first, 'Sweet & Sour Chicken');
    expect(find('sweet and sour chicken').first, 'Sweet & Sour Chicken');
    expect(find('sex beach').first, 'Sex on the Beach');
    // a filler word alone is still looked up as typed
    expect(find('with').first, 'Chicken with Broccoli');
    expect(find('with'), isNot(contains('Hunan Beef')));
  });

  test('among dishes with every word, the name with the least beside them comes first', () {
    expect(find('chicken broccoli').take(3), [
      'Chicken with Broccoli',
      'Sliced Chicken with Broccoli',
      'Steamed Chicken with Broccoli',
    ]);
    expect(find('fried rice').take(4), [
      'Pork Fried Rice',
      'Chicken Fried Rice',
      'Beef Fried Rice',
      'House Special Fried Rice',
    ]);
    expect(find('broccoli').first, 'Steamed Broccoli');
  });

  test('a whole word comes before the start of a word, and that before letters inside a word', () {
    final beef = find('beef');
    expect(beef.indexOf('Beefeater'), greaterThan(beef.indexOf('Mongolian Beef (House)')));
    expect(beef.length, greaterThan(5));
    final roll = find('rol');
    expect(roll, ['Egg Roll', 'Salmon Roll', 'Spring Rolls (2)']);
    final berry = find('berry');
    expect(berry, ['Strawberry Daiquiri']);
    // what is being typed finds dishes from its first letters on
    expect(find('chick broc').first, 'Chicken with Broccoli');
    expect(find('gen tso').first, 'General Tso\'s Chicken');
  });

  test('plurals: one or several finds the same dish', () {
    expect(find('egg rolls').first, 'Egg Roll');
    expect(find('spring roll').first, 'Spring Rolls (2)');
    expect(find('dumpling').first, 'Pan Fried Dumplings (6)');
    expect(find('chicken wing').first, 'Chicken Wings');
    expect(find('snow pea').first, 'Beef with Snow Peas');
    expect(find('string bean').first, 'Sautéed String Beans');
    expect(find('general tso').first, 'General Tso\'s Chicken');
    expect(find('titos'), ['Tito\'s']);
  });

  test('small typos: a word found nowhere on the menu is taken for the closest words', () {
    expect(find('beef brocoli').first, 'Beef with Broccoli');
    expect(find('chiken wings').first, 'Chicken Wings');
    expect(find('chikcen wings').first, 'Chicken Wings');
    expect(find('lo mien').take(2), ['Chicken Lo Mein', 'Beef Lo Mein']);
    expect(find('mongolain beef').first, 'Mongolian Beef (House)');
    expect(find('brocol').first, 'Steamed Broccoli', reason: 'a typo in a word still being typed');
    // a word the menu has is never taken for a typo of another: beef is not beer
    expect(find('beef'), isNot(contains('Root Beer')));
    expect(find('beer'), ['Root Beer']);
    // too short to guess at, and the first letter has to be right
    expect(find('bef'), isEmpty);
    expect(find('reef'), isEmpty);
  });

  test('accents and apostrophes need not be typed', () {
    expect(find('patron'), ['Patrón Silver']);
    expect(find('pina colada'), ['Piña Colada']);
    expect(find('sauteed'), ['Sautéed Spinach', 'Sautéed String Beans']);
    expect(find('PATRÓN'), ['Patrón Silver']);
    expect(find('general tso\'s').first, 'General Tso\'s Chicken');
    expect(find('general tso’s').first, 'General Tso\'s Chicken');
  });

  test('two words typed as one, and one word typed as two', () {
    expect(find('eggroll'), ['Egg Roll']);
    expect(find('lomein'), ['Chicken Lo Mein', 'Beef Lo Mein']);
    expect(find('beef lomein').first, 'Beef Lo Mein');
    expect(find('maitai'), ['Mai Tai']);
    expect(find('mooshu').first, 'Moo Shu Pork');
    expect(find('won ton').first, 'Wonton Soup');
    expect(find('won ton soup').first, 'Wonton Soup');
    expect(find('straw berry').first, 'Strawberry Daiquiri');
  });

  test('when no dish has every word, the dishes with the most of them come first', () {
    expect(find('general tso shrimp').first, 'General Tso\'s Chicken');
    expect(find('kung pow chicken').first, 'Kung Pao Chicken');
    // one word of three is not enough: the fifteen other chicken dishes stay out
    expect(find('kung pow chicken'), isNot(contains('Chicken Wings')));
    expect(find('zzz'), isEmpty);
    expect(find('zzz qqq'), isEmpty);
    // short of every word, only whole words count: no spinach for a piña colada, no lobster for a lo mein
    expect(find('pina'), ['Piña Colada', 'Sautéed Spinach']);
    expect(find('pina colada'), ['Piña Colada']);
    expect(find('pina daiquiri'), ['Piña Colada', 'Strawberry Daiquiri']);
    expect(find('lo'), contains('Shrimp in Lobster Sauce'));
    expect(find('lo mein'), ['Chicken Lo Mein', 'Beef Lo Mein']);
    // while the second word is being typed, the dishes with the first stay
    expect(find('beef b').take(2), ['Beef with Broccoli', 'Beef with Mushrooms']);
    expect(find('beef b'), contains('Hunan Beef'));
    expect(find('beef b'), isNot(contains('Boneless Spare Ribs')));
  });

  test('a dish’s number, typed whole, comes first', () {
    expect(find('805'), ['Wonton Soup']);
    expect(find('b2'), ['Beef with Broccoli']);
    expect(find('B2'), ['Beef with Broccoli']);
    expect(find('7').first, '7 Up');
    expect(find('80'), isEmpty, reason: 'half a number is no number');
  });

  test('the Chinese name and the kitchen’s label find a dish too, after the names on the buttons', () {
    expect(find('芥蘭牛'), ['Beef with Broccoli']);
    expect(find('芥蘭').take(1), ['Chicken with Broccoli']);
    expect(find('芥蘭').length, 3);
    expect(find('牛'), ['Beef with Broccoli', 'Pepper Steak']);
    expect(find('shmp cashew').first, 'Shrimp with Cashew Nuts');
    expect(
      find('chkn'),
      unorderedEquals(['General Tso\'s Chicken', 'Chicken with Broccoli', 'Chicken with Cashew Nuts']),
    );
    // "Pepper Steak" is beef to the kitchen: found, after whatever a name on a button found
    final beef = find('beef');
    expect(beef.last, 'Pepper Steak');
    expect(beef[beef.length - 2], 'Beefeater');
    // the kitchen's marks are not words: the single letters (r for rice), what stands before a colon
    expect(find('r').every((name) => name.toLowerCase().contains('r')), isTrue);
    expect(find('sa').first, 'Sake');
    expect(find('sa'), isNot(contains('Maguro')));
    expect(find('maguro'), ['Maguro']);
  });

  test('whatever the plain text match found is still found', () {
    for (final typed in ['f with b', 'oll', 'tso\'s ch', '(6)', 'beef w', 'n fried d', 'lobster sauce', 'ry da', '蘭']) {
      final old = [
        for (final d in menu)
          if (d.name.toLowerCase().contains(typed) || (d.second ?? '').toLowerCase().contains(typed)) d.name,
      ];
      expect(old, isNotEmpty, reason: typed);
      expect(find(typed), containsAll(old), reason: typed);
    }
    expect(find('&'), ['Hot & Sour Soup', 'Sweet & Sour Chicken'], reason: 'no word at all: the text as typed');
    expect(find(''), isEmpty);
    expect(find('   '), isEmpty);
  });

  test('dishes that match alike keep the menu’s order', () {
    expect(find('lo mein'), ['Chicken Lo Mein', 'Beef Lo Mein']);
    final twice = searchOf([dish('L8|Beef with Broccoli'), dish('88|Beef with Broccoli')]);
    expect([for (final d in twice.find('beef broccoli')) d.number], ['L8', '88']);
  });

  test('a long menu is searched in well under a frame', () {
    final big = searchOf([
      for (var i = 0; i < 15; i++)
        for (final d in menu) (number: '${d.number}$i', name: d.name, second: d.second, kitchen: d.kitchen),
    ]);
    final watch = Stopwatch()..start();
    const typed = [
      'b',
      'be',
      'beef',
      'beef b',
      'beef broc',
      'beef brocoli',
      'sweet and sour chiken',
      'a a a a a a a a',
    ];
    for (var i = 0; i < 10; i++) {
      for (final t in typed) {
        big.find(t);
      }
    }
    final each = watch.elapsedMicroseconds / (10 * typed.length);
    printOnFailure('${each.round()} µs a search over ${menu.length * 15} dishes');
    expect(each, lessThan(8000));
  });
}
