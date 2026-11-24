import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/phone.dart';
import 'package:pos_app/push.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_test.dart' show active;

/// The hub's push registry as the app sees it: what it was sent, what it answers.
class PushHub {
  final puts = <Map<String, dynamic>>[];
  final deletes = <String>[];
  bool configured = true;
  bool down = false;

  Future<http.Response> handle(http.Request request) async {
    if (down) return http.Response('', 503);
    if (request.url.path == '/push/devices' && request.method == 'PUT') {
      puts.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true, 'configured': configured}), 200);
    }
    if (request.url.path.startsWith('/push/devices/') && request.method == 'DELETE') {
      deletes.add(request.url.path.split('/').last);
      return http.Response(jsonEncode({'ok': true, 'removed': true}), 200);
    }
    return http.Response('{}', 404);
  }
}

const voip = 'aaaaaaaaaaaaaaaa';
const alert = 'bbbbbbbbbbbbbbbb';

void main() {
  Future<(PushHub, Settings, PushRegistrar)> registrar({String platform = 'ios', bool phoneOn = true}) async {
    SharedPreferences.setMockInitialValues({});
    final settings = Settings(
      device: 'iphone1',
      endpoints: ['http://hub:8000'],
      prefs: await SharedPreferences.getInstance(),
      phone: phoneOn ? active : const PhoneSettings(),
    );
    final hub = PushHub();
    final api = PosApi(settings, client: MockClient(hub.handle));
    final push = PushRegistrar(api, settings, platform: platform);
    addTearDown(push.stop);
    return (hub, settings, push);
  }

  test('registers each token with the hub, the voip one with the extension the phone registers as', () async {
    final (hub, _, push) = await registrar();
    expect(push.line, startsWith('Waiting for the push token'));
    push.start();
    push.token('voip', 'AAAAAAAAAAAAAAAA');
    push.token('alert', alert);
    await Future<void>.delayed(Duration.zero);
    await push.sync();
    expect(hub.puts.map((p) => p['kind']), containsAll(['voip', 'alert']));
    final voipPut = hub.puts.firstWhere((p) => p['kind'] == 'voip');
    expect(voipPut, {'device': 'iphone1', 'platform': 'ios', 'kind': 'voip', 'token': voip, 'extension': '301'});
    final alertPut = hub.puts.firstWhere((p) => p['kind'] == 'alert');
    expect(alertPut['extension'], '');
    expect(push.wakesForCalls, isTrue);
    expect(push.wakesForPops, isTrue);
    expect(push.configured, isTrue);
    expect(push.line, 'Woken when locked for calls to 301 and desk-phone pick-ups');
    expect(push.lastOk, isNotNull);
  });

  test('the voip token goes off the hub when the phone is switched off here, and back on with it', () async {
    final (hub, settings, push) = await registrar();
    push.start();
    push.token('voip', voip);
    push.token('alert', alert);
    await push.sync();
    await settings.savePhone(active.copyWith(enabled: false));
    await push.sync();
    expect(hub.deletes, [voip]);
    expect(push.wakesForCalls, isFalse);
    expect(push.wakesForPops, isTrue);
    expect(push.line, 'Woken when locked for desk-phone pick-ups');
    hub.puts.clear();
    await settings.savePhone(active.copyWith(extension: '302'));
    await push.sync();
    expect(hub.puts.where((p) => p['kind'] == 'voip').last['extension'], '302');
    expect(push.line, 'Woken when locked for calls to 302 and desk-phone pick-ups');
  });

  test('a revoked token is taken off the hub', () async {
    final (hub, _, push) = await registrar();
    push.start();
    push.token('alert', alert);
    await push.sync();
    push.token('alert', '');
    await push.sync();
    expect(hub.deletes, [alert]);
    expect(push.tokens, isEmpty);
  });

  test('says when the hub has no key, and when it does not answer', () async {
    final (hub, _, push) = await registrar();
    hub.configured = false;
    push.start();
    push.token('alert', alert);
    await push.sync();
    expect(
      push.line,
      'Woken when locked for desk-phone pick-ups · the hub has no Apple key yet (Location, Keys and connections)',
    );
    hub.down = true;
    await push.sync();
    expect(push.lastError, isNotNull);
    expect(push.line, startsWith('Push not registered with the hub:'));
    expect(push.wakesForPops, isFalse);
    hub.down = false;
    await push.sync();
    expect(push.lastError, isNull);
  });

  test('has nothing to say on Android and Mac, which need no push', () async {
    final (hub, _, push) = await registrar(platform: 'android');
    push.start();
    await push.sync();
    expect(push.line, isNull);
    expect(hub.puts, isEmpty);
  });

  test('registers again every quarter hour, so a hub that lost its registry gets it back', () {
    fakeAsync((async) {
      late PushHub hub;
      late PushRegistrar push;
      registrar().then((made) {
        hub = made.$1;
        push = made.$3;
      });
      async.flushMicrotasks();
      push.start();
      push.token('alert', alert);
      async.flushMicrotasks();
      expect(hub.puts, hasLength(1));
      async.elapse(const Duration(minutes: 15));
      expect(hub.puts, hasLength(2));
    });
  });
}
