import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/bag.dart';
import 'package:pos_app/check_history.dart';
import 'package:pos_app/screens/bag_question_dialog.dart';
import 'package:pos_app/screens/bag_sheet.dart';
import 'package:pos_app/screens/location_settings_screen.dart';
import 'package:pos_app/screens/menu_panel.dart';
import 'package:pos_app/screens/order_screen.dart';
import 'package:pos_app/screens/pay_dialog.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub.dart';
import 'location_rows.dart';

/// The to-go question (docs/to-go-question.md): before a to-go order is sent, the screen asks once what goes
/// in the bag besides the food. The location lists what to offer; "Nothing" is an answer. The answer goes on
/// the order, shows over the check's totals, and a tap there asks again. The hub prints it; these tests are
/// about the screen asking, at the right moment and only then, and sending the answer as the hub wants it.

const chopsticks2 = BagItem(id: 'chopsticks', name: 'Chopsticks', qty: 2);
const forks = BagItem(id: 'forks', name: 'Forks');
const napkins = BagItem(id: 'napkins', name: 'Napkins');

Map<String, dynamic> answered(List<BagItem> items) => bagField(items);

/// Linda's phone order, number 7: two egg rolls the kitchen has not seen ([sent]: it has), with [bag] as the
/// answer it carries.
Map<String, dynamic> toGo({bool sent = false, Map<String, dynamic>? bag, bool paid = false}) => {
  'order_id': 'o1',
  'status': 'open',
  'fields': {
    'order_type': 'takeout',
    'order_no': 7,
    'customer_name': 'Linda',
    'channel': 'phone',
    'stage': 'new',
    'bag': ?bag,
  },
  'lines': {'L1': line('Egg roll', fired: sent)..['qty'] = 2},
  'fired': sent ? {'': '2026-11-16T18:00:00'} : <String, dynamic>{},
  'payments': paid
      ? {
          'P1': {'method': 'cash', 'amount': '10.70', 'by': 'Amy'},
        }
      : <String, dynamic>{},
};

/// Two egg rolls with the 7% rate; [paid] leaves nothing due, so the order is sent with "Send" alone.
Map<String, dynamic> rolls({bool paid = false}) => {
  'lines': [
    {'line_id': 'L1', 'name': 'Egg roll', 'qty': 2, 'total': '10.00'},
  ],
  'subtotal': '10.00',
  'tax_rate_pct': '7.00',
  'tax': '0.70',
  'total': '10.70',
  'paid': paid ? '10.70' : '0.00',
  'due': paid ? '0.00' : '10.70',
};

/// Amy at the order, pushed over a page so a test sees it go back for the next customer. The hub asks the
/// standard question unless [question] says otherwise (null: a hub older than the question).
Future<Terminal> pumpToGo(
  WidgetTester tester,
  Map<String, dynamic> order, {
  bool paid = false,
  Size size = const Size(1100, 800),
  Object? question = #standard,
}) async {
  final t = await terminal(tester);
  t.session.staff = const Staff(staffId: 's1', name: 'Amy', role: 'server', method: 'pin');
  t.hub.bag = question == #standard ? Hub.standardBag : question as Map<String, dynamic>?;
  t.hub.check = rolls(paid: paid || (order['payments'] as Map).isNotEmpty);
  t.hub.orders.add(order);
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('next customer'))),
    ),
  );
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
          ),
        ),
  );
  await tester.pumpAndSettle();
  return t;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> tapAction(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(TextButton, label));
  await tester.pumpAndSettle();
}

/// What the terminal sent about order o1: each operation's kind, and the answers among them.
List<String> kinds(Hub hub) => [for (final op in hub.opsFor('o1')) op['kind'] as String];
List<Map<String, dynamic>> answers(Hub hub) => [
  for (final op in hub.opsFor('o1'))
    if ((op['data'] as Map).containsKey('bag')) (op['data'] as Map).cast<String, dynamic>(),
];

ChoiceTile tile(WidgetTester tester, String id) => tester.widget<ChoiceTile>(find.byKey(ValueKey('bag:$id')));
bool enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed != null;

Future<void> stop(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // stops the refresh timers

void main() {
  group('the question and its answer', () {
    test('the question is read as the hub keeps it, and asks only when it is on with something to offer', () {
      final question = BagQuestion.fromJson(Hub.standardBag);
      expect((question.enabled, question.question, question.asks), (true, 'What goes in the bag?', true));
      expect(
        [for (final c in question.choices) (c.id, c.name)],
        [('chopsticks', 'Chopsticks'), ('forks', 'Forks'), ('napkins', 'Napkins')],
      );
      expect(question.toJson(), Hub.standardBag);
      expect(BagQuestion.fromJson({...Hub.standardBag, 'enabled': false}).asks, isFalse);
      expect(BagQuestion.fromJson({'enabled': true, 'choices': <Object>[]}).asks, isFalse);
      // a hub that sent no words is asked in the standard ones; a new choice has no id until the hub names it
      expect(BagQuestion.fromJson({'question': ' '}).question, BagQuestion.standardWords);
      expect(const BagChoice(name: 'Duck sauce').toJson(), {'name': 'Duck sauce'});
    });

    test('an order carries its answer: what was picked, nothing, or no answer at all', () {
      expect(Order.fromJson(toGo()).bag, isNull);
      expect(Order.fromJson(toGo(bag: answered(const []))).bag, isEmpty);
      final order = Order.fromJson(toGo(bag: answered(const [chopsticks2, forks])));
      expect(order.bag, [chopsticks2, forks]);
      expect(bagWords(order.bag!), '2x Chopsticks, Forks');
      expect(bagWords(const []), 'Nothing');
      expect(bagField(const [chopsticks2]), {
        'items': [
          {'id': 'chopsticks', 'name': 'Chopsticks', 'qty': 2},
        ],
      });
      // an answer this build cannot read is as good as none, and the order is asked about again
      expect(bagAnswer({'bag': 'forks'}), isNull);
      expect(bagAnswer({'bag': <String, dynamic>{}}), isNull);
      expect(
        bagAnswer({
          'bag': {
            'items': ['forks'],
          },
        }),
        isNull,
      );
      // a name or a count left out reads as the id, and one
      expect(
        bagAnswer({
          'bag': {
            'items': [
              {'id': 'forks'},
            ],
          },
        }),
        [const BagItem(id: 'forks', name: 'forks')],
      );
    });

    test('the hub is asked for the question, and a hub older than it answers nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings(
        device: 't1',
        endpoints: ['http://hub:8000'],
        prefs: await SharedPreferences.getInstance(),
      );
      final hub = Hub();
      final api = PosApi(settings, client: MockClient(hub.handle));
      expect(await api.bagQuestion(), isNull);
      hub.bag = Hub.standardBag;
      expect((await api.bagQuestion())!.choices.length, 3);
      final saved = await api.saveBagQuestion(
        'tok-admin',
        const BagQuestion(
          question: 'Chopsticks or sauce?',
          choices: [
            BagChoice(id: 'chopsticks', name: 'Chopsticks'),
            BagChoice(name: 'Duck sauce'),
          ],
        ),
      );
      expect(hub.bagAuth, 'Bearer tok-admin');
      expect([for (final c in saved.choices) c.id], ['chopsticks', 'duck-sauce']);
      expect((await api.bagQuestion())!.question, 'Chopsticks or sauce?');
    });

    test("the check's history says what was answered", () {
      HistoryStep step(Map<String, dynamic> said) =>
          HistoryStep.fromJson({'op_id': 'x', 'at_ms': 1, 'device': 't1', 'what': 'bag', ...said});
      String time(int ms) => '';
      final asked = wordsOf(
        step({
          'items': [
            {'name': 'Chopsticks', 'qty': 2},
            {'name': 'Forks', 'qty': 1},
          ],
          'changed': false,
        }),
        time: time,
      );
      expect(asked.title, 'Asked what goes in the bag');
      expect(asked.under, ['2x Chopsticks, Forks']);
      final changed = wordsOf(step({'items': <Object>[], 'changed': true}), time: time);
      expect(changed.title, 'Changed what goes in the bag');
      expect(changed.under, ['Nothing']);
    });
  });

  group('before a to-go order is sent', () {
    testWidgets('Send asks first; what was picked goes on the order, then the order goes to the kitchen', (
      tester,
    ) async {
      final t = await pumpToGo(tester, toGo(paid: true));
      expect(find.byKey(const ValueKey('bag-row')), findsNothing); // nobody was asked yet
      await tapAction(tester, 'Send');
      expect(find.byType(BagSheet), findsOneWidget);
      expect(find.text('What goes in the bag?'), findsOneWidget);
      expect(
        [
          for (final id in ['chopsticks', 'forks', 'napkins']) tile(tester, id).name,
        ],
        ['Chopsticks', 'Forks', 'Napkins'],
      );
      expect(kinds(t.hub), isEmpty); // nothing went anywhere yet
      expect(enabled(tester, 'bag-done'), isFalse); // an answer first
      expect(enabled(tester, 'bag-nothing'), isTrue);

      // a tap puts one in, another tap one more, the minus takes one out
      await tapKey(tester, 'bag:chopsticks');
      await tapKey(tester, 'bag:chopsticks');
      await tapKey(tester, 'bag:chopsticks');
      await tapKey(tester, 'bag:forks');
      await tapKey(tester, 'bag:napkins');
      expect((tile(tester, 'chopsticks').name, tile(tester, 'chopsticks').selected), ('3x Chopsticks', true));
      expect((tile(tester, 'forks').name, tile(tester, 'forks').selected), ('Forks', true));
      final minus = find.descendant(
        of: find.byKey(const ValueKey('bag:chopsticks')),
        matching: find.byTooltip('One fewer'),
      );
      await tester.tap(minus);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('bag:napkins')), matching: find.byTooltip('One fewer')),
      );
      await tester.pumpAndSettle();
      expect(tile(tester, 'chopsticks').name, '2x Chopsticks');
      expect(tile(tester, 'napkins').selected, isFalse);
      expect(tile(tester, 'napkins').onRemove, isNull);

      expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
      await tapKey(tester, 'bag-done');
      expect(kinds(t.hub), ['set_field', 'fire']);
      expect(answers(t.hub).single, {
        'bag': answered(const [chopsticks2, forks]),
        'by': 'Amy',
        'by_id': 's1',
      });
      expect(find.text('next customer'), findsOneWidget); // sent, and back for the next one
      await stop(tester);
    });

    testWidgets('"Nothing" is an answer, in one tap', (tester) async {
      final t = await pumpToGo(tester, toGo(paid: true));
      await tapAction(tester, 'Send');
      await tapKey(tester, 'bag:forks'); // a pick is forgotten: nothing is nothing
      await tapKey(tester, 'bag-nothing');
      expect(kinds(t.hub), ['set_field', 'fire']);
      expect(answers(t.hub).single['bag'], {'items': <Object>[]});
      expect(find.text('next customer'), findsOneWidget);
      await stop(tester);
    });

    testWidgets('the sheet closed without an answer sends nothing', (tester) async {
      final t = await pumpToGo(tester, toGo(paid: true));
      await tapAction(tester, 'Send');
      await tapKey(tester, 'bag:forks');
      await tester.tapAt(const Offset(20, 20)); // beside the sheet
      await tester.pumpAndSettle();
      expect(find.byType(BagSheet), findsNothing);
      expect(kinds(t.hub), isEmpty);
      expect(find.widgetWithText(TextButton, 'Send'), findsOneWidget); // the order is still here
      // and it is asked again, from the start
      await tapAction(tester, 'Send');
      expect(tile(tester, 'forks').selected, isFalse);
      await stop(tester);
    });

    testWidgets('Pay & send asks before the money; a payment called off keeps the answer', (tester) async {
      final t = await pumpToGo(tester, toGo());
      await tapAction(tester, 'Pay & send');
      expect(find.byType(BagSheet), findsOneWidget);
      expect(find.byType(PayDialog), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);
      await tapKey(tester, 'bag:forks');
      await tapKey(tester, 'bag-done');
      expect(find.byType(PayDialog), findsOneWidget);
      expect(kinds(t.hub), ['set_field']);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(kinds(t.hub), ['set_field']); // not paid, not sent
      expect(find.text('In the bag: Forks'), findsOneWidget);

      // the second time nothing is asked: the order carries its answer
      await tapAction(tester, 'Pay & send');
      expect(find.byType(BagSheet), findsNothing);
      expect(find.byType(PayDialog), findsOneWidget);
      await tapKey(tester, 'pay:later');
      await tapKey(tester, 'pay-send');
      expect(kinds(t.hub), ['set_field', 'fire']);
      await stop(tester);
    });

    testWidgets('an order that carries an answer is sent with nothing asked', (tester) async {
      final t = await pumpToGo(tester, toGo(bag: answered(const [])), paid: true);
      expect(find.text('In the bag: Nothing'), findsOneWidget);
      await tapAction(tester, 'Send');
      expect(find.byType(BagSheet), findsNothing);
      expect(kinds(t.hub), ['fire']);
      await stop(tester);
    });

    testWidgets('a hub older than the question, or a location that turned it off, is sent to with nothing asked', (
      tester,
    ) async {
      var t = await pumpToGo(tester, toGo(paid: true), question: null);
      await tapAction(tester, 'Send');
      expect(find.byType(BagSheet), findsNothing);
      expect(kinds(t.hub), ['fire']);
      await stop(tester);

      t = await pumpToGo(tester, toGo(paid: true), question: {...Hub.standardBag, 'enabled': false});
      await tapAction(tester, 'Send');
      expect(find.byType(BagSheet), findsNothing);
      expect(kinds(t.hub), ['fire']);
      await stop(tester);
    });

    testWidgets("a table's check is never asked", (tester) async {
      final t = await terminal(tester);
      t.hub.bag = Hub.standardBag;
      t.hub.check = rolls();
      t.hub.orders.add(table('o1', {'L1': line('Egg roll', course: '1')}));
      await tester.pumpWidget(
        MaterialApp(
          home: OrderScreen(api: t.api, outbox: t.outbox, photos: t.photos, orderId: 'o1', session: t.session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Fire'));
      await tester.pumpAndSettle();
      expect(find.byType(BagSheet), findsNothing);
      expect(find.byKey(const ValueKey('bag-row')), findsNothing);
      await stop(tester);
    });

    testWidgets('the location words the question and lists what it offers', (tester) async {
      final t = await pumpToGo(
        tester,
        toGo(paid: true),
        question: {
          'enabled': true,
          'question': 'Chopsticks, forks or sauce?',
          'choices': [
            {'id': 'chopsticks', 'name': 'Chopsticks'},
            {'id': 'duck-sauce', 'name': 'Duck sauce'},
          ],
        },
      );
      await tapAction(tester, 'Send');
      expect(find.text('Chopsticks, forks or sauce?'), findsOneWidget);
      expect(find.byKey(const ValueKey('bag:forks')), findsNothing);
      await tapKey(tester, 'bag:duck-sauce');
      await tapKey(tester, 'bag-done');
      expect(answers(t.hub).single['bag'], answered(const [BagItem(id: 'duck-sauce', name: 'Duck sauce')]));
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the question, its buttons and the answer on the check fit', (tester) async {
      final t = await pumpToGo(
        tester,
        toGo(paid: true),
        size: const Size(320, 568),
        question: {
          'enabled': true,
          'question': 'Chopsticks, forks, napkins or any of the sauces in the bag?',
          'choices': [
            for (final name in ['Chopsticks', 'Forks', 'Napkins', 'Soy sauce', 'Duck sauce', 'Hot mustard'])
              {'id': name.toLowerCase().replaceAll(' ', '-'), 'name': name},
            {'id': 'long', 'name': 'Extra fortune cookies x'},
            {'id': 'last', 'name': 'Paper plates'},
          ],
        },
      );
      await tester.tap(find.byTooltip('Send')); // a phone's bar holds icons
      await tester.pumpAndSettle();
      expect(find.byType(BagSheet), findsOneWidget);
      for (final id in ['chopsticks', 'long', 'last']) {
        await tapKey(tester, 'bag:$id');
      }
      await tapKey(tester, 'bag:long');
      expect(tile(tester, 'long').name, '2x Extra fortune cookies x');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'bag-done');
      expect((answers(t.hub).single['bag'] as Map)['items'], hasLength(3));
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the answer on the check', () {
    testWidgets('a tap asks again with what the order carries; a change goes to the hub, which prints a slip', (
      tester,
    ) async {
      final t = await pumpToGo(tester, toGo(sent: true, bag: answered(const [chopsticks2, forks])), paid: true);
      expect(find.text('In the bag: 2x Chopsticks, Forks'), findsOneWidget);
      await tapKey(tester, 'bag-row');
      expect(find.byType(BagSheet), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      expect(tile(tester, 'chopsticks').name, '2x Chopsticks');
      expect((tile(tester, 'forks').selected, tile(tester, 'napkins').selected), (true, false));

      // saved as it was: nothing is sent
      await tapKey(tester, 'bag-done');
      expect(kinds(t.hub), isEmpty);

      await tapKey(tester, 'bag-row');
      await tapKey(tester, 'bag:napkins');
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('bag:forks')), matching: find.byTooltip('One fewer')),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'bag-done');
      expect(kinds(t.hub), ['set_field']);
      expect(answers(t.hub).single, {
        'bag': answered(const [chopsticks2, napkins]),
        'by': 'Amy',
        'by_id': 's1',
      });
      expect(find.text('The takeout printer gets a slip about it.'), findsOneWidget);
      expect(find.text('In the bag: 2x Chopsticks, Napkins'), findsOneWidget);
      expect(find.byType(OrderScreen), findsOneWidget); // a change sends nothing to the kitchen and stays here
      await stop(tester);
    });

    testWidgets('down to nothing, and no slip is spoken of while the kitchen has not seen the order', (tester) async {
      final t = await pumpToGo(tester, toGo(bag: answered(const [forks])), paid: true);
      await tapKey(tester, 'bag-row');
      await tapKey(tester, 'bag-nothing');
      expect(answers(t.hub).single['bag'], {'items': <Object>[]});
      expect(find.text('In the bag: Nothing'), findsOneWidget);
      expect(find.text('The takeout printer gets a slip about it.'), findsNothing);
      await stop(tester);
    });

    testWidgets('something the location no longer offers stays on the order until it is taken out', (tester) async {
      const spoons = BagItem(id: 'spoons', name: 'Spoons', qty: 2);
      final t = await pumpToGo(tester, toGo(bag: answered(const [spoons])), paid: true);
      await tapKey(tester, 'bag-row');
      expect(tile(tester, 'spoons').name, '2x Spoons');
      await tapKey(tester, 'bag:forks');
      await tapKey(tester, 'bag-done');
      expect(answers(t.hub).single['bag'], answered(const [spoons, forks]));
      await stop(tester);
    });

    testWidgets('a closed order says its answer and asks nothing', (tester) async {
      await pumpToGo(tester, {
        ...toGo(sent: true, bag: answered(const [forks])),
        'status': 'closed',
      }, paid: true);
      expect(find.text('In the bag: Forks'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bag-row')));
      await tester.pumpAndSettle();
      expect(find.byType(BagSheet), findsNothing);
      await stop(tester);
    });
  });

  group('the setting under Location', () {
    Future<Terminal> pumpLocation(WidgetTester tester, {Map<String, dynamic>? question, Size? size}) async {
      final t = await terminal(tester);
      t.hub.bag = question;
      if (size != null) tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: LocationSettingsScreen(api: t.api, token: 'tok-admin', device: 't1'),
        ),
      );
      await tester.pumpAndSettle();
      await bringUp(tester, 'to-go-question');
      return t;
    }

    String rowWords(WidgetTester tester) =>
        ((tester.widget<ListTile>(find.byKey(const ValueKey('to-go-question'))).subtitle!) as Text).data!;

    testWidgets('the row says what is asked; a manager rewords it, adds and removes choices', (tester) async {
      final t = await pumpLocation(tester, question: Hub.standardBag);
      expect(rowWords(tester), 'Asked before a to-go order is sent: Chopsticks, Forks, Napkins');
      await tapKey(tester, 'to-go-question');
      expect(find.byType(BagQuestionDialog), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('bag-words')), 'Chopsticks or sauce?');
      await tapKey(tester, 'bag-choice-remove:1'); // forks
      await tapKey(tester, 'bag-choice-add');
      await tester.enterText(find.byKey(const ValueKey('bag-choice-name:3')), 'Duck sauce');
      await tapKey(tester, 'bag-save');
      expect(find.byType(BagQuestionDialog), findsNothing);
      expect(t.hub.bagAuth, 'Bearer tok-admin');
      expect(t.hub.bag, {
        'enabled': true,
        'question': 'Chopsticks or sauce?',
        'choices': [
          {'id': 'chopsticks', 'name': 'Chopsticks'},
          {'id': 'napkins', 'name': 'Napkins'},
          {'id': 'duck-sauce', 'name': 'Duck sauce'}, // new on the screen: the hub named it
        ],
      });
      expect(find.text('To-go question saved'), findsOneWidget);
      expect(rowWords(tester), 'Asked before a to-go order is sent: Chopsticks, Napkins, Duck sauce');
      await stop(tester);
    });

    testWidgets('turned off, nothing is asked, and the row says so', (tester) async {
      final t = await pumpLocation(tester, question: Hub.standardBag);
      await tapKey(tester, 'to-go-question');
      await tapKey(tester, 'bag-enabled');
      expect(find.text('To-go orders are sent with nothing asked'), findsOneWidget);
      await tapKey(tester, 'bag-save');
      expect(t.hub.bag!['enabled'], isFalse);
      expect(rowWords(tester), 'Off: a to-go order is sent with nothing asked');
      await stop(tester);
    });

    testWidgets('what cannot be saved is said in the dialog, the hub\'s own words too', (tester) async {
      final t = await pumpLocation(tester, question: Hub.standardBag);
      await tapKey(tester, 'to-go-question');
      await tester.enterText(find.byKey(const ValueKey('bag-choice-name:1')), 'chopsticks');
      await tapKey(tester, 'bag-save');
      expect(find.text('Two choices have the same name'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('bag-choice-name:1')), ' ');
      await tapKey(tester, 'bag-save');
      expect(find.text('Every choice needs a name'), findsOneWidget);
      for (final row in [0, 1, 2]) {
        await tapKey(tester, 'bag-choice-remove:$row');
      }
      await tapKey(tester, 'bag-save');
      expect(find.text('List at least one thing to offer, or turn the question off'), findsOneWidget);
      expect(t.hub.bagAuth, isNull); // none of it reached the hub

      await tapKey(tester, 'bag-choice-add');
      await tester.enterText(find.byKey(const ValueKey('bag-choice-name:3')), 'Forks');
      t.hub.refuseBag = 'a choice is at most 24 characters';
      await tapKey(tester, 'bag-save');
      expect(find.text('a choice is at most 24 characters'), findsOneWidget);
      expect(find.byType(BagQuestionDialog), findsOneWidget);
      // eight choices at most: the button to add one goes off
      for (var n = 0; n < 7; n++) {
        await tapKey(tester, 'bag-choice-add');
      }
      expect(enabled(tester, 'bag-choice-add'), isFalse);
      await stop(tester);
    });

    testWidgets('a hub older than the question says so on the row', (tester) async {
      await pumpLocation(tester);
      expect(rowWords(tester), 'The hub has not answered about the to-go question (an older hub: update it)');
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('to-go-question'))).onTap, isNull);
      await stop(tester);
    });

    testWidgets('on a 320-wide phone the dialog fits with eight choices', (tester) async {
      await pumpLocation(
        tester,
        size: const Size(320, 568),
        question: {
          'enabled': true,
          'question': 'Chopsticks, forks, napkins or any of the sauces in the bag?',
          'choices': [
            for (var n = 0; n < 8; n++) {'id': 'c$n', 'name': 'Extra fortune cookies $n'},
          ],
        },
      );
      await tapKey(tester, 'to-go-question');
      expect(find.byType(BagQuestionDialog), findsOneWidget);
      await tapKey(tester, 'bag-choice-remove:7');
      await tapKey(tester, 'bag-enabled');
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });
}
