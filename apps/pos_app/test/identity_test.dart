import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_app/api.dart';
import 'package:pos_app/camera.dart';
import 'package:pos_app/photos.dart';
import 'package:pos_app/session.dart';
import 'package:pos_app/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCamera extends EventCamera {
  int snaps = 0;
  @override
  bool get ready => true;
  @override
  String? get error => null;
  @override
  Widget preview() => const SizedBox();
  @override
  Future<Uint8List?> snap() async {
    snaps += 1;
    return Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
  }
}

void main() {
  late List<http.Request> requests;
  late bool backendUp;

  http.Client client() => MockClient((request) async {
    requests.add(request);
    if (!backendUp) throw http.ClientException('refused', request.url);
    if (request.url.path == '/signin') {
      final pin = (jsonDecode(request.body) as Map)['pin'];
      if (pin == '1111') {
        final amy = {'staff_id': 's1', 'name': 'Amy', 'role': 'server', 'method': 'pin'};
        return http.Response(jsonEncode(amy), 200);
      }
      if (pin == '0000') {
        return http.Response(
          jsonEncode({
            'detail': {'error': 'unknown_credential'},
          }),
          401,
        );
      }
      return http.Response(
        jsonEncode({
          'detail': {'error': 'locked', 'seconds': 60},
        }),
        423,
      );
    }
    if (request.url.path == '/events/photos') return http.Response(jsonEncode({'photo_id': 'x', 'bytes': 7}), 202);
    return http.Response('{}', 404);
  });

  setUp(() {
    requests = [];
    backendUp = true;
    SharedPreferences.setMockInitialValues({});
  });

  test('PIN sign-in: right, wrong, locked', () async {
    final settings = Settings(device: 'mac1', endpoints: const ['http://hub1:8000']);
    final session = Session(PosApi(settings, client: client()));
    expect(await session.signInWithPin('mac1', '1111'), isNull);
    expect(session.staff!.name, 'Amy');
    session.signOut();
    expect(session.signedIn, isFalse);
    expect(await session.signInWithPin('mac1', '0000'), 'Wrong PIN');
    expect(await session.signInWithPin('mac1', '2222'), contains('Wait a minute'));
  });

  test('an event photo is taken at once and sent when the backend is reachable', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = Settings(device: 'mac1', endpoints: const ['http://hub1:8000'], prefs: prefs);
    final api = PosApi(settings, client: client(), timeout: const Duration(milliseconds: 200));
    final session = Session(api);
    await session.signInWithPin('mac1', '1111');
    final camera = FakeCamera();
    final photos = PhotoQueue(api, settings, camera, session, prefs: prefs);

    backendUp = false;
    await photos.capture('fire', opId: 'op1');
    await photos.flush();
    expect(camera.snaps, 1);
    expect(photos.pending, 1);
    expect(prefs.getStringList('photos')!.length, 1);

    backendUp = true;
    await photos.flush();
    expect(photos.pending, 0);
    final sent = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(sent['event'], 'fire');
    expect(sent['op_id'], 'op1');
    expect(sent['staff_id'], 's1');
    expect(sent['device'], 'mac1');
    expect(base64Decode(sent['jpeg_b64'] as String).take(2), [0xff, 0xd8]);
  });

  test('no camera means no photo and no error', () async {
    final settings = Settings(device: 'mac1', endpoints: const ['http://hub1:8000']);
    final api = PosApi(settings, client: client());
    final photos = PhotoQueue(api, settings, NoCamera(), Session(api), prefs: await SharedPreferences.getInstance());
    await photos.capture('close');
    expect(photos.pending, 0);
    expect(photos.taken, 0);
  });
}
