import 'package:flutter/material.dart';

import 'api.dart';
import 'cache.dart';
import 'camera.dart';
import 'outbox.dart';
import 'photos.dart';
import 'print_relay.dart';
import 'screens/orders_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/signin_screen.dart';
import 'screens/theme.dart';
import 'session.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  // The last menu, dishes, floor and tax rates read stay on disk, so the screen can still take orders when
  // no backend answers (ADR 6).
  final api = PosApi(settings, cache: await ReadCache.load());
  final outbox = Outbox(api, settings);
  await outbox.restore();
  final session = Session(api);
  final camera = EventCamera.forPlatform();
  final photos = PhotoQueue(api, settings, camera, session);
  await photos.restore();
  final relay = PrintRelay(api, settings)..bind();
  runApp(
    PosApp(
      settings: settings,
      api: api,
      outbox: outbox,
      session: session,
      camera: camera,
      photos: photos,
      relay: relay,
    ),
  );
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
    required this.relay,
  });

  final Settings settings;
  final PosApi api;
  final Outbox outbox;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay relay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, session]),
      builder: (context, _) {
        // The signed-in person's own text size and contrast, on every screen and dialog; back to normal
        // when they sign out, so the next person starts from the defaults or their own settings.
        final prefs = session.prefs;
        return MaterialApp(
          title: 'POS',
          debugShowCheckedModeBanner: false,
          theme: PosTheme.light(highContrast: prefs.highContrast),
          darkTheme: PosTheme.dark(highContrast: prefs.highContrast),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(prefs.textScale))),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) {
              final Widget screen;
              if (!settings.isConfigured) {
                screen = SettingsScreen(key: const ValueKey('first-run-settings'), settings: settings, firstRun: true);
              } else if (!session.signedIn) {
                screen = SignInScreen(
                  key: const ValueKey('sign-in'),
                  session: session,
                  settings: settings,
                  camera: camera,
                  onSettings: () => Navigator.of(context).push(
                    PosPageRoute(
                      builder: (_) => SettingsScreen(settings: settings, api: api, relay: relay),
                    ),
                  ),
                );
              } else {
                screen = OrdersScreen(
                  key: const ValueKey('orders'),
                  api: api,
                  outbox: outbox,
                  settings: settings,
                  session: session,
                  camera: camera,
                  photos: photos,
                  relay: relay,
                );
              }
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: screen,
              );
            },
          ),
        );
      },
    );
  }
}
