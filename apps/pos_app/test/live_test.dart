import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pos_app/api.dart';
import 'package:pos_app/live.dart';
import 'package:pos_app/settings.dart';

import 'hub.dart';

/// The hub's change feed as the app holds it: what it tells the screens, and what it does when the hub goes
/// quiet, restarts, is older than the feed, or the terminal moves to the standby.
void main() {
  (LiveHub, PosApi) device({List<String> endpoints = const ['http://hub:8000']}) {
    final live = LiveHub(Hub());
    final api = PosApi(
      Settings(device: 't1', endpoints: endpoints),
      client: live.client,
    );
    addTearDown(live.close);
    return (live, api);
  }

  /// Every state the feed went through and every change it told, as the test runs.
  (List<LiveState>, List<LiveChange>) watch(PosApi api) {
    final states = <LiveState>[];
    final changes = <LiveChange>[];
    api.live.addListener(() => states.add(api.live.state));
    api.live.changes.listen(changes.add);
    return (states, changes);
  }

  test('the feed opens on the backend that answers and tells what the hub says changed', () {
    fakeAsync((async) {
      final (hub, api) = device();
      final (states, changes) = watch(api);
      api.live.start();
      async.flushMicrotasks();
      expect((api.live.state, hub.opened), (LiveState.off, 0)); // no backend has answered anything yet

      unawaited(api.health());
      async.flushMicrotasks();
      expect((api.live.state, hub.opened), (LiveState.connecting, 1));
      expect(hub.asked!.url.toString(), 'http://hub:8000/live?device=t1');
      expect(hub.asked!.headers['accept'], 'text/event-stream');
      expect(hub.asked!.headers['accept-encoding'], 'identity'); // compressed, a line would wait for the next

      hub.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);
      expect(changes.single.everything, isTrue); // whatever changed before: every screen reads once

      hub.changed(orders: ['o1', 'o2']);
      hub.changed(topics: ['menu']);
      hub.changed(topics: ['settings', 'something-newer']);
      hub.changed(everything: true);
      async.flushMicrotasks();
      final [_, orders, menu, settings, everything] = changes;
      expect(orders.orders, {'o1', 'o2'});
      expect((orders.menu, orders.everything), (false, false));
      expect((orders.touches('o1'), orders.touches('o9'), orders.anyOrder), (true, false, true));
      expect((menu.menu, menu.anyOrder, menu.touches('o1')), (true, false, false));
      expect((settings.settings, settings.anyOrder, settings.menu), (true, true, false));
      expect((everything.touches('o9'), everything.anyOrder), (true, true));
      expect(states, [LiveState.connecting, LiveState.live]);

      api.dispose();
      async.flushMicrotasks();
      expect(hub.hungUp, 1);
    });
  });

  test('a hub that keeps writing stays live; one that goes quiet is given up on and asked for again', () {
    fakeAsync((async) {
      final (hub, api) = device();
      final (states, changes) = watch(api);
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      hub.hello();
      async.flushMicrotasks();
      for (var second = 0; second < 30; second++) {
        async.elapse(const Duration(seconds: 1));
        hub.beat();
      }
      expect((api.live.isLive, hub.opened), (true, 1));

      // The hub's machine loses power: nothing closes the connection, it just goes quiet. Three heartbeats
      // missed and the feed is no longer live (the screens ask again), the backends are asked for their health
      // at once, and the feed is opened again after a second.
      hub.hub.requests.clear();
      async.elapse(const Duration(milliseconds: 2900));
      expect(api.live.isLive, isTrue);
      async.elapse(const Duration(milliseconds: 200));
      expect((api.live.state, hub.hungUp), (LiveState.connecting, 1));
      expect(hub.hub.requests, ['GET /health']);
      async.elapse(const Duration(seconds: 1));
      expect(hub.opened, 2);
      hub.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);
      expect(changes.where((c) => c.everything), hasLength(2)); // connected again: every screen reads once
      expect(states, [LiveState.connecting, LiveState.live, LiveState.connecting, LiveState.live]);
      api.dispose();
    });
  });

  test('a hub that restarts is found again, waiting longer while it stays away', () {
    fakeAsync((async) {
      final (hub, api) = device();
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      hub.hello();
      async.flushMicrotasks();

      hub.down = true;
      hub.drop(); // the hub closes its streams as it stops
      async.flushMicrotasks();
      expect(api.live.isLive, isFalse);
      expect(api.connection.value.isOnline, isFalse); // asked for its health at once: the outage shows now
      expect(api.live.state, LiveState.off);

      // Nothing is opened while no backend answers; the screens' own asking finds the hub when it is back.
      async.elapse(const Duration(seconds: 30));
      expect(hub.opened, 1);
      hub.down = false;
      unawaited(api.health());
      async.flushMicrotasks();
      expect((hub.opened, api.live.state), (2, LiveState.connecting));
      hub.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);

      // A feed that keeps ending on a backend that otherwise answers is tried at 1, 2, 4, 8, 8 seconds.
      final waits = <int>[];
      for (var round = 0; round < 5; round++) {
        final before = hub.opened;
        hub.drop();
        async.flushMicrotasks();
        var waited = 0;
        while (hub.opened == before) {
          async.elapse(const Duration(seconds: 1));
          waited += 1;
        }
        waits.add(waited);
      }
      expect(waits, [1, 2, 4, 8, 8]);
      hub.hello(); // and a hello starts the count over
      async.flushMicrotasks();
      hub.drop();
      async.elapse(const Duration(seconds: 1));
      expect(hub.opened, 8);
      api.dispose();
    });
  });

  test('a hub from before the feed is left to be polled, and asked again a minute later', () {
    fakeAsync((async) {
      final (hub, api) = device();
      final (_, changes) = watch(api);
      hub.refuse = 404;
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      expect((api.live.state, api.live.isLive, hub.opened), (LiveState.unsupported, false, 0));
      hub.hub.requests.clear();
      async.elapse(const Duration(seconds: 59));
      expect(hub.hub.requests, isEmpty); // not asked for its health, not hammered
      async.elapse(const Duration(seconds: 1));
      expect(hub.hub.requests, ['GET /live']);
      expect(api.live.state, LiveState.unsupported);

      hub.refuse = null; // the hub was updated meanwhile
      async.elapse(const Duration(minutes: 1));
      hub.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);
      expect(changes.single.everything, isTrue);
      api.dispose();
    });
  });

  test('the feed follows the terminal to the standby when the hub dies', () {
    fakeAsync((async) {
      final first = LiveHub(Hub()), second = LiveHub(Hub(), base: 'http://hub2:8000');
      addTearDown(first.close);
      addTearDown(second.close);
      final hubs = {'hub': first, 'hub2': second};
      final api = PosApi(
        Settings(device: 't1', endpoints: const ['http://hub:8000', 'http://hub2:8000']),
        client: _Routed(hubs),
      );
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      first.hello();
      async.flushMicrotasks();
      expect((api.live.isLive, first.opened, second.opened), (true, 1, 0));

      first.down = true; // power cut: the stream just goes quiet
      async.elapse(const Duration(milliseconds: 3100));
      async.flushMicrotasks();
      // Its silence was noticed, its health asked for, the standby answered: the feed is opened there at once.
      expect(api.connection.value.endpoint, 'http://hub2:8000');
      expect((first.hungUp, second.opened, api.live.state), (1, 1, LiveState.connecting));
      second.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);
      async.elapse(const Duration(seconds: 2));
      second.beat();
      async.elapse(const Duration(seconds: 2));
      expect((api.live.isLive, second.opened, first.opened), (true, 1, 1)); // no second feed, no stray retry
      api.dispose();
    });
  });

  test('what was found out about one backend is not held against the next', () {
    fakeAsync((async) {
      final old = LiveHub(Hub())..refuse = 404, updated = LiveHub(Hub(), base: 'http://hub2:8000');
      addTearDown(old.close);
      addTearDown(updated.close);
      final api = PosApi(
        Settings(device: 't1', endpoints: const ['http://hub:8000', 'http://hub2:8000']),
        client: _Routed({'hub': old, 'hub2': updated}),
      );
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      expect(api.live.state, LiveState.unsupported);
      old.down = true; // the older hub goes away: the next call finds the standby, which has the feed
      unawaited(api.health());
      async.flushMicrotasks();
      expect(
        (api.connection.value.endpoint, api.live.state, updated.opened),
        ('http://hub2:8000', LiveState.connecting, 1),
      );
      updated.hello();
      async.flushMicrotasks();
      expect(api.live.isLive, isTrue);
      async.elapse(const Duration(minutes: 2));
      expect(old.hub.requests.where((r) => r == 'GET /live'), hasLength(1)); // the old hub's retry went with it
      api.dispose();
    });
  });

  test('back in front after a sleep the feed is opened afresh', () {
    fakeAsync((async) {
      final (hub, api) = device();
      final (_, changes) = watch(api);
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      hub.hello();
      async.flushMicrotasks();
      api.live.wake();
      async.flushMicrotasks();
      expect((hub.hungUp, hub.opened, api.live.isLive), (1, 2, false));
      hub.hello();
      async.flushMicrotasks();
      expect((api.live.isLive, changes.length), (true, 2));
      api.dispose();
    });
  });

  test('a feed that was never started is not live: every screen polls as before', () {
    final (hub, api) = device();
    expect((api.live.isLive, api.live.state), (false, LiveState.off));
    final poll = SafetyPoll(api.live);
    expect([for (var tick = 0; tick < 5; tick++) poll.due()], everyElement(isTrue));
    expect(hub.opened, 0);
    api.dispose();
  });

  test('under a live feed a screen asks by itself only every fifteenth tick', () {
    fakeAsync((async) {
      final (hub, api) = device();
      api.live.start();
      unawaited(api.health());
      async.flushMicrotasks();
      hub.hello();
      async.flushMicrotasks();
      final poll = SafetyPoll(api.live);
      final due = [
        for (var tick = 1; tick <= 45; tick++)
          if (poll.due()) tick,
      ];
      expect(due, [15, 30, 45]);
      // a read for any other reason starts the count over
      for (var tick = 0; tick < 10; tick++) {
        poll.due();
      }
      poll.asked();
      expect(
        [
          for (var tick = 1; tick <= 15; tick++)
            if (poll.due()) tick,
        ],
        [15],
      );
      // and the moment the feed is not live, every tick asks again
      hub.drop();
      async.flushMicrotasks();
      expect(poll.due(), isTrue);
      api.dispose();
    });
  });

  group('a paced reader', () {
    test('reads at once when told after a quiet spell, and once more for a burst', () {
      fakeAsync((async) {
        var reads = 0;
        final reader = Paced(const Duration(seconds: 1), () async => reads++);
        reader();
        async.flushMicrotasks();
        expect(reads, 1);
        for (var i = 0; i < 10; i++) {
          reader();
        }
        async.elapse(const Duration(milliseconds: 900));
        expect(reads, 1);
        async.elapse(const Duration(milliseconds: 100));
        expect(reads, 2);
        async.elapse(const Duration(seconds: 5));
        expect(reads, 2); // told nothing more: reads nothing more
        reader();
        async.flushMicrotasks();
        expect(reads, 3);
      });
    });

    test('never reads twice at a time, and a change told during a read is read after it', () {
      fakeAsync((async) {
        final answers = <Completer<void>>[];
        final reader = Paced(const Duration(milliseconds: 250), () {
          answers.add(Completer<void>());
          return answers.last.future;
        });
        reader();
        reader(); // told again while the first read is still out
        unawaited(reader.now(must: false)); // the timer comes round: the read under way will do
        async.elapse(const Duration(seconds: 3));
        expect(answers, hasLength(1));
        answers.first.complete();
        async.flushMicrotasks();
        expect(answers, hasLength(2)); // what it was told meanwhile
        answers.last.complete();
        async.elapse(const Duration(seconds: 3));
        expect(answers, hasLength(2));

        // asked outright, it reads whatever the gap; asked outright during a read, once more after it
        unawaited(reader.now());
        unawaited(reader.now());
        async.flushMicrotasks();
        expect(answers, hasLength(3));
        answers.last.complete();
        async.elapse(const Duration(milliseconds: 250));
        expect(answers, hasLength(4));
        answers.last.complete();

        reader.cancel();
        reader();
        unawaited(reader.now());
        async.elapse(const Duration(seconds: 3));
        expect(answers, hasLength(4));
      });
    });
  });
}

/// Two pretend hubs behind one client, by host name.
class _Routed extends http.BaseClient {
  _Routed(this.hubs);
  final Map<String, LiveHub> hubs;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      hubs[request.url.host]!.handle(request, request.finalize());
}
