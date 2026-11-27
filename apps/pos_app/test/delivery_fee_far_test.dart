import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/delivery_fee.dart';
import 'package:pos_app/screens/delivery_fee_dialog.dart';
import 'package:pos_app/screens/fee_picker.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart';

import 'catering_test.dart' show dataOf, enabled, kinds, tapKey;
import 'delivery_distance_test.dart' show lindaTo, main9, oak, said, typeAddress;
import 'delivery_fee_test.dart' show carried, delivery, offered, picked, pumpForm, pumpOrder, typeDelivery;
import 'delivery_test.dart' show created, elm, key, typed;
import 'hub.dart';
import 'location_rows.dart';

/// Two things the owner asked for on 2026-11-27 (docs/delivery.md, "A custom fee for a delivery further
/// away" and "More than four prices"):
///
/// - "Allow custom delivery fee for distance more than the max delivery fee distance in the delivery fee
///   settings": where the location lets it, a delivery that goes further than the last price reaches is
///   charged what whoever takes the order types.
/// - "Also delivery fees with lots of options (over 4) change it something that fit better on the screen
///   than a bunch of buttons (maybe like a slider or something better)": more than four prices are one
///   line that says the fee picked and opens the whole list.
///
/// The hub's side of the custom fee is backend/tests/orders/test_delivery_fee.py.

/// A custom fee as an order carries it once the hub filled it in.
Map<String, dynamic> customFee(String amount, {bool taxed = false}) => {
  'by': 'custom',
  'up_to': null,
  'amount': amount,
  'taxed': taxed,
};

/// What the one line of a long list says.
String line(WidgetTester tester) =>
    tester.widget<Text>(key('fee-list-picked')).textSpan?.toPlainText() ?? said(tester, 'fee-list-picked');

/// The lines of the open list, as they read: how far, and what it costs.
List<String> listed(WidgetTester tester) => [
  for (final row in tester.widgetList<FeeListLine>(find.byType(FeeListLine)))
    [row.title, if (row.price.isNotEmpty) row.price].join(', '),
];

/// The line of the open list that is marked as the one picked; null when none is.
String? marked(WidgetTester tester) => [
  for (final row in tester.widgetList<FeeListLine>(find.byType(FeeListLine)))
    if (row.selected) row.title,
].firstOrNull;

/// The message under the box a custom fee is typed in, when what is typed is no amount.
String? amountProblem(WidgetTester tester) => tester.widget<TextField>(key('fee-custom-amount')).decoration!.errorText;

void main() {
  group('the custom fee, as it is kept and sent', () {
    test('a location says whether a far delivery may be charged a typed fee', () {
      final fees = DeliveryFees.fromJson(Hub.customFees);
      expect((fees.custom, fees.offersCustom, fees.furthest?.upTo), (true, true, '8'));
      expect(fees.toJson()['custom'], isTrue);
      // turned off, and a hub older than the custom fee, which says nothing and is told nothing
      final off = DeliveryFees.fromJson({...Hub.milesFees, 'custom': false});
      expect((off.custom, off.offersCustom, off.toJson()['custom']), (false, false, false));
      final older = DeliveryFees.fromJson(Hub.milesFees);
      expect((older.custom, older.offersCustom, older.toJson().containsKey('custom')), (null, false, false));
      // with no fee charged there is nothing to be further than
      expect(DeliveryFees.fromJson({...Hub.customFees, 'enabled': false}).offersCustom, isFalse);
      expect(const DeliveryFees(enabled: true, custom: true).offersCustom, isFalse);
      // the band that reaches furthest, however the list is handed over
      const mixed = DeliveryFees(
        enabled: true,
        bands: [
          FeeBand(upTo: '10', fee: '9.00'),
          FeeBand(upTo: '2', fee: '3.00'),
          FeeBand(upTo: '4.5', fee: '5.00'),
        ],
      );
      expect((mixed.furthest?.upTo, const DeliveryFees().furthest), ('10', null));
      expect((pastWords('miles', '8'), pastWords('minutes', '20')), ('Past 8 mi', 'Past 20 min'));
    });

    test('what is typed is an amount once it is dollars and cents above nothing', () {
      for (final (text, amount) in [
        ('12.50', '12.50'),
        ('12.5', '12.50'),
        ('12', '12.00'),
        ('12.', '12.00'),
        ('.5', '0.50'),
        (r'$7', '7.00'),
        (' 999.99 ', '999.99'),
        ('0.01', '0.01'),
      ]) {
        expect(FeePick.money(text), amount, reason: text);
      }
      for (final text in ['', '0', '0.00', '.', '12.505', '1000', '-5', 'a lot', '1.2.3', '1,50']) {
        expect(FeePick.money(text), isNull, reason: text);
      }
    });

    test('a form holds the custom fee as far as it is typed, and sends its amount', () {
      expect((FeePick.typed(''), FeePick.typed(' 12.5 ')), (FeePick.custom, '+12.5'));
      expect((FeePick.isCustom(FeePick.custom), FeePick.isCustom('+12.5')), (true, true));
      for (final other in [null, FeePick.none, FeePick.kept, '4.5', '12.5']) {
        expect(FeePick.isCustom(other), isFalse, reason: '$other');
        expect((FeePick.typedOf(other), FeePick.amountOf(other), FeePick.unfinished(other)), ('', null, false));
      }
      expect((FeePick.typedOf('+12.5'), FeePick.amountOf('+12.5')), ('12.5', '12.50'));
      expect(
        (FeePick.unfinished(FeePick.custom), FeePick.unfinished('+0'), FeePick.unfinished('+12')),
        (true, true, false),
      );
      // the amount alone: it is the one amount a screen says
      expect(FeePick.field('+12.5'), {'custom': '12.50'});
      const map = Measured(miles: '9.3', minutes: 21, service: 'geocodio', from: '3fa9c2d1');
      expect(FeePick.field('+15', measured: map), {'custom': '15.00', 'measured': map.toJson()});
      expect(FeePick.field('4.5'), {'up_to': '4.5'}); // a band is sent as ever
      expect(FeePick.field(FeePick.none), {'up_to': null});
    });

    test('what an order carries of a custom fee', () {
      final fee = OrderFee.of(customFee('12.50', taxed: true))!;
      expect((fee.custom, fee.none, fee.onWebsite, fee.upTo), (true, false, false, null));
      expect((fee.amount, fee.taxed, fee.pick), ('12.50', true, '+12.50'));
      expect((fee.reach, fee.words), ('Custom fee', r'$12.50 · custom fee'));
      const map = {'miles': '9.3', 'minutes': 21};
      expect(OrderFee.of({...customFee('12.50'), 'measured': map})?.measured?.words, '9.3 mi · 21 min');
      // a custom fee of nothing is no fee
      expect(OrderFee.of(customFee('0.00'))?.none, isTrue);
      expect(Order.fromJson(delivery(fee: customFee('12.50'))).deliveryFee, OrderFee.of(customFee('12.50')));
    });

    test('only what changed is sent', () {
      final fees = DeliveryFees.fromJson(Hub.customFees);
      final taken = OrderFee.of(customFee('12.50'))!;
      expect(FeePick.listed(taken, fees), isTrue);
      expect(FeePick.changed(FeePick.kept, taken, fees), isNull);
      expect(FeePick.changed('+12.50', taken, fees), isNull);
      expect(FeePick.changed('+12.5', taken, fees), isNull); // the 12.50 it carries, typed another way
      expect(FeePick.changed('+14', taken, fees), '+14');
      expect((FeePick.changed('8', taken, fees), FeePick.changed(FeePick.none, taken, fees)), ('8', FeePick.none));
      // half typed is nothing to send
      expect((FeePick.changed(FeePick.custom, taken, fees), FeePick.changed('+0', null, fees)), (null, null));
      expect(FeePick.changed('+9', OrderFee.of(carried('8', '8.50')), fees), '+9');
      expect(FeePick.changed('+9', null, fees), '+9');
      // where the location takes no typed fee any more, the one on the order is not of its list
      final off = DeliveryFees.fromJson({...Hub.milesFees, 'custom': false});
      expect((FeePick.listed(taken, off), FeePick.listed(taken, null)), (false, false));
      expect(FeePick.listed(taken, DeliveryFees.fromJson(Hub.milesFees)), isFalse);
    });

    test('the map picks the band, or the custom fee for an address further than them all', () {
      final fees = DeliveryFees.fromJson(Hub.customFees);
      final near = FeeLookup.fromJson({
        'miles': '3.2',
        'minutes': 9,
        'band': {'up_to': '4.5', 'fee': '5.00'},
        'beyond': false,
      });
      final far = FeeLookup.fromJson({'miles': '9.3', 'minutes': 21, 'band': null, 'beyond': true});
      expect((FeePick.found(near, fees, null), FeePick.found(near, fees, '+12')), ('4.5', '4.5'));
      expect((FeePick.found(far, fees, null), FeePick.found(far, fees, '2')), (FeePick.custom, FeePick.custom));
      expect(FeePick.found(far, fees, '+12'), '+12'); // what is typed of one already stays
      // no answer, or nowhere a fee may be typed: the form is left as it is
      expect((FeePick.found(null, fees, '2'), FeePick.found(far, null, '2')), (null, null));
      expect(FeePick.found(far, DeliveryFees.fromJson(Hub.milesFees), null), isNull);
      // typing the amount of a custom fee that is picked already is no pick by hand; any other tap is
      expect((FeePick.byHand(FeePick.custom, '+1'), FeePick.byHand('+1', '+12')), (false, false));
      expect(
        (FeePick.byHand(null, FeePick.custom), FeePick.byHand('+12', '8'), FeePick.byHand('2', '8')),
        (true, true, true),
      );
    });

    test('the history says a custom fee by name', () {
      StepWords words(Object? now, Object? was) => wordsOf(
        HistoryStep.fromJson({'op_id': 'x', 'what': 'delivery_fee', 'now': now, 'was': was}),
        time: (ms) => '$ms',
      );
      var step = words({
        ...customFee('12.50'),
        'measured': {'miles': '9.3', 'minutes': 21},
      }, carried('8', '8.50'));
      expect(step.title, r'Delivery fee $12.50');
      expect(step.under, ['Custom fee', 'The map said 9.3 mi · 21 min', r'It was $8.50 · up to 8 mi']);
      step = words(carried('2', '3.00'), customFee('12.50'));
      expect(step.under, ['Up to 2 mi', r'It was $12.50 · custom fee']);
    });
  });

  group('a custom fee on the to-go form', () {
    testWidgets('it is one more button after the prices, and its amount is typed under them', (tester) async {
      final t = await pumpForm(tester, fees: Hub.customFees);
      await typeDelivery(tester);
      expect(offered(tester), [
        r'$3.00, Up to 2 mi',
        r'$5.00, Up to 4.5 mi',
        r'$8.50, Up to 8 mi',
        'Custom fee, Past 8 mi',
        'No fee',
      ]);
      expect(key('fee-custom-amount'), findsNothing);
      expect(said(tester, 'fee-needed'), 'Pick the delivery fee.');

      await tapKey(tester, 'fee:custom');
      expect((picked(tester, 'custom'), picked(tester, '8')), (true, false));
      expect(key('fee-custom-amount'), findsOneWidget);
      // what it costs is the next thing to say: the keyboard is in its box
      expect(tester.widget<TextField>(key('fee-custom-amount')).focusNode!.hasFocus, isTrue);
      expect(said(tester, 'fee-needed'), 'Type the delivery fee.');
      expect(enabled(tester, 'takeout-start'), isFalse);

      await tester.enterText(key('fee-custom-amount'), '12.5');
      await tester.pumpAndSettle();
      expect(key('fee-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);
      expect(offered(tester)[3], r'$12.50, Past 8 mi'); // what was typed heads its button, as a price heads its own
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'custom': '12.50'});
      await stop(tester);
    });

    testWidgets('what is no amount is said under the box, and Start waits', (tester) async {
      await pumpForm(tester, fees: Hub.customFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee:custom');
      for (final (text, problem) in [
        ('0', true),
        ('12.345', true),
        ('1.2.3', true),
        ('12', false),
        ('', false), // nothing typed is nothing wrong yet: the line under the form asks for it
      ]) {
        await tester.enterText(key('fee-custom-amount'), text);
        await tester.pumpAndSettle();
        expect(amountProblem(tester) != null, problem, reason: text);
        expect(enabled(tester, 'takeout-start'), text == '12', reason: text);
      }
      // letters are not taken at all
      await tester.enterText(key('fee-custom-amount'), r'$12 or so');
      await tester.pumpAndSettle();
      expect(typed(tester, 'fee-custom-amount'), '12');
      await stop(tester);
    });

    testWidgets('a price picked after all, and the custom fee again: what was typed is still there', (tester) async {
      final t = await pumpForm(tester, fees: Hub.customFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee:custom');
      await tester.enterText(key('fee-custom-amount'), '15');
      await tester.pumpAndSettle();
      await tapKey(tester, 'fee:8');
      expect(key('fee-custom-amount'), findsNothing);
      expect((picked(tester, '8'), picked(tester, 'custom')), (true, false));
      await tapKey(tester, 'fee:custom');
      expect(typed(tester, 'fee-custom-amount'), '15');
      expect(enabled(tester, 'takeout-start'), isTrue);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'custom': '15.00'});
      await stop(tester);
    });

    testWidgets('no custom fee where the location turned it off, or the hub is older than it', (tester) async {
      for (final fees in [
        {...Hub.milesFees, 'custom': false},
        Hub.milesFees,
      ]) {
        await pumpForm(tester, fees: fees);
        await typeDelivery(tester);
        expect(offered(tester), [r'$3.00, Up to 2 mi', r'$5.00, Up to 4.5 mi', r'$8.50, Up to 8 mi', 'No fee']);
        expect(key('fee:custom'), findsNothing);
        await stop(tester);
      }
    });

    testWidgets('a catering order may be told its fee later, but not half of one', (tester) async {
      await pumpForm(tester, fees: Hub.customFees);
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:catering');
      await tapKey(tester, 'handover:delivery');
      expect(key('fee-needed'), findsNothing);
      await tapKey(tester, 'fee:custom');
      expect(said(tester, 'fee-needed'), 'Type the delivery fee.');
      await tester.enterText(key('fee-custom-amount'), '40');
      await tester.pumpAndSettle();
      expect(key('fee-needed'), findsNothing);
      await stop(tester);
    });

    testWidgets('an address further than every price asks for the custom fee by itself', (tester) async {
      final t = await pumpForm(tester, fees: Hub.customMapFees);
      await lindaTo(tester, oak);
      expect(said(tester, 'fee-lookup-found'), '9.3 mi · 21 min drive: further than the prices reach');
      expect(picked(tester, 'custom'), isTrue);
      expect(key('fee-custom-amount'), findsOneWidget);
      expect(said(tester, 'fee-needed'), 'Type the delivery fee.');
      expect(enabled(tester, 'takeout-start'), isFalse);
      await tester.enterText(key('fee-custom-amount'), '15');
      await tester.pumpAndSettle();
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'custom': '15.00',
        'measured': {'miles': '9.3', 'minutes': 21, ...Hub.mapMark},
      });
      await stop(tester);
    });

    testWidgets('typing its amount is no pick by hand: a nearer address typed after it gets its own price', (
      tester,
    ) async {
      final t = await pumpForm(tester, fees: Hub.customMapFees);
      await lindaTo(tester, oak);
      await tester.enterText(key('fee-custom-amount'), '15');
      await tester.pumpAndSettle();
      await typeAddress(tester, main9); // it was Main Street after all
      expect(said(tester, 'fee-lookup-found'), '1.1 mi · 4 min drive');
      expect((picked(tester, '2'), picked(tester, 'custom')), (true, false));
      expect(key('fee-custom-amount'), findsNothing);
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'up_to': '2',
        'measured': {'miles': '1.1', 'minutes': 4, ...Hub.mapMark},
      });
      await stop(tester);
    });

    testWidgets('a custom fee tapped by hand stays when the map finds the address within the prices', (tester) async {
      final t = await pumpForm(tester, fees: Hub.customMapFees);
      await lindaTo(tester, elm);
      expect(picked(tester, '4.5'), isTrue); // 3.2 miles
      await tapKey(tester, 'fee:custom'); // the bridge is closed: it is the long way round tonight
      await tester.enterText(key('fee-custom-amount'), '11');
      await tester.pumpAndSettle();
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {
        'custom': '11.00',
        'measured': {'miles': '3.2', 'minutes': 9, ...Hub.mapMark},
      });
      await stop(tester);
    });

    testWidgets('it fits a small phone with large type', (tester) async {
      await pumpForm(tester, fees: Hub.customFees, size: const Size(320, 640), type: 1.3);
      await typeDelivery(tester);
      expect(find.text('Delivery fee, up to'), findsOneWidget);
      expect(offered(tester), [r'$3.00, 2 mi', r'$5.00, 4.5 mi', r'$8.50, 8 mi', 'Custom fee, Past 8 mi', 'No fee']);
      await tapKey(tester, 'fee:custom');
      await tester.enterText(key('fee-custom-amount'), '0'); // with the line that says what is wrong
      await tester.pumpAndSettle();
      expect(amountProblem(tester), isNotNull);
      await tester.enterText(key('fee-custom-amount'), '999.99');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(enabled(tester, 'takeout-start'), isTrue);
      await stop(tester);
    });
  });

  group('a custom fee on the order', () {
    testWidgets('the one it carries is picked, with its amount; saved as it was, nothing is written', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: customFee('12.50')), fees: Hub.customFees);
      await tapKey(tester, 'leaving-chip');
      expect((picked(tester, 'custom'), picked(tester, '8')), (true, false));
      expect(key('fee:kept'), findsNothing);
      expect(typed(tester, 'fee-custom-amount'), '12.50');
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);

      // the same amount typed another way is no change either
      await tapKey(tester, 'leaving-chip');
      await tester.enterText(key('fee-custom-amount'), '12.5');
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);

      // another amount is sent alone, with who typed it
      await tapKey(tester, 'leaving-chip');
      await tester.enterText(key('fee-custom-amount'), '14');
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1'), {
        'delivery_fee': {'custom': '14.00'},
        'by': 'Amy',
        'by_id': 's1',
      });
      await stop(tester);
    });

    testWidgets('it cannot be saved with its amount rubbed out', (tester) async {
      await pumpOrder(tester, delivery(fee: carried('8', '8.50')), fees: Hub.customFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:custom');
      expect(said(tester, 'fee-needed'), 'Type the delivery fee.');
      expect(enabled(tester, 'when-save'), isFalse);
      await tester.enterText(key('fee-custom-amount'), '10');
      await tester.pumpAndSettle();
      expect(enabled(tester, 'when-save'), isTrue);
      await tester.enterText(key('fee-custom-amount'), '');
      await tester.pumpAndSettle();
      expect(enabled(tester, 'when-save'), isFalse);
      await stop(tester);
    });

    testWidgets('one typed while the location let it stays as it was taken, until another is picked', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: customFee('12.50')), fees: {...Hub.milesFees, 'custom': false});
      await tapKey(tester, 'leaving-chip');
      expect(offered(tester).first, r'$12.50 · as taken, Custom fee');
      expect(picked(tester, 'kept'), isTrue);
      expect(key('fee:custom'), findsNothing);
      expect(key('fee-custom-amount'), findsNothing);
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee:8');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '8'});
      await stop(tester);
    });

    testWidgets('a pickup made a delivery to an address further than every price', (tester) async {
      final t = await pumpOrder(tester, delivery(brought: false), fees: Hub.customMapFees);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'handover:delivery');
      await typeAddress(tester, oak);
      expect(picked(tester, 'custom'), isTrue);
      expect(enabled(tester, 'when-save'), isFalse);
      await tester.enterText(key('fee-custom-amount'), '15');
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {
        'custom': '15.00',
        'measured': {'miles': '9.3', 'minutes': 21, ...Hub.mapMark},
      });
      await stop(tester);
    });
  });

  group('more than four prices', () {
    /// [count] prices, a mile apart.
    Map<String, dynamic> prices(int count, {bool? custom}) => {
      'enabled': true,
      'by': 'miles',
      'bands': [
        for (var mile = 1; mile <= count; mile++) {'up_to': '$mile', 'fee': '${mile + 1}.00'},
      ],
      'taxed': false,
      'custom': ?custom,
    };

    test('four are a button each, and the custom fee is not counted among them', () {
      expect(DeliveryFees.mostButtons, 4);
      expect(DeliveryFees.fromJson(prices(4, custom: true)).crowded, isFalse);
      expect(DeliveryFees.fromJson(prices(5)).crowded, isTrue);
      expect(DeliveryFees.fromJson(Hub.manyFees).crowded, isTrue);
    });

    testWidgets('four prices are buttons still', (tester) async {
      await pumpForm(tester, fees: prices(4, custom: true));
      await typeDelivery(tester);
      expect(key('fee-list'), findsNothing);
      expect(offered(tester).length, 6); // the four, the custom fee and no fee
      await stop(tester);
    });

    testWidgets('five and more are one line, and a tap on it opens the whole list', (tester) async {
      final t = await pumpForm(tester, fees: Hub.manyFees);
      await typeDelivery(tester);
      expect(find.byType(ChoiceTile), findsNothing);
      expect(find.text('Delivery fee'), findsOneWidget);
      expect(line(tester), 'Pick the fee');
      expect(key('fee-list-sheet'), findsNothing);
      expect(said(tester, 'fee-needed'), 'Pick the delivery fee.');
      expect(enabled(tester, 'takeout-start'), isFalse);

      await tapKey(tester, 'fee-list');
      expect(listed(tester), [
        'Up to 0.5 mi, Free',
        r'Up to 1 mi, $2.00',
        r'Up to 2 mi, $3.00',
        r'Up to 3 mi, $4.00',
        r'Up to 4.5 mi, $5.00',
        r'Up to 8 mi, $8.50',
        'Custom fee · past 8 mi',
        'No fee',
      ]);
      expect(marked(tester), isNull);
      await tapKey(tester, 'fee:3');
      expect(key('fee-list-sheet'), findsNothing); // a tap picks, and puts the list away
      expect(line(tester), r'$4.00 · Up to 3 mi');
      expect(key('fee-needed'), findsNothing);
      expect(enabled(tester, 'takeout-start'), isTrue);

      // opened again, the one picked is marked; another is a tap
      await tapKey(tester, 'fee-list');
      expect(marked(tester), 'Up to 3 mi');
      await tapKey(tester, 'fee:0.5');
      expect(line(tester), 'Free · Up to 0.5 mi');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'up_to': '0.5'});
      await stop(tester);
    });

    testWidgets('the list put away with nothing tapped changes nothing', (tester) async {
      await pumpForm(tester, fees: Hub.manyFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee-list');
      await tapKey(tester, 'fee:2');
      await tapKey(tester, 'fee-list');
      await tester.tapAt(const Offset(10, 10)); // beside the list
      await tester.pumpAndSettle();
      expect(key('fee-list-sheet'), findsNothing);
      expect(line(tester), r'$3.00 · Up to 2 mi');
      await stop(tester);
    });

    testWidgets('"No fee" and the custom fee are lines of the list', (tester) async {
      final t = await pumpForm(tester, fees: Hub.manyFees);
      await typeDelivery(tester);
      await tapKey(tester, 'fee-list');
      await tapKey(tester, 'fee:none');
      expect(line(tester), 'No fee');
      expect(enabled(tester, 'takeout-start'), isTrue);

      await tapKey(tester, 'fee-list');
      expect(find.text('Type what this delivery costs'), findsOneWidget);
      await tapKey(tester, 'fee:custom');
      expect(line(tester), 'Custom fee · Past 8 mi');
      expect(tester.widget<TextField>(key('fee-custom-amount')).focusNode!.hasFocus, isTrue);
      expect(said(tester, 'fee-needed'), 'Type the delivery fee.');
      await tester.enterText(key('fee-custom-amount'), '12.5');
      await tester.pumpAndSettle();
      expect(line(tester), r'$12.50 · Past 8 mi');
      await tapKey(tester, 'fee-list');
      expect(listed(tester)[6], r'Custom fee · past 8 mi, $12.50');
      expect(marked(tester), 'Custom fee · past 8 mi');
      await tapKey(tester, 'fee:custom'); // the same again: what was typed stays
      expect(typed(tester, 'fee-custom-amount'), '12.5');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['delivery_fee'], {'custom': '12.50'});
      await stop(tester);
    });

    testWidgets('the map picks the line, and the open list says how far the address is', (tester) async {
      final t = await pumpForm(
        tester,
        fees: {...Hub.manyFees, 'origin': '1 Restaurant Row, Winchester', 'maps': true, 'lookup': true},
      );
      await lindaTo(tester, elm);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      expect(line(tester), r'$5.00 · Up to 4.5 mi');
      await tapKey(tester, 'fee-list');
      expect(said(tester, 'fee-list-drive'), '3.2 mi · 9 min drive');
      expect(marked(tester), 'Up to 4.5 mi');
      await tapKey(tester, 'fee:8'); // the bridge is closed tonight
      expect(line(tester), r'$8.50 · Up to 8 mi');

      // an address further than them all: the line asks for the custom fee
      await typeAddress(tester, oak);
      expect(line(tester), r'$8.50 · Up to 8 mi'); // a price tapped by hand stands
      await stop(tester);
      await pumpForm(
        tester,
        fees: {...Hub.manyFees, 'origin': '1 Restaurant Row, Winchester', 'maps': true, 'lookup': true},
      );
      await lindaTo(tester, oak);
      expect(line(tester), 'Custom fee · Past 8 mi');
      expect(key('fee-custom-amount'), findsOneWidget);
      expect(t.hub.distanceAsks, isNotEmpty);
      await stop(tester);
    });

    testWidgets('on the order: the fee it carries is on the line, and one the list has no more is its own line', (
      tester,
    ) async {
      var t = await pumpOrder(tester, delivery(fee: carried('4.5', '5.00')), fees: Hub.manyFees);
      await tapKey(tester, 'leaving-chip');
      expect(line(tester), r'$5.00 · Up to 4.5 mi');
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await tapKey(tester, 'leaving-chip');
      await tapKey(tester, 'fee-list');
      await tapKey(tester, 'fee:8');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['delivery_fee'], {'up_to': '8'});
      await stop(tester);

      // it was six miles for seven dollars when the order was taken
      t = await pumpOrder(tester, delivery(fee: carried('6', '7.00')), fees: Hub.manyFees);
      await tapKey(tester, 'leaving-chip');
      expect(line(tester), r'$7.00 · as taken · Up to 6 mi');
      await tapKey(tester, 'fee-list');
      expect(listed(tester).first, r'Up to 6 mi, $7.00');
      expect(find.text('As it was taken'), findsOneWidget);
      expect(marked(tester), 'Up to 6 mi');
      await tapKey(tester, 'fee:kept');
      await tapKey(tester, 'when-save');
      expect(kinds(t.hub, 'o1'), isEmpty);
      await stop(tester);
    });

    testWidgets('eight prices by minutes, on a small phone with large type: the line, the list and the box fit', (
      tester,
    ) async {
      final fees = {
        'enabled': true,
        'by': 'minutes',
        'bands': [
          for (final minutes in [5, 10, 15, 20, 30, 45, 60, 240]) {'up_to': '$minutes', 'fee': '${minutes + 99}.99'},
        ],
        'taxed': true,
        'custom': true,
      };
      await pumpForm(tester, fees: fees, size: const Size(320, 640), type: 1.3);
      await typeDelivery(tester);
      expect(find.text('Delivery fee'), findsOneWidget); // a line is as wide as the form: it says "Up to"
      await tapKey(tester, 'fee-list');
      expect(tester.takeException(), isNull);
      expect(listed(tester).length, 10);
      // the list is longer than the screen and scrolls in itself to its last line
      await tapKey(tester, 'fee:240');
      expect(line(tester), r'$339.99 · Up to 240 min');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'fee-list');
      await tapKey(tester, 'fee:custom');
      await tester.enterText(key('fee-custom-amount'), '999.99');
      await tester.pumpAndSettle();
      expect(line(tester), r'$999.99 · Past 240 min');
      expect(tester.takeException(), isNull);
      await stop(tester);

      await pumpOrder(
        tester,
        delivery(fee: carried('3', '4.00')),
        fees: fees,
        size: const Size(320, 640),
        type: 1.3,
      );
      await tapKey(tester, 'when-strip');
      expect(line(tester), r'$4.00 · as taken · Up to 3 mi');
      await tapKey(tester, 'fee-list');
      expect(listed(tester).length, 11);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'fee:none');
      expect(line(tester), 'No fee');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the custom fee under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, Map<String, dynamic> fees, {Size? size, double? type}) async {
      final t = await terminal(tester);
      t.hub.deliveryFees = fees;
      if (size != null) tester.view.physicalSize = size;
      if (type != null) {
        tester.platformDispatcher.textScaleFactorTestValue = type;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'delivery-fee');
      return t;
    }

    String rowWords(WidgetTester tester) => ((tester.widget<ListTile>(key('delivery-fee')).subtitle!) as Text).data!;
    bool on(WidgetTester tester) => tester.widget<SwitchListTile>(key('fee-custom')).value;

    testWidgets('a switch says whether a far delivery may be charged a typed fee; it is on to start', (tester) async {
      final t = await pumpLocation(tester, Hub.customFees);
      expect(rowWords(tester), r'$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi, custom fee further out');
      await tapKey(tester, 'delivery-fee');
      expect(find.byType(DeliveryFeeDialog), findsOneWidget);
      expect(on(tester), isTrue);
      expect(find.text('Custom fee past the last distance'), findsOneWidget);
      expect(
        find.text('For a delivery further than the last price reaches, whoever takes the order types what it costs'),
        findsOneWidget,
      );
      await tapKey(tester, 'fee-custom');
      expect(on(tester), isFalse);
      expect(
        find.text('A delivery further than the last price reaches is charged one of the prices, or no fee'),
        findsOneWidget,
      );
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?['custom'], isFalse);
      expect(t.hub.deliveryFees?['bands'], Hub.milesFees['bands']); // the prices as they were
      expect(rowWords(tester), r'$3.00 up to 2 mi, $5.00 up to 4.5 mi, $8.50 up to 8 mi');

      // and on again
      await tapKey(tester, 'delivery-fee');
      expect(on(tester), isFalse);
      await tapKey(tester, 'fee-custom');
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?['custom'], isTrue);
      await stop(tester);
    });

    testWidgets('a hub older than the custom fee shows no switch, and is told nothing of one', (tester) async {
      final t = await pumpLocation(tester, Hub.milesFees);
      await tapKey(tester, 'delivery-fee');
      expect(key('fee-custom'), findsNothing);
      await tapKey(tester, 'fee-taxed');
      await tapKey(tester, 'fee-save');
      expect(t.hub.deliveryFees?.containsKey('custom'), isFalse);
      expect(t.hub.deliveryFees?['taxed'], isTrue);
      await stop(tester);
    });

    testWidgets('the dialog says how a long list is shown, and fits a 320-wide phone with large type', (tester) async {
      await pumpLocation(tester, Hub.manyFees, size: const Size(320, 640), type: 1.3);
      await tapKey(tester, 'delivery-fee');
      expect(
        said(tester, 'fee-bands-says'),
        'Nearest first. Up to 4 are a button each on a delivery; more are one line that opens the whole list. '
        '"No fee" is always a choice.',
      );
      await tapKey(tester, 'fee-custom');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
