import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'asset_ringer.dart';
import 'cache.dart';
import 'call_screen.dart';
import 'camera.dart';
import 'desk_phone_watcher.dart';
import 'outbox.dart';
import 'phone.dart';
import 'photos.dart';
import 'print_relay.dart';
import 'push.dart';
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
  // The device's own part in calls (docs/push-relay.md): the system's call screen on iOS, the service that
  // keeps the app alive with the screen off on Android, the sleep hold on a Mac.
  final screen = NativeCallScreen.forPlatform();
  // The phone follows the settings: registered with the PBX while switched on and filled in, off otherwise.
  final phone = PhoneClient(
    SipUaStack(),
    screen: screen,
    callState: api.callState,
    isForeground: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
  unawaited(phone.apply(settings.phone));
  settings.addListener(() => unawaited(phone.apply(settings.phone)));
  // The ring, on every platform, for as long as the banner shows and the device's screen does not ring itself.
  CallRinger(phone, AssetRinger());
  // Desk phones: a call taken on one linked to this device opens the caller's order here, as the app does
  // when it picks up a call itself. The hub is asked for as long as the app runs.
  final deskPhones = DeskPhoneWatcher(api, settings)..start();
  // The hub wakes a locked screen with a push: it holds this screen's tokens, for as long as the app runs.
  final push = PushRegistrar(api, settings)..start();
  screen.events = _ScreenEvents(phone, push, deskPhones);
  screen.ready();
  // Awake and alive for calls while the phone is on, or a desk phone is linked to this screen.
  void keepAwake() => screen.keepAwake(settings.phone.active || deskPhones.linked);
  settings.addListener(keepAwake);
  deskPhones.addListener(keepAwake);
  keepAwake();
  // A pick-up while the app is not in front: the device lights up and says so (the orders screen underneath
  // opens the order meanwhile, so it is there when the app comes up).
  deskPhones.addListener(() {
    final call = deskPhones.pending;
    if (call == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    screen.wake(title: 'Phone ${call.extension} picked up', body: call.caller.formatted);
  });
  // Back in front after a sleep: the phone's connection is started over when it is likely dead, and the
  // hub is asked for a pick-up that happened meanwhile.
  AppLifecycleListener(
    onPause: phone.paused,
    onResume: () {
      phone.resumed();
      deskPhones.wakeUp();
    },
  );
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
      deskPhones: deskPhones,
      push: push,
      callScreen: screen,
    ),
  );
}

/// What the device's screen tells the app, handed to whoever it concerns.
class _ScreenEvents implements CallScreenEvents {
  _ScreenEvents(this.phone, this.push, this.deskPhones);

  final PhoneClient phone;
  final PushRegistrar push;
  final DeskPhoneWatcher deskPhones;

  @override
  void pushToken(String kind, String token) => push.token(kind, token);

  @override
  void pushed(String id, {String? number, String? name, bool test = false}) =>
      phone.pushed(id, number: number, name: name, test: test);

  @override
  void screenAnswered(String id) => phone.screenAnswered(id);

  @override
  void screenEnded(String id) => phone.screenEnded(id);

  @override
  void screenMuted(String id, bool on) => phone.screenMuted(id, on);

  @override
  void screenGone(String id) => phone.screenGone(id);

  @override
  void opened() => deskPhones.wakeUp();
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
    required this.deskPhones,
    this.push,
    this.callScreen,
  });

  final Settings settings;
  final PosApi api;
  final Outbox outbox;
  final Session session;
  final EventCamera camera;
  final PhotoQueue photos;
  final PrintRelay relay;
  final PhoneClient phone;
  final DeskPhoneWatcher deskPhones;
  final PushRegistrar? push;
  final CallScreen? callScreen;

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
                      builder: (_) => SettingsScreen(
                        settings: settings,
                        api: api,
                        relay: relay,
                        phone: phone,
                        push: push,
                        screen: callScreen,
                        camera: camera,
                      ),
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
                  deskPhones: deskPhones,
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
