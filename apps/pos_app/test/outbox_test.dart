import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/outbox.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A pretend backend at one or more addresses; each address can be up or down.
class FakeBackend {
  final Map<String, bool> up = {};
  final Map<String, List<Map<String, dynamic>>> seen = {};
  final Set<String> ids = {};

  http.Client client() => MockClient((request) async {
    final base = '${request.url.scheme}://${request.url.host}:${request.url.port}';
    if (!(up[base] ?? false)) throw http.ClientException('connection refused', request.url);
    if (request.url.path == '/health') return http.Response(jsonEncode({'status': 'ok', 'cursor': ids.length}), 200);
    if (request.url.path == '/orders') {
      return http.Response(jsonEncode({'orders': [], 'cursor': ids.length}), 200);
    }
    if (request.method == 'POST') {
      final ops = (jsonDecode(request.body) as List).cast<Map<String, dynamic>>();
      final accepted = <String>[];
      for (final op in ops) {
        if (op['kind'] == 'bogus') {
          return http.Response(
            jsonEncode({
              'detail': {'error': 'unknown_kind', 'op_id': op['op_id']},
            }),
            422,
          );
        }
        if (ids.add(op['op_id'] as String)) {
          accepted.add(op['op_id'] as String);
          seen.putIfAbsent(base, () => []).add(op);
        }
      }
      return http.Response(jsonEncode({'accepted': accepted, 'cursor': ids.length}), 202);
    }
    return http.Response('{"detail":"no such order"}', 404);
  });
}

Future<(Settings, PosApi, Outbox, FakeBackend)> harness({List<String> endpoints = const ['http://hub1:8000']}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = Settings(device: 't1', endpoints: endpoints, prefs: prefs);
  final backend = FakeBackend();
  final api = PosApi(settings, client: backend.client(), timeout: const Duration(milliseconds: 200));
  final outbox = Outbox(api, settings, prefs: prefs);
  return (settings, api, outbox, backend);
}

void main() {
  test('clock stamps are monotonic and formatted for the backend', () {
    var t = 1000;
    final clock = Hlc(node: 't1', now: () => t);
    expect(clock.next(), '0000000001000-0000-t1');
    expect(clock.next(), '0000000001000-0001-t1');
    t = 999; // wall clock went backwards: the counter keeps order
    expect(clock.next(), '0000000001000-0002-t1');
    t = 2000;
    expect(clock.next(), '0000000002000-0000-t1');
  });

  test('ops reach the backend and leave the queue', () async {
    final (_, _, outbox, backend) = await harness();
    backend.up['http://hub1:8000'] = true;
    await outbox.add('o1', 'create', {'table': 4});
    await outbox.flush();
    expect(outbox.pending, 0);
    expect(backend.seen['http://hub1:8000']!.single['kind'], 'create');
  });

  test('ops wait on disk while every backend is down, then go out on reconnect', () async {
    final (_, api, outbox, backend) = await harness();
    await outbox.add('o1', 'create', {'table': 4});
    await outbox.add('o1', 'add_line', {'line_id': 'L1', 'item': 'Tsingtao', 'qty': 2});
    await outbox.flush();
    expect(outbox.pending, 2);
    expect(api.connection.value.isOnline, isFalse);

    // A fresh outbox (the app restarted) restores the same queue from disk.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('outbox')!.length, 2);

    backend.up['http://hub1:8000'] = true;
    await outbox.flush();
    expect(outbox.pending, 0);
    expect(api.connection.value.endpoint, 'http://hub1:8000');
    expect(backend.seen['http://hub1:8000']!.map((op) => op['kind']), ['create', 'add_line']);
    expect(prefs.getStringList('outbox'), isEmpty);
  });

  test('failover: the standby takes the ops when the hub is down, the hub again when it returns', () async {
    final (_, api, outbox, backend) = await harness(endpoints: ['http://hub1:8000', 'http://cloud:8000']);
    backend.up['http://cloud:8000'] = true;
    await outbox.add('o1', 'create', {'table': 1});
    await outbox.flush();
    expect(api.connection.value.endpoint, 'http://cloud:8000');
    expect(backend.seen['http://cloud:8000']!.length, 1);

    backend.up['http://hub1:8000'] = true;
    backend.up['http://cloud:8000'] = false;
    await outbox.add('o1', 'fire', {'course': '*'});
    await outbox.flush();
    expect(api.connection.value.endpoint, 'http://hub1:8000');
    expect(backend.seen['http://hub1:8000']!.single['kind'], 'fire');
  });

  test('a refused op is dropped with its reason and does not block the rest', () async {
    final (_, _, outbox, backend) = await harness();
    backend.up['http://hub1:8000'] = true;
    await outbox.add('o1', 'bogus');
    await outbox.add('o2', 'create', {'table': 2});
    await outbox.flush();
    expect(outbox.pending, 0);
    expect(outbox.lastRefusal, 'unknown_kind');
    expect(backend.seen['http://hub1:8000']!.single['order_id'], 'o2');
  });

  test('orders are read as the backend reports them', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(device: 't1', endpoints: const ['http://hub1:8000']);
    final api = PosApi(
      settings,
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'order_id': 'o1',
            'status': 'open',
            'fields': {'table': 4},
            'lines': {
              'L1': {'item': 'Tsingtao', 'qty': 2, 'status': 'active', 'note': '', 'modified_after_fire': true},
              'L2': {'item': 'Rolls', 'qty': 1, 'status': 'void', 'void_reason': 'oops'},
            },
            'fired': {'*': '0000000001000-0000-t1'},
          }),
          200,
        );
      }),
    );
    final order = await api.order('o1');
    expect(order.table, '4');
    expect(order.isFired, isTrue);
    expect(order.activeLines.single.item, 'Tsingtao');
    expect(order.activeLines.single.modifiedAfterFire, isTrue);
    expect(order.lines.where((l) => l.isVoid).single.item, 'Rolls');
  });

  test('settings normalise the device name and the addresses', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(device: '', endpoints: const [], prefs: await SharedPreferences.getInstance());
    await settings.save(device: 'bar-1', endpoints: ['172.19.1.179:8000/', '', ' https://pos.example.com ']);
    expect(settings.device, 'bar1');
    expect(settings.endpoints, ['http://172.19.1.179:8000', 'https://pos.example.com']);
    expect(settings.isConfigured, isTrue);
  });
}
