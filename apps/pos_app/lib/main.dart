import 'package:flutter/material.dart';

import 'api.dart';
import 'camera.dart';
import 'outbox.dart';
import 'photos.dart';
import 'screens/orders_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/signin_screen.dart';
import 'session.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final api = PosApi(settings);
  final outbox = Outbox(api, settings);
  await outbox.restore();
  final session = Session(api);
  final camera = EventCamera.forPlatform();
  final photos = PhotoQueue(api, settings, camera, session);
  await photos.restore();
  runApp(PosApp(settings: settings, api: api, outbox: outbox, session: session, camera: camera, photos: photos));
}

class PosApp extends StatelessWidget {
  const PosApp({
    super.key,
    required this.settings,
    required this.api,
    required this.outbox,
    required this.session,
    required this.camera,
    required this.photos,
  });

  final Settings settings;
  final PosApi api;
  final Outbox outbox;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POS',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFB3261E), useMaterial3: true),
      home: ListenableBuilder(
        listenable: Listenable.merge([settings, session]),
        builder: (context, _) {
          if (!settings.isConfigured) return SettingsScreen(settings: settings, firstRun: true);
          if (!session.signedIn) {
            return SignInScreen(
              session: session,
              settings: settings,
              camera: camera,
              onSettings: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(settings: settings))),
            );
          }
          return OrdersScreen(
            api: api,
            outbox: outbox,
            settings: settings,
            session: session,
            camera: camera,
            photos: photos,
          );
        },
      ),
    );
  }
}
