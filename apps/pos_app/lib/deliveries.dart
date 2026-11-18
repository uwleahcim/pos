/// The deliveries (docs/delivery.md): the open orders that are brought to the customer, sorted the way
/// whoever hands the bags out thinks of them. The ones that have not left yet, and for each driver what
/// they have out. Worked out from the open orders the hub lists; nothing here is kept.
library;

import 'api.dart';
import 'roster.dart';
import 'takeout.dart';
import 'to_go_stages.dart';

/// Where a delivery that has not left stands.
enum Waiting {
  /// Packed: it can go.
  ready,

  /// With the kitchen. It can be handed over all the same: bags leave without anybody tapping Ready.
  cooking,

  /// For a time the customer named, and the kitchen has not started it; or still being rung up.
  later,
}

/// Where [order], a delivery that has not left, stands at [now].
Waiting waitingStage(Order order, DateTime now) {
  if (order.stage == 'ready') return Waiting.ready;
  if (!order.isFired || waitsForItsTime(order, now)) return Waiting.later;
  return Waiting.cooking;
}

/// Whether a delivery that has not left can be handed to a driver: the kitchen has it, or it is packed.
bool canLeave(Order order, DateTime now) => waitingStage(order, now) != Waiting.later;

/// What a delivery that has not left says of itself: "READY", "cooking", "for tomorrow 12:00", "not sent
/// yet".
String waitingWords(Order order, DateTime now) => switch (waitingStage(order, now)) {
  Waiting.ready => 'READY',
  Waiting.cooking => 'cooking',
  Waiting.later => switch (order.promisedAt) {
    final at? when order.forLater => 'for ${whenFor(at, now)}',
    _ => 'not sent yet',
  },
};

/// What one driver has out, the bag that left first at the top.
class DriverLoad {
  const DriverLoad({required this.driverId, required this.name, required this.orders});

  final String driverId;
  final String name;
  final List<Order> orders;

  /// When the first of them left (ms), if any said so.
  int? get since => orders.map((o) => o.outAt).whereType<int>().fold<int?>(null, (a, b) => a == null || b < a ? b : a);
}

/// The open deliveries: [waiting] to leave (the packed ones first, then by the time promised) and [out]
/// by driver (whoever has been out the longest first).
class Deliveries {
  const Deliveries({this.waiting = const [], this.out = const []});

  final List<Order> waiting;
  final List<DriverLoad> out;

  bool get isEmpty => waiting.isEmpty && out.isEmpty;

  /// How many bags are out, with all the drivers together.
  int get outCount => out.fold(0, (n, load) => n + load.orders.length);

  /// How many bags [staffId] has out: what the picker says under a driver's name.
  int has(String staffId) => out.where((load) => load.driverId == staffId).fold(0, (n, load) => n + load.orders.length);

  /// The loads with [staffId]'s own first: a driver looks for theirs.
  List<DriverLoad> mineFirst(String? staffId) => [
    for (final load in out)
      if (load.driverId == staffId) load,
    for (final load in out)
      if (load.driverId != staffId) load,
  ];
}

int _byPromise(Order a, Order b) {
  final at = (a.promisedAt ?? 0).compareTo(b.promisedAt ?? 0);
  return at != 0 ? at : (a.orderNo ?? 0).compareTo(b.orderNo ?? 0);
}

/// Sorts the open [orders] into the deliveries waiting to leave and the ones out with each driver. An
/// order the customer comes for, a table's check and a closed order are none of them.
Deliveries deliveriesOf(Iterable<Order> orders, DateTime now) {
  final waiting = <Order>[];
  final byDriver = <String, List<Order>>{};
  for (final order in orders) {
    if (!order.isDelivery || !order.isOpen || order.stage == 'picked_up') continue;
    if (order.isOut) {
      // one handed over by a screen that named nobody is still out: it is listed under no name
      byDriver.putIfAbsent(order.driverId, () => []).add(order);
    } else {
      waiting.add(order);
    }
  }
  waiting.sort((a, b) {
    final stage = waitingStage(a, now).index.compareTo(waitingStage(b, now).index);
    return stage != 0 ? stage : _byPromise(a, b);
  });
  final out = [
    for (final MapEntry(key: id, value: has) in byDriver.entries)
      DriverLoad(
        driverId: id,
        name: has.first.driver,
        orders: has
          ..sort((a, b) {
            final left = (a.outAt ?? 0).compareTo(b.outAt ?? 0);
            return left != 0 ? left : _byPromise(a, b);
          }),
      ),
  ]..sort((a, b) => (a.since ?? 0).compareTo(b.since ?? 0));
  return Deliveries(waiting: waiting, out: out);
}

/// The fields that hand a delivery to [driver] at [at] (ms): it is out, with whom, and since when. Bags
/// handed over in one go carry the same [at]: that is one run.
Map<String, dynamic> outFields(StaffMember driver, int at) => {
  'stage': 'out',
  'driver': driver.name,
  'driver_id': driver.staffId,
  'out_at': at,
};

/// The fields that take a delivery back from its driver: it is ready again, and nobody's.
const backFields = <String, dynamic>{'stage': 'ready', 'driver': null, 'driver_id': null};

/// How long ago [ms] was at [now], for a bag that is out: "just now", "12 min", "1 h 05".
String outFor(int ms, DateTime now) {
  final minutes = now.difference(DateTime.fromMillisecondsSinceEpoch(ms)).inMinutes;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}
