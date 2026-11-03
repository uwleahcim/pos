import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'asset_ringer.dart';
import 'cache.dart';
import 'camera.dart';
import 'outbox.dart';
import 'phone.dart';
import 'photos.dart';
import 'print_relay.dart';
import 'ringer.dart';
import 'screens/orders_screen.dart';
import 'screens/phone_bar.dart';
import 'screens/settings_screen.dart';
import 'screens/signin_screen.dart';
import 'screens/theme.dart';
import 'session.dart';
import 'settings.dart';
import 'sip_ua_stack.dart';

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
  // The phone follows the settings: registered with the PBX while switched on and filled in, off otherwise.
  final phone = PhoneClient(SipUaStack());
  unawaited(phone.apply(settings.phone));
  settings.addListener(() => unawaited(phone.apply(settings.phone)));
  // The ring, on every platform, for as long as the banner shows.
  CallRinger(phone, AssetRinger());
  runApp(
    PosApp(
      settings: settings,
      api: api,
      outbox: outbox,
      session: session,
      camera: camera,
      photos: photos,
      relay: relay,
      phone: phone,
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
    required this.phone,
  });

  final Settings settings;
  final PosApi api;
  final Outbox outbox;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay relay;
  final PhoneClient phone;

  static final _navigator = GlobalKey<NavigatorState>();

  /// To go on the call strip: back to the orders screen, which opens the to-go form for the caller.
  void _orderForCaller() {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    phone.startOrder();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, session]),
      builder: (context, _) {
        // The signed-in person's own text size and contrast, on every screen and dialog; back to normal
        // when they sign out, so the next person starts from the defaults or their own settings.
        final prefs = session.prefs;
        final canOrder = settings.isConfigured && session.signedIn;
        return MaterialApp(
          navigatorKey: _navigator,
          title: 'POS',
          debugShowCheckedModeBanner: false,
          theme: PosTheme.light(highContrast: prefs.highContrast),
          darkTheme: PosTheme.dark(highContrast: prefs.highContrast),
          // The call banner and strip sit over every screen and dialog.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(prefs.textScale))),
            child: PhoneBar(
              client: phone,
              onOrder: canOrder ? _orderForCaller : null,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: Builder(
            builder: (context) {
              final Widget screen;
              if (!settings.isConfigured) {
                screen = SettingsScreen(
                  key: const ValueKey('first-run-settings'),
                  settings: settings,
                  firstRun: true,
                  phone: phone,
                );
              } else if (!session.signedIn) {
                screen = SignInScreen(
                  key: const ValueKey('sign-in'),
                  session: session,
                  settings: settings,
                  camera: camera,
                  onSettings: () => Navigator.of(context).push(
                    PosPageRoute(
                      builder: (_) => SettingsScreen(settings: settings, api: api, relay: relay, phone: phone),
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
                  phone: phone,
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
