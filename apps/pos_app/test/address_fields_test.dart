import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/address_list.dart';
import 'package:pos_app/address_parts.dart';
import 'package:pos_app/screens/address_fields.dart';

import 'address_list_test.dart' show inBox, lines, type;
import 'catering_test.dart' show dataOf, enabled, tapKey;
import 'delivery_distance_test.dart' show said;
import 'delivery_fee_test.dart' show carried, delivery, pumpForm, pumpOrder;
import 'delivery_test.dart' show addressBoxes, addressOn, addressParts, created, elm, key, label, typed;
import 'hub.dart';

/// A delivery's address in its parts (docs/delivery.md, "The address in its parts"): five boxes where
/// there was one, the street's with the list of addresses under it, and a tap on a line of that list
/// filling every one of them. The order carries one line as it always did, so these tests are about the
/// boxes and the line they write; how a line reads into parts is address_parts_test.dart, and what the hub
/// says of a line's parts backend/tests/orders/test_address_list.py.

const medfordRef = 'ChIJ-medford';

/// Elm Street in Medford as Google lists it: no ZIP, and its own name for the place to ask it by.
Map<String, dynamic> get medford => Hub.addressLine(
  '12 Elm Street, Medford, MA',
  from: 'google',
  main: '12 Elm Street',
  rest: 'Medford, MA',
  ref: medfordRef,
);

/// The same street as Mapbox lists it: every part told apart, the ZIP among them.
Map<String, dynamic> get medfordWhole => Hub.addressLine(
  '12 Elm Street, Medford, Massachusetts 02155, United States',
  from: 'mapbox',
  main: '12 Elm Street',
  rest: 'Medford, Massachusetts 02155, United States',
  parts: const {'street': '12 Elm Street', 'unit': '', 'city': 'Medford', 'state': 'MA', 'zip': '02155'},
);

const medfordParts = {'street': '12 Elm St', 'unit': '', 'city': 'Medford', 'state': 'MA', 'zip': '02155'};

/// A hub's list for "12 el": the customer's own address, and Medford from Google and from Mapbox.
Map<String, List<Map<String, dynamic>>> get lists => {
  '12 el': [Hub.addressLine(elm, from: 'customer'), medford, medfordWhole],
};

/// The boxes by themselves over a hub, with another box under them to leave them for, and what they told
/// the form around them.
class Fields {
  Fields(this.t);

  final Terminal t;
  final address = TextEditingController();
  int changed = 0;
  int done = 0;
  int left = 0;

  /// The line the form held each time it was told the address is done.
  final doneWith = <String>[];
}

Future<Fields> pumpFields(
  WidgetTester tester, {
  String line = '',
  String home = '',
  double width = 400,
  double type = 1,
  bool asks = true,
}) async {
  final t = await terminal(tester);
  t.hub
    ..addressLists = lists
    ..addressWholes = {medfordRef: medfordParts};
  final fields = Fields(t)..address.text = line;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(type)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AddressFields(
                    address: fields.address,
                    source: t.api.suggestAddresses,
                    whole: asks ? t.api.wholeAddress : null,
                    homeState: home,
                    onChanged: () => fields.changed++,
                    onDone: () {
                      fields.done++;
                      fields.doneWith.add(fields.address.text);
                    },
                    onLeft: () => fields.left++,
                  ),
                  const TextField(key: ValueKey('other')),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fields;
}

Future<void> enter(WidgetTester tester, String box, String text) async {
  await tester.enterText(key(box), text);
  await tester.pump();
}

/// Enter on the keyboard of the box the typing is in.
Future<void> pressEnter(WidgetTester tester, String box, {TextInputAction action = TextInputAction.next}) async {
  await tester.showKeyboard(key(box));
  await tester.testTextInput.receiveAction(action);
  await tester.pumpAndSettle();
}

const street = 'event-address';
const unit = 'event-address:unit';
const city = 'event-address:city';
const state = 'event-address:state';
const zip = 'event-address:zip';

void main() {
  group('the line the boxes write', () {
    testWidgets('each box is a part of the one line the order carries', (tester) async {
      final fields = await pumpFields(tester);
      expect(addressParts(tester), ['', '', '', '', '']);
      expect(
        [for (final box in addressBoxes) label(tester, box)],
        ['Deliver to', 'Apt / unit', 'City', 'State', 'ZIP'],
      );
      await enter(tester, street, '12 Elm St');
      expect(fields.address.text, '12 Elm St');
      await enter(tester, city, 'Winchester');
      expect(fields.address.text, '12 Elm St, Winchester');
      await enter(tester, unit, '3B');
      expect(fields.address.text, '12 Elm St #3B, Winchester');
      await enter(tester, state, 'ma');
      expect(typed(tester, state), 'MA'); // two capitals, however it is typed
      await enter(tester, zip, '01890');
      expect(fields.address.text, '12 Elm St #3B, Winchester, MA 01890');
      expect(fields.changed, 5);
      // a unit said by its word is written by its word
      await enter(tester, unit, 'Apt 3B');
      expect(fields.address.text, '12 Elm St Apt 3B, Winchester, MA 01890');
      // and the line reads back into the same boxes
      expect(AddressParts.parse(fields.address.text).unit, 'Apt 3B');
      expect((fields.done, fields.left), (0, 0));
    });

    testWidgets('the state takes two letters and the ZIP its digits', (tester) async {
      await pumpFields(tester);
      await enter(tester, state, 'm4a ss');
      expect(typed(tester, state), 'MA');
      await enter(tester, zip, '0189o0-1234x');
      expect(typed(tester, zip), '01890-1234');
    });

    testWidgets('the whole line is never longer than an order takes', (tester) async {
      final fields = await pumpFields(tester);
      await enter(tester, city, 'Winchester');
      await enter(tester, zip, '01890');
      await enter(tester, street, '12 ${'Elm ' * 80}St');
      expect(fields.address.text.length, 200);
      expect(fields.address.text, endsWith(', Winchester, 01890'));
      // a box that is full takes no more, and what is there can still be taken away
      await enter(tester, unit, '3B');
      expect(typed(tester, unit), '');
      await enter(tester, street, '12 Elm St');
      expect(fields.address.text, '12 Elm St, Winchester, 01890');
    });
  });

  group("the restaurant's own state", () {
    testWidgets('is in the box before anything is typed, and by itself it is no address', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      expect(addressParts(tester), ['', '', '', 'MA', '']);
      expect(fields.address.text, '');
      expect(fields.changed, 0);
      await enter(tester, street, '12 Elm St');
      await enter(tester, city, 'Winchester');
      expect(fields.address.text, '12 Elm St, Winchester, MA');
      // another state is typed over it, and it stays
      await enter(tester, state, 'NH');
      expect(fields.address.text, '12 Elm St, Winchester, NH');
    });

    testWidgets('an address the form already had keeps the state it names, or none', (tester) async {
      final fields = await pumpFields(tester, line: elm, home: 'MA');
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', '', '']);
      expect(fields.address.text, elm);
    });

    testWidgets('comes back when the form takes the address away', (tester) async {
      final fields = await pumpFields(tester, line: '4 Oak Rd, Nashua, NH 03060', home: 'MA');
      expect(addressParts(tester), ['4 Oak Rd', '', 'Nashua', 'NH', '03060']);
      fields.address.text = '';
      await tester.pump();
      expect(addressParts(tester), ['', '', '', 'MA', '']);
      expect(fields.address.text, '');
    });
  });

  group('a line from before there were boxes', () {
    testWidgets('reads into the boxes and stays as it was written until a box is changed', (tester) async {
      const old = '12 elm st., apt 3b, winchester ma';
      final fields = await pumpFields(tester, line: old);
      expect(addressParts(tester), ['12 elm st.', 'apt 3b', 'winchester', 'MA', '']);
      expect(fields.address.text, old);
      expect(fields.changed, 0);
      // a box changed: the line is written from the boxes
      await enter(tester, zip, '01890');
      expect(fields.address.text, '12 elm st. apt 3b, winchester, MA 01890');
      // and changed back: it is the line it was
      await enter(tester, zip, '');
      expect(fields.address.text, old);
    });

    testWidgets('that cannot be told apart stands in the street as it is', (tester) async {
      const old = 'the blue house behind the library';
      final fields = await pumpFields(tester, line: old, home: 'MA');
      expect(addressParts(tester), [old, '', '', '', '']);
      expect(fields.address.text, old);
    });

    testWidgets('the form putting another address in its box fills the boxes again', (tester) async {
      final fields = await pumpFields(tester, line: elm);
      fields.address.text = '4 Oak Rd #2, Woburn, MA 01801';
      await tester.pump();
      expect(addressParts(tester), ['4 Oak Rd', '2', 'Woburn', 'MA', '01801']);
      expect(fields.address.text, '4 Oak Rd #2, Woburn, MA 01801');
      expect(fields.changed, 0); // the form knows what it put there
    });
  });

  group('a tap on a line of the list', () {
    testWidgets('fills every box from an address of our own, and keeps its line as it was', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      await enter(tester, unit, '9');
      await enter(tester, zip, '99999');
      await type(tester, '12 el');
      expect(lines(tester), hasLength(3));
      await tapKey(tester, 'address-suggestion:0');
      // no box keeps what it held: the unit and the ZIP typed before are another address's
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', '', '']);
      expect(fields.address.text, elm);
      expect(lines(tester), isEmpty);
      expect(fields.doneWith, [elm]);
      expect(fields.t.hub.wholeAsks, isEmpty); // our own line has nothing more to ask
    });

    testWidgets('fills every box with the parts a map service told apart', (tester) async {
      final fields = await pumpFields(tester);
      await type(tester, '12 el');
      await tapKey(tester, 'address-suggestion:2');
      expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', '02155']);
      expect(fields.address.text, '12 Elm Street, Medford, MA 02155'); // no country, the state by its letters
      expect(fields.doneWith, ['12 Elm Street, Medford, MA 02155']);
      expect(fields.t.hub.wholeAsks, isEmpty);
    });

    testWidgets("asks the hub once for the ZIP that Google's list leaves out, and is done when it has it", (
      tester,
    ) async {
      final fields = await pumpFields(tester);
      fields.t.hub.wholeWaits = Completer<void>();
      await type(tester, '12 el');
      await tapKey(tester, 'address-suggestion:1');
      // what the line says is in the boxes at once
      expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', '']);
      expect(fields.address.text, '12 Elm Street, Medford, MA');
      expect(fields.t.hub.wholeAsks, [
        {'service': 'google', 'ref': medfordRef},
      ]);
      expect(fields.done, 0); // not done before the ZIP is there: the distance is asked once, of the whole
      fields.t.hub.wholeWaits!.complete();
      await tester.pumpAndSettle();
      // the ZIP is added; the street stays as the line said it
      expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', '02155']);
      expect(fields.doneWith, ['12 Elm Street, Medford, MA 02155']);
      expect(fields.t.hub.wholeAsks, hasLength(1));
    });

    testWidgets('typing on before the hub answered keeps what was typed', (tester) async {
      final fields = await pumpFields(tester);
      fields.t.hub.wholeWaits = Completer<void>();
      await type(tester, '12 el');
      await tapKey(tester, 'address-suggestion:1');
      await enter(tester, zip, '02');
      fields.t.hub.wholeWaits!.complete();
      await tester.pumpAndSettle();
      expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', '02']);
      expect(fields.done, 0); // nobody is done with an address that is still typed
    });

    testWidgets('keeps what the line said when the hub has no ZIP to give', (tester) async {
      for (final why in ['older', 'down', 'unknown', 'not asked']) {
        final fields = await pumpFields(tester, asks: why != 'not asked');
        if (why == 'older') fields.t.hub.addressWholes = null;
        if (why == 'unknown') fields.t.hub.addressWholes = {};
        await type(tester, '12 el');
        if (why == 'down') fields.t.hub.addressesDown = true;
        await tapKey(tester, 'address-suggestion:1');
        expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', ''], reason: why);
        expect(fields.doneWith, ['12 Elm Street, Medford, MA'], reason: why);
        expect(tester.takeException(), isNull, reason: why);
        await tester.pumpWidget(const SizedBox());
      }
    });

    test('a line says its parts and what more there is to ask', () {
      final whole = AddressSuggestion.of(medfordWhole)!;
      expect(whole.parts, const AddressParts(street: '12 Elm Street', city: 'Medford', state: 'MA', zip: '02155'));
      expect((whole.ref, whole.boxes), (null, whole.parts));
      final listed = AddressSuggestion.of(medford)!;
      expect((listed.parts, listed.ref), (null, medfordRef));
      expect(listed.boxes, const AddressParts(street: '12 Elm Street', city: 'Medford', state: 'MA'));
      // parts that name no street are none, and a name that is no text is none
      final odd = AddressSuggestion.of({
        ...medford,
        'parts': {'city': 'Medford'},
        'ref': 7,
      })!;
      expect((odd.parts, odd.ref), (null, null));
    });
  });

  group('a whole address typed in the first box', () {
    testWidgets('goes to its boxes when the box is left, and the line says the same before and after', (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      await enter(tester, street, '12 Elm St, Apt 3B, Winchester, MA 01890');
      // at every letter the order would carry the address, not the address and the state again
      expect(fields.address.text, '12 Elm St Apt 3B, Winchester, MA 01890');
      await tester.tap(key(city));
      await tester.pumpAndSettle();
      expect(addressParts(tester), ['12 Elm St', 'Apt 3B', 'Winchester', 'MA', '01890']);
      expect(fields.address.text, '12 Elm St Apt 3B, Winchester, MA 01890');
      expect(fields.left, 0); // from one of its boxes to another
    });

    testWidgets("with no state in it, it is in the restaurant's", (tester) async {
      final fields = await pumpFields(tester, home: 'MA');
      await enter(tester, street, '12 Elm St, Winchester');
      await tester.tap(key('other'));
      await tester.pumpAndSettle();
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', 'MA', '']);
      expect(fields.address.text, '12 Elm St, Winchester, MA');
      expect(fields.left, 1);
    });

    testWidgets('replaces the other boxes only when it is typed as far as its state or its ZIP', (tester) async {
      final fields = await pumpFields(tester, line: '12 Elm St #3B, Winchester, MA 01890');
      await enter(tester, street, '12 Elm St, side door');
      await tester.tap(key('other'));
      await tester.pumpAndSettle();
      expect(addressParts(tester), ['12 Elm St, side door', '3B', 'Winchester', 'MA', '01890']); // no new town
      await enter(tester, street, '4 Oak Rd, Woburn, MA 01801');
      await tester.tap(key('other'));
      await tester.pumpAndSettle();
      expect(addressParts(tester), ['4 Oak Rd', '', 'Woburn', 'MA', '01801']);
      expect(fields.address.text, '4 Oak Rd, Woburn, MA 01801');
    });
  });

  group('Enter', () {
    testWidgets('goes from box to box, and says the address is done once it can be found', (tester) async {
      final fields = await pumpFields(tester);
      await enter(tester, street, '12 Elm St');
      await pressEnter(tester, street);
      expect(inBox(tester, unit), isTrue);
      expect(fields.done, 0); // a street alone is nowhere yet
      await pressEnter(tester, unit);
      expect(inBox(tester, city), isTrue);
      await enter(tester, city, 'Winchester');
      await pressEnter(tester, city);
      expect(inBox(tester, state), isTrue);
      expect(fields.doneWith, ['12 Elm St, Winchester']); // a street and its town
      await pressEnter(tester, state);
      expect(inBox(tester, zip), isTrue);
      expect((fields.done, fields.left), (2, 0));
      await enter(tester, zip, '01890');
      await pressEnter(tester, zip, action: TextInputAction.done);
      expect(fields.doneWith.last, '12 Elm St, Winchester, 01890');
      expect((fields.done, fields.left), (3, 1)); // and the keyboard is put away, as after the one box
    });

    testWidgets('in the last box says so of whatever is typed, and in the first it closes the list', (tester) async {
      final fields = await pumpFields(tester);
      await type(tester, '12 el');
      expect(lines(tester), isNotEmpty);
      await pressEnter(tester, street);
      expect(lines(tester), isEmpty);
      expect((inBox(tester, unit), fields.done), (true, 0));
      await pressEnter(tester, zip, action: TextInputAction.done);
      expect(fields.doneWith, ['12 el']);
    });

    testWidgets('after a whole address in the first box, it is done with its parts', (tester) async {
      final fields = await pumpFields(tester);
      await enter(tester, street, '12 Elm St, Winchester, MA 01890');
      await pressEnter(tester, street);
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', 'MA', '01890']);
      expect(fields.doneWith, ['12 Elm St, Winchester, MA 01890']);
    });
  });

  group('where the boxes stand', () {
    testWidgets('on a phone: the street, then the unit and the town, then the state and the ZIP', (tester) async {
      await pumpFields(tester, width: 262);
      final [a, b, c, d, e] = [for (final box in addressBoxes) tester.getRect(key(box))];
      expect((a.left, a.right), (0, 262));
      expect(b.top, greaterThan(a.bottom));
      expect((b.top, b.left, c.right), (c.top, 0, 262));
      expect(d.top, greaterThan(b.bottom));
      expect((d.top, d.left, e.right), (e.top, 0, 262));
      expect(c.width, greaterThan(b.width)); // the town has more to say than the unit
      expect(e.width, greaterThan(d.width));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with more room: the unit beside the street, and the town, the state and the ZIP under them', (
      tester,
    ) async {
      await pumpFields(tester, width: 400);
      final [a, b, c, d, e] = [for (final box in addressBoxes) tester.getRect(key(box))];
      expect((a.top, a.left, b.right), (b.top, 0, 400));
      expect(c.top, greaterThan(a.bottom));
      expect((c.top, d.top, c.left, e.right), (d.top, e.top, 0, 400));
      expect(c.width, greaterThan(e.width));
      expect(e.width, greaterThan(d.width)); // two letters need the least
      // the list drops down under the street and the unit beside it, as wide as the form
      await type(tester, '12 el');
      final list = tester.getRect(key('address-list'));
      expect((list.left, list.right), (0, 400));
      expect(list.top, greaterThanOrEqualTo(a.bottom));
      // over the other boxes, which stay where they stood
      expect([for (final box in addressBoxes) tester.getRect(key(box))], [a, b, c, d, e]);
      expect(list.bottom, greaterThan(c.bottom));
      expect(key(city).hitTestable(), findsNothing);
      expect(key('address-suggestion:0').hitTestable(), findsOneWidget);
    });

    testWidgets('large type takes the lines it needs, and names the unit shortly', (tester) async {
      // a small phone's form: too narrow for "Apt / unit" at this size of type
      await pumpFields(tester, width: 201, type: 1.3);
      expect(label(tester, unit), 'Apt');
      final [a, b, c, d, e] = [for (final box in addressBoxes) tester.getRect(key(box))];
      expect((b.top, d.top), (c.top, e.top));
      expect(d.top, greaterThan(b.bottom));
      expect(b.top, greaterThan(a.bottom));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // room that is wide at the usual size is not at this one
      await pumpFields(tester, width: 400, type: 1.3);
      expect(tester.getRect(key(unit)).top, greaterThan(tester.getRect(key(street)).bottom));
      await tester.pumpWidget(const SizedBox());
      await pumpFields(tester, width: 400 * 1.3, type: 1.3);
      expect(tester.getRect(key(unit)).top, tester.getRect(key(street)).top);
      expect(tester.takeException(), isNull);
    });
  });

  group('the to-go form', () {
    Map<String, dynamic> fees() => {...Hub.mapFees, 'origin': '1 Restaurant Row, Winchester, MA 01890'};

    Future<Terminal> pumpDelivery(WidgetTester tester, {Size? size, double? type}) async {
      final t = await pumpForm(tester, fees: fees(), size: size, type: type);
      t.hub
        ..addressLists = lists
        ..addressWholes = {medfordRef: medfordParts}
        ..distances['12 Elm Street, Medford, MA 02155'] = const {'miles': '3.2', 'minutes': 9}
        ..distances['9 Main St #2, Woburn, MA'] = const {'miles': '1.6', 'minutes': 5};
      await tester.enterText(key('takeout-name'), 'Linda');
      await tapKey(tester, 'channel:phone');
      await tapKey(tester, 'handover:delivery');
      return t;
    }

    testWidgets("starts in the restaurant's state, and a delivery still needs somewhere to go", (tester) async {
      final t = await pumpDelivery(tester);
      expect(addressParts(tester), ['', '', '', 'MA', '']);
      expect(key('address-needed'), findsOneWidget);
      expect(enabled(tester, 'takeout-start'), isFalse);
      await enter(tester, street, '9 Main St');
      await enter(tester, unit, '2');
      await enter(tester, city, 'Woburn');
      expect(key('address-needed'), findsNothing);
      // Enter in the town's box: that is enough to find it by, and how far it is gets asked
      await pressEnter(tester, city);
      expect([for (final ask in t.hub.distanceAsks) ask['address']], ['9 Main St #2, Woburn, MA']);
      expect(said(tester, 'fee-lookup-found'), '1.6 mi · 5 min drive');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['address'], '9 Main St #2, Woburn, MA');
      await stop(tester);
    });

    testWidgets("a tap on Google's line fills the boxes, ZIP and all, and asks how far once", (tester) async {
      final t = await pumpDelivery(tester);
      await type(tester, '12 el');
      await tapKey(tester, 'address-suggestion:1');
      expect(addressParts(tester), ['12 Elm Street', '', 'Medford', 'MA', '02155']);
      expect(t.hub.wholeAsks, [
        {'service': 'google', 'ref': medfordRef},
      ]);
      expect([for (final ask in t.hub.distanceAsks) ask['address']], ['12 Elm Street, Medford, MA 02155']);
      expect(said(tester, 'fee-lookup-found'), '3.2 mi · 9 min drive');
      await tapKey(tester, 'takeout-start');
      expect(created(t.hub)['address'], '12 Elm Street, Medford, MA 02155');
      expect(t.hub.distanceAsks, hasLength(1));
      await stop(tester);
    });

    testWidgets('on a small phone with large type every box is there and nothing runs over', (tester) async {
      await pumpDelivery(tester, size: const Size(320, 568), type: 1.3);
      for (final box in addressBoxes) {
        await tester.ensureVisible(key(box));
        await tester.pumpAndSettle();
        expect(key(box).hitTestable(), findsOneWidget, reason: box);
      }
      expect(label(tester, unit), 'Apt');
      expect(tester.getRect(key(unit)).top, tester.getRect(key(city)).top);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });

    testWidgets('on a tablet the five boxes take two lines', (tester) async {
      await pumpDelivery(tester, size: const Size(1024, 768));
      expect(tester.getRect(key(unit)).top, tester.getRect(key(street)).top);
      expect(tester.getRect(key(city)).top, tester.getRect(key(zip)).top);
      expect(tester.takeException(), isNull);
      await stop(tester);
    });
  });

  group('the order', () {
    testWidgets('an address from before the boxes is saved as it was when only something else is changed', (
      tester,
    ) async {
      final t = await pumpOrder(tester, delivery(fee: carried('2', '3.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      expect(addressParts(tester), ['12 Elm St', '', 'Winchester', '', '']);
      await tester.enterText(key('event-note'), 'Leave it with the neighbour');
      await tester.pumpAndSettle();
      await tapKey(tester, 'when-save');
      final sent = dataOf(t.hub, 'set_field', 'o1');
      expect(sent['address'] ?? elm, elm);
      await stop(tester);
    });

    testWidgets('a unit added in its box is on the line the order carries', (tester) async {
      final t = await pumpOrder(tester, delivery(fee: carried('2', '3.00')), fees: Hub.mapFees);
      await tapKey(tester, 'when-strip');
      await enter(tester, unit, '3B');
      expect(addressOn(tester), '12 Elm St #3B, Winchester');
      await tapKey(tester, 'when-save');
      expect(dataOf(t.hub, 'set_field', 'o1')['address'], '12 Elm St #3B, Winchester');
      await stop(tester);
    });
  });
}
