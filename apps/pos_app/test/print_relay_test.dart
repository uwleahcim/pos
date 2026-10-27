import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/print_relay.dart';
import 'package:pos_app/settings.dart';

/// A backend with one printer and a queue of jobs that relays claim, finish or fail.
class FakePrintBackend {
  final List<Map<String, dynamic>> queued = [];
  final Map<String, String> doneBy = {};
  final List<String> failures = [];
  String? leased;

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (path == '/print/printers') {
      return http.Response(
        jsonEncode({
          'printers': [
            {'name': 'kitchen', 'address': '127.0.0.1:9100', 'dialect': 'escpos'},
          ],
          'direct': false,
        }),
        200,
      );
    }
    if (path == '/print/jobs/claim') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (leased != null || queued.isEmpty || !(body['printers'] as List).contains('127.0.0.1:9100')) {
        return http.Response(jsonEncode({'job': null}), 200);
      }
      leased = body['relay'] as String;
      return http.Response(jsonEncode({'job': queued.first}), 200);
    }
    final done = RegExp(r'^/print/jobs/(.+)/done$').firstMatch(path);
    if (done != null) {
      doneBy[done[1]!] = (jsonDecode(request.body) as Map)['by'] as String;
      queued.removeWhere((j) => j['job_id'] == done[1]);
      leased = null;
      return http.Response('{}', 200);
    }
    final failed = RegExp(r'^/print/jobs/(.+)/failed$').firstMatch(path);
    if (failed != null) {
      failures.add((jsonDecode(request.body) as Map)['error'] as String);
      leased = null;
      return http.Response('{}', 200);
    }
    return http.Response('{"detail":"nope"}', 404);
  });
}

void main() {
  final settings = Settings(device: 'ipad1', endpoints: ['http://hub:8000'], printRelay: true);
  final job = {
    'job_id': 'f:kitchen',
    'printer': '127.0.0.1:9100',
    'data_b64': base64Encode([27, 64, 65, 10]),
  };

  test('a claimed job is written to the printer and reported done', () async {
    final backend = FakePrintBackend()..queued.add(job);
    final api = PosApi(settings, client: backend.client());
    final sent = <(String, Uint8List)>[];
    final relay = PrintRelay(api, settings, send: (address, data) async => sent.add((address, data)));

    expect(await relay.poll(), isTrue);
    expect(sent.single.$1, '127.0.0.1:9100');
    expect(sent.single.$2, [27, 64, 65, 10]);
    expect(backend.doneBy, {'f:kitchen': 'ipad1'});
    expect(relay.printed, 1);
    expect(await relay.poll(), isFalse); // queue empty now
  });

  test('a printer that cannot be reached sends the job back to the queue', () async {
    final backend = FakePrintBackend()..queued.add(job);
    final api = PosApi(settings, client: backend.client());
    final relay = PrintRelay(api, settings, send: (address, data) async => throw Exception('no route'));

    expect(await relay.poll(), isFalse);
    expect(backend.failures.single, contains('no route'));
    expect(backend.doneBy, isEmpty);
    expect(relay.failed, 1);
    expect(relay.lastError, contains('no route'));
    expect(backend.leased, isNull); // free for the next relay
  });

  test('the relay follows the setting', () async {
    final backend = FakePrintBackend();
    final api = PosApi(settings, client: backend.client());
    final own = Settings(device: 'mac1', endpoints: ['http://hub:8000']);
    final relay = PrintRelay(api, own, send: (a, d) async {})..bind();
    expect(relay.running, isFalse);
    await own.save(device: 'mac1', endpoints: ['http://hub:8000'], printRelay: true);
    expect(relay.running, isTrue);
    await own.save(device: 'mac1', endpoints: ['http://hub:8000'], printRelay: false);
    expect(relay.running, isFalse);
    relay.dispose();
  });

  test('a real socket receives the bytes and the status reply does not break the send', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final payload = server.first.then((socket) async {
      socket.add([0, 0, 0, 0]); // status bytes, unasked, like a Star
      final bytes = <int>[];
      await for (final chunk in socket) {
        bytes.addAll(chunk);
      }
      await socket.close();
      await server.close();
      return bytes;
    });
    await sendRaw('127.0.0.1:${server.port}', Uint8List.fromList([1, 2, 3]));
    expect(await payload, [1, 2, 3]);
  });
}
