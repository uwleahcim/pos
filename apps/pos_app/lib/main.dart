import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'asset_ringer.dart';
import 'cache.dart';
import 'call_screen.dart';
import 'camera.dart';
import 'desk_phone_watcher.dart';
import 'dish_names.dart';
import 'face_signin.dart';
import 'frames.dart';
import 'idle_lock.dart';
import 'outbox.dart';
import 'phone.dart';
import 'photos.dart';
import 'print_relay.dart';
import 'push.dart';
import 'queue_store.dart';
import 'ringer.dart';
import 'screens/lock_layer.dart';
import 'screens/orders_screen.dart';
import 'screens/phone_bar.dart';
import 'screens/reader_keys.dart';
import 'screens/settings_screen.dart';
import 'screens/signin_screen.dart';
import 'screens/standing_gate.dart';
import 'screens/tap_focus.dart';
import 'screens/text_arrows.dart';
import 'screens/theme.dart';
import 'session.dart';
import 'settings.dart';
import 'sip_ua_stack.dart';
import 'switching.dart';
import 'tags.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FrameWatch.shared.start(); // counts the frames drawn late: Settings shows them under Smoothness
  final settings = await Settings.load();
  // The last menu, dishes, floor and tax rates read stay on disk, so the screen can still take orders when
  // no backend answers (ADR 6).
  final api = PosApi(settings, cache: await ReadCache.load());
  // The taps and the audit photos not sent yet are files too, beside the saved reads: a tap costs the same
  // however many are waiting. What an older build left in the preference store is taken over on the way.
  final prefs = await SharedPreferences.getInstance();
  final support = (await getApplicationSupportDirectory()).path;
  final session = Session(api);
  // Every step taken on a check says who was signed in when it was taken: a check's history names them.
  final outbox = Outbox(
    api,
    settings,
    store: JournalStore(File('$support/outbox.log'), id: Outbox.idField),
    who: () => session.staff,
  );
  await outbox.restore(legacy: prefs);
  final camera = EventCamera.forPlatform();
  final photos = PhotoQueue(
    api,
    settings,
    camera,
    session,
    store: FolderStore(Directory('$support/photo_queue'), id: PhotoQueue.idField),
  );
  await photos.restore(legacy: prefs);
  // Builds before 2026-11-12 kept the saved reads in the preference store as well, over ten megabytes of it,
  // which the store rewrote whole on every write: they are taken out, slowly, once the app is up.
  unawaited(ReadCache.forgetLegacy(prefs));
  final relay = PrintRelay(api, settings)..bind();
  // The hub tells this screen what changed, the moment it does, over one connection held open: the screens
  // stop asking every two seconds while it is up, and go back to asking whenever it is not.
  api.live.start();
  // Who is at this screen, for as long as the app runs: the camera signs people in and switches between them
  // hands-free (docs/face-signin.md), and a badge reader on the keyboard does the same by tag.
  final faces = FaceSignIn(api, settings, camera, session);
  if (camera is! NoCamera) faces.start();
  final tags = WedgeTagReader(onTag: faces.tag)..install();
  // A screen nobody touches for the minutes this device was given locks itself (docs/idle-lock.md).
  final idleLock = IdleLock(settings, session)..start();
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
      idleLock.check(); // a device that slept through its minutes comes back locked
    },
    // Back from the background (not a Mac window regaining focus): the connection the feed slept on is not
    // trusted, it is opened afresh.
    onRestart: api.live.wake,
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
      faces: faces,
      tags: tags,
      idleLock: idleLock,
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

class PosApp extends StatefulWidget {
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
    this.faces,
    this.tags,
    this.idleLock,
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

  /// The app-wide face sign-in, shown by the sign-in screen; the screen runs its own without one.
  final FaceSignIn? faces;

  /// The terminal's tag reader, for enrolling tags in Location settings.
  final TagReader? tags;

  /// Locks the screen when nobody has touched it for the device's minutes; it is told of every touch.
  final IdleLock? idleLock;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  static final _navigator = GlobalKey<NavigatorState>();
  static final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final SessionWatcher _switching;

  @override
  void initState() {
    super.initState();
    // A change of person, by face, tag or PIN, closes whatever the last person had open.
    _switching = SessionWatcher(widget.session, navigator: _navigator, messenger: _messenger);
  }

  @override
  void dispose() {
    _switching.dispose();
    super.dispose();
  }

  /// To go on the call strip: back to the orders screen, which opens the to-go form for the caller.
  void _orderForCaller() {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    widget.phone.startOrder();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final session = widget.session;
    final api = widget.api;
    final phone = widget.phone;
    final camera = widget.camera;
    final tags = widget.tags;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, session]),
      builder: (context, _) {
        // The signed-in person's own text size and contrast, on every screen and dialog; back to normal
        // when they sign out, so the next person starts from the defaults or their own settings.
        final prefs = session.prefs;
        final canOrder = settings.isConfigured && session.signedIn;
        return MaterialApp(
          navigatorKey: _navigator,
          scaffoldMessengerKey: _messenger,
          title: 'POS',
          debugShowCheckedModeBanner: false,
          theme: PosTheme.light(highContrast: prefs.highContrast),
          darkTheme: PosTheme.dark(highContrast: prefs.highContrast),
          // The call banner and strip sit over every screen and dialog. So do the rules of the keyboard's
          // focus: a touch or a click takes it to what was touched, a badge reader's keys press none of the
          // buttons, and the arrows leave a text box once the cursor can go no further.
          // Which name of a dish the signed-in person reads, English or Chinese: theirs like the text size.
          builder: (context, child) => DishLanguage(
            chinese: readsChinese(prefs.locale),
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(prefs.textScale))),
              // Every touch tells the idle lock somebody is here. While the screen is locked the sign-in pad
              // lies over the screens, which stay as they were; the call banner stays above the pad, as it
              // is above the sign-in screen.
              child: Touches(
                lock: widget.idleLock,
                child: TapTakesFocus(
                  child: ReaderKeysPressNothing(
                    typed: tags is WedgeTagReader ? tags.typed : null,
                    child: ArrowsLeaveTextBoxes(
                      child: PhoneBar(
                        client: phone,
                        onOrder: canOrder ? _orderForCaller : null,
                        child: LockLayer(
                          session: session,
                          // (a pickup board or a kitchen screen stands over the pad too: the screen on the
                          // wall locked itself)
                          pad: (context) => StandingGate(
                            settings: settings,
                            api: api,
                            outbox: widget.outbox,
                            pad: (context, toBoard) => SignInScreen(
                              session: session,
                              settings: settings,
                              camera: camera,
                              faces: widget.faces,
                              lockedNote: lockedNote(settings.lockMinutes, session.lockedFrom?.name ?? ''),
                              onBoard: toBoard,
                            ),
                          ),
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
              } else if (!session.signedIn && !session.locked) {
                // (a screen locked for standing idle keeps what was open, under the pad the lock lays over it)
                // On a device that is a pickup board or a station's kitchen screen, that stands here, the pad
                // one tap behind it.
                screen = StandingGate(
                  key: const ValueKey('sign-in'),
                  settings: settings,
                  api: api,
                  outbox: widget.outbox,
                  pad: (_, toBoard) => SignInScreen(
                    session: session,
                    settings: settings,
                    camera: camera,
                    faces: widget.faces,
                    onBoard: toBoard,
                    onSettings: () => Navigator.of(context).push(
                      PosPageRoute(
                        builder: (_) => SettingsScreen(
                          settings: settings,
                          api: api,
                          relay: widget.relay,
                          phone: phone,
                          push: widget.push,
                          screen: widget.callScreen,
                          camera: camera,
                        ),
                      ),
                    ),
                  ),
                );
              } else {
                screen = OrdersScreen(
                  key: const ValueKey('orders'),
                  api: api,
                  outbox: widget.outbox,
                  settings: settings,
                  session: session,
                  camera: camera,
                  photos: widget.photos,
                  relay: widget.relay,
                  phone: phone,
                  deskPhones: widget.deskPhones,
                  tags: widget.tags,
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
