import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../call_screen.dart';
import '../camera.dart';
import '../faces.dart';
import '../frames.dart';
import '../kitchen_bell.dart';
import '../phone.dart';
import '../print_relay.dart';
import '../printers.dart';
import '../push.dart';
import '../settings.dart';
import 'save_bar.dart';
import 'smoothness_card.dart';

/// Device name, backend addresses and the phone. Shown on first start, and from the orders screen afterwards.
/// With an [api] it also says how face sign-in stands, so a terminal that is not looking for faces says why.
/// Nothing is kept as it is changed: a bar with Save comes up at the bottom of the screen with the first
/// change ([SaveBarScaffold]), and on first start it is there from the beginning.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.firstRun = false,
    this.api,
    this.relay,
    this.phone,
    this.push,
    this.screen,
    this.camera,
    this.frames,
    this.bell,
  });

  final Settings settings;
  final bool firstRun;
  final PosApi? api;
  final PrintRelay? relay;
  final PhoneClient? phone;
  final EventCamera? camera;

  /// How smoothly this device draws; the app's own count when not given.
  final FrameWatch? frames;

  /// A kitchen screen's chime, for the button that plays it; no button without one.
  final KitchenBell? bell;

  /// The hub's push registry for this screen (iOS): a line on whether a locked screen is woken.
  final PushRegistrar? push;

  /// The device's own part in calls: what it still needs allowed (Android), and the way to ask.
  final CallScreen? screen;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _device = TextEditingController(text: widget.settings.device);
  late final TextEditingController _endpoints = TextEditingController(text: widget.settings.endpoints.join('\n'));
  late bool _relay = widget.settings.printRelay;
  late int _lockMinutes = widget.settings.lockMinutes;
  late bool _signOutAfterSend = widget.settings.signOutAfterSend;
  late String _opensOn = widget.settings.opensOn;
  late bool _pickupBoard = widget.settings.pickupBoard;
  late final List<String> _kitchen = [...widget.settings.kitchenStations];
  late bool _pass = widget.settings.kitchenPass;
  late bool _sound = widget.settings.kitchenSound;
  StationList? _stations; // the location's stations, to pick a kitchen screen's from; null until the hub says
  bool _noStations = false; // the hub did not say
  late String _guestOf = widget.settings.guestDisplayOf; // the screen this one faces the guest of; '' for none
  List<String>? _screens; // the screens the hub hears from, to pick that one from; null until the hub says
  bool _noScreens = false; // the hub did not say
  late final TextEditingController _pbx = TextEditingController(text: widget.settings.phone.server);
  late final TextEditingController _extension = TextEditingController(text: widget.settings.phone.extension);
  late final TextEditingController _secret = TextEditingController(text: widget.settings.phone.secret);
  late bool _phoneOn = widget.settings.phone.enabled;
  String? _printMessage;
  FaceStatus? _faceStatus;
  String? _faceError;
  Map<String, bool> _readiness = const {};
  bool _saving = false;
  bool _waits = false; // what the Save bar was last built for: something differs from what the device keeps

  /// The fields that are typed: the Save bar follows them as they are.
  List<TextEditingController> get _typedFields => [_device, _endpoints, _pbx, _extension, _secret];

  @override
  void initState() {
    super.initState();
    for (final field in _typedFields) {
      field.addListener(_typed);
    }
    widget.camera?.addListener(_changed);
    unawaited(_askFaces());
    unawaited(_askStations());
    unawaited(_askScreens());
    unawaited(_checkReadiness());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// A letter was typed: the bar comes up, or goes once the field reads as it is kept. (Not a rebuild a
  /// letter.)
  void _typed() {
    if (mounted && _differs != _waits) setState(() {});
  }

  /// Something on the screen is not what the device keeps.
  bool get _differs {
    final kept = widget.settings;
    return _device.text.trim() != kept.device ||
        _endpoints.text.trim() != kept.endpoints.join('\n') ||
        _relay != kept.printRelay ||
        _lockMinutes != kept.lockMinutes ||
        _signOutAfterSend != kept.signOutAfterSend ||
        _opensOn != kept.opensOn ||
        _pickupBoard != kept.pickupBoard ||
        _guestOf != kept.guestDisplayOf ||
        !setEquals(_kitchen.toSet(), kept.kitchenStations.toSet()) ||
        _pass != kept.kitchenPass ||
        _sound != kept.kitchenSound ||
        _phoneOn != kept.phone.enabled ||
        _pbx.text.trim() != kept.phone.server ||
        _extension.text.trim() != kept.phone.extension ||
        _secret.text != kept.phone.secret;
  }

  Future<void> _checkReadiness() async {
    final screen = widget.screen;
    if (screen == null) return;
    final found = await screen.readiness();
    if (mounted) setState(() => _readiness = found);
  }

  Future<void> _prepare() async {
    await widget.screen?.prepare();
    await _checkReadiness();
  }

  /// What Android still needs allowed for calls with the screen off, in words; null when all is allowed.
  String? get _missing {
    final missing = [
      if (_readiness['notifications'] == false) 'notifications',
      if (_readiness['fullScreen'] == false) 'full-screen alerts',
      if (_readiness['battery'] == false) 'running without battery limits',
    ];
    return missing.isEmpty ? null : missing.join(', ');
  }

  @override
  void dispose() {
    widget.camera?.removeListener(_changed);
    _device.dispose();
    _endpoints.dispose();
    _pbx.dispose();
    _extension.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.settings.save(device: _device.text, endpoints: _endpoints.text.split('\n'), printRelay: _relay);
    await widget.settings.saveLockMinutes(_lockMinutes);
    await widget.settings.saveSignOutAfterSend(_signOutAfterSend);
    await widget.settings.saveOpensOn(_opensOn);
    await widget.settings.savePickupBoard(_pickupBoard);
    await widget.settings.saveKitchenStations(_kitchen, pass: _pass, sound: _sound);
    await widget.settings.saveGuestDisplayOf(_guestOf);
    await widget.settings.savePhone(
      PhoneSettings.clean(
        enabled: _phoneOn,
        server: _pbx.text,
        extension: _extension.text,
        secret: _secret.text,
        port: widget.settings.phone.port,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (widget.firstRun) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _askStations() async {
    final api = widget.api;
    if (api == null) return;
    try {
      final stations = await api.printStations();
      if (mounted) setState(() => _stations = stations);
    } on ApiException {
      if (mounted) setState(() => _noStations = true);
    }
  }

  Future<void> _askScreens() async {
    final api = widget.api;
    if (api == null) return;
    try {
      final screens = await api.devicesSeen();
      if (mounted) setState(() => _screens = screens);
    } on ApiException {
      if (mounted) setState(() => _noScreens = true);
    }
  }

  /// The screens a guest display can be linked to: the ones the hub hears from, without this one, and the
  /// one this device is already linked to (it may be switched off right now).
  List<String> get _linkable {
    final own = widget.settings.device.toLowerCase();
    final found = [
      for (final screen in _screens ?? const <String>[])
        if (screen.toLowerCase() != own) screen,
    ];
    final kept = widget.settings.guestDisplayOf;
    return [...found, if (kept.isNotEmpty && !found.any((screen) => screen.toLowerCase() == kept.toLowerCase())) kept];
  }

  /// The stations a kitchen screen can stand at: the location's, and any this device was already set to.
  List<({String code, String name})> get _offered => [
    for (final station in _stations?.stations ?? const <StationInfo>[]) (code: station.code, name: station.name),
    for (final code in _kitchen)
      if (_stations?.byCode(code) == null) (code: code, name: code),
  ];

  /// "Wok", "Wok and Fryer", "Wok, Fryer and Sushi bar": the stations picked, by name.
  String get _kitchenNames {
    final names = [
      for (final station in _offered)
        if (_kitchen.contains(station.code)) station.name,
    ];
    if (names.length < 2) return names.join();
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  Future<void> _askFaces() async {
    final api = widget.api;
    if (api == null) return;
    try {
      final status = await api.faceStatus();
      if (mounted) setState(() => _faceStatus = status);
    } on ApiException catch (err) {
      if (mounted) setState(() => _faceError = 'The hub has not answered about face sign-in: ${err.message}');
    }
  }

  /// How face sign-in stands here: what the hub says, then this terminal's own camera.
  String _faceLine() {
    final hub = _faceError ?? _faceStatus?.line ?? 'Asking the hub…';
    final camera = widget.camera;
    if (camera == null) return hub;
    final here = camera is NoCamera
        ? 'This terminal has no camera: PIN only.'
        : camera.ready
        ? 'This terminal\'s camera is up.'
        : 'This terminal\'s camera: ${camera.error ?? 'starting'}.';
    return '$hub. $here';
  }

  Future<void> _testPrint() async {
    final api = widget.api!;
    try {
      final printers = await api.printers();
      if (printers.isEmpty) {
        setState(() => _printMessage = 'No printers set yet: a manager adds them under Location settings › Printers');
        return;
      }
      for (final p in printers) {
        await api.testPrint(p['name'] as String);
      }
      setState(() => _printMessage = 'Demo ticket queued for ${printers.map((p) => p['name']).join(', ')}');
    } catch (err) {
      setState(() => _printMessage = 'Test print failed: $err');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    _waits = _differs;
    return SaveBarScaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Set up this terminal' : 'Settings')),
      // On first start nothing is kept yet and there is no screen to go back to: Save is there from the
      // beginning, and nothing asks about leaving.
      changed: _waits && !widget.firstRun,
      always: widget.firstRun,
      onSave: _saving ? null : _save,
      saveKey: const ValueKey('settings-save'),
      waiting: widget.firstRun ? 'Not saved yet' : 'Changes not saved',
      unsaved: 'Your changes to this terminal\'s settings are not saved.',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _device,
                        decoration: const InputDecoration(
                          labelText: 'Device name',
                          helperText: 'Letters and digits, unique per terminal, e.g. bar1 or ipad3',
                          prefixIcon: Icon(Icons.devices_outlined),
                        ),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _endpoints,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'Backend addresses, one per line, in failover order',
                          helperText: 'Hub first, then the standby hub, then the cloud. e.g. http://172.19.1.179:8000',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: _relay,
                        onChanged: (v) => setState(() => _relay = v),
                        title: const Text('Print relay'),
                        subtitle: Text(
                          widget.relay == null
                              ? 'This terminal prints queued tickets when the hub cannot reach the printers'
                              : 'Printed ${widget.relay!.printed}, failed ${widget.relay!.failed}'
                                    '${widget.relay!.lastError == null ? '' : ' · ${widget.relay!.lastError}'}',
                        ),
                      ),
                      if (widget.api != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _testPrint,
                                icon: const Icon(Icons.print_outlined),
                                label: const Text('Test print on every printer'),
                              ),
                              if (_printMessage != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    _printMessage!,
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // What this screen shows first when somebody signs in, as buttons; kept with Save.
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.start_rounded, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(child: Text('This screen opens on', style: theme.textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _opensOn == Settings.listOfChecks
                            ? 'Whoever signs in here starts on the list of checks, where the to-go orders are by '
                                  'stage. The floor map is one tap away.'
                            : 'Whoever signs in here starts on the floor map. The list of checks, with the to-go '
                                  'orders, is one tap away.',
                        key: const ValueKey('opens-on-line'),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final MapEntry(key: value, value: label) in Settings.opensOnChoices.entries)
                            ChoiceChip(
                              key: ValueKey('opens-on:$value'),
                              label: Text(label),
                              selected: _opensOn == value,
                              onSelected: (_) => setState(() => _opensOn = value),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // The pickup board: what this screen shows while nobody is signed in; kept with Save.
              Card(
                child: SwitchListTile(
                  key: const ValueKey('pickup-board-switch'),
                  contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 10),
                  secondary: Icon(Icons.view_module_outlined, color: scheme.onSurfaceVariant),
                  title: Text('Pickup board', style: theme.textTheme.titleMedium),
                  subtitle: Text(
                    _pickupBoard
                        ? 'While nobody is signed in, this screen lists the to-go orders being made and the ones '
                              'ready, by number and first name. Staff, in its corner, brings up the sign-in pad.'
                        : 'For a screen facing the pickup shelf: while nobody is signed in it lists the to-go '
                              'orders being made and the ones ready, by number and first name.',
                    key: const ValueKey('pickup-board-line'),
                  ),
                  value: _pickupBoard,
                  // (one thing only: a board for the customers shows no kitchen tickets, and no guest's order)
                  onChanged: (on) => setState(() {
                    _pickupBoard = on;
                    if (on) {
                      _kitchen.clear();
                      _pass = false;
                      _guestOf = '';
                    }
                  }),
                ),
              ),
              const SizedBox(height: 16),
              // A guest display: what this screen shows while nobody is signed in, turned to the customer;
              // the screen it is linked to is picked from the ones the hub hears from; kept with Save.
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.tv_outlined, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Guest display', style: theme.textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _guestOf.isNotEmpty
                            ? 'While nobody is signed in, this screen faces the guest: it shows the order open on '
                                  '$_guestOf as it is rung up, dish by dish, with the total. Staff, in its corner, '
                                  'brings up the sign-in pad.'
                            : _linkable.isNotEmpty
                            ? 'For a screen turned to the guest at a register: while nobody is signed in it shows '
                                  'the order being rung up on the screen it is linked to, dish by dish, with the '
                                  'total. Pick that screen.'
                            : _screens != null
                            ? 'For a screen turned to the guest at a register. No other screen is up right now: '
                                  'start the app on the register\'s screen, then come back here.'
                            : _noScreens || widget.api == null
                            ? 'For a screen turned to the guest at a register. The screens could not be read from '
                                  'the hub: come back here once it answers.'
                            : 'For a screen turned to the guest at a register. Asking the hub for the screens…',
                        key: const ValueKey('guest-display-line'),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      if (_linkable.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final screen in _linkable)
                              ChoiceChip(
                                key: ValueKey('guest-display-of:$screen'),
                                label: Text(screen),
                                selected: _guestOf.toLowerCase() == screen.toLowerCase(),
                                // (tapped again, it is a guest display no longer; and it is one thing only:
                                // no pickup board, no kitchen screen)
                                onSelected: (on) => setState(() {
                                  _guestOf = on ? screen : '';
                                  if (on) {
                                    _pickupBoard = false;
                                    _kitchen.clear();
                                    _pass = false;
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // A kitchen screen: what this screen shows while nobody is signed in, at a station; kept with Save.
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.soup_kitchen_outlined, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Kitchen screen', style: theme.textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _pass
                            ? 'While nobody is signed in, this screen is the pass: it lists every dish of each '
                                  'ticket with what each station has made, and a tap says a dish went out. It '
                                  'watches ${_kitchen.isEmpty ? 'every station' : _kitchenNames}. Staff, in its '
                                  'corner, brings up the sign-in pad.'
                            : _kitchen.isNotEmpty
                            ? 'While nobody is signed in, this screen lists what $_kitchenNames '
                                  '${_kitchen.length == 1 ? 'has' : 'have'} to make, and a tap marks a dish made. '
                                  'Staff, in its corner, brings up the sign-in pad.'
                            : _offered.isNotEmpty
                            ? 'For a screen at a station in the kitchen: while nobody is signed in it lists what '
                                  'the station has to make, and a tap marks a dish made. Pick the station it '
                                  'stands at.'
                            : _stations != null
                            ? 'For a screen at a station in the kitchen. The menu names no station yet.'
                            : _noStations || widget.api == null
                            ? 'For a screen at a station in the kitchen. The stations could not be read from '
                                  'the hub: come back here once it answers.'
                            : 'For a screen at a station in the kitchen. Asking the hub for the stations…',
                        key: const ValueKey('kitchen-screen-line'),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      if (_offered.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final station in _offered)
                              FilterChip(
                                key: ValueKey('kitchen-station:${station.code}'),
                                label: Text(station.name),
                                selected: _kitchen.contains(station.code),
                                onSelected:
                                    !_kitchen.contains(station.code) &&
                                        _kitchen.length >=
                                            (_pass ? Settings.kitchenPassMax : Settings.kitchenStationsMax)
                                    ? null
                                    : (on) => setState(() {
                                        if (on) {
                                          _kitchen.add(station.code);
                                          _pickupBoard = false;
                                          _guestOf = '';
                                        } else {
                                          _kitchen.remove(station.code);
                                        }
                                      }),
                              ),
                          ],
                        ),
                      ],
                      // The pass: the screen of whoever calls the orders, in place of a station's.
                      SwitchListTile(
                        key: const ValueKey('kitchen-pass-switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('This screen is the pass'),
                        subtitle: Text(
                          _pass
                              ? (_kitchen.isEmpty
                                    ? 'Pick stations to watch those alone.'
                                    : 'It leaves out the stations not picked.')
                              : 'For whoever calls the orders: each ticket whole, with what every station has made.',
                        ),
                        value: _pass,
                        onChanged: (on) => setState(() {
                          _pass = on;
                          if (on) {
                            _pickupBoard = false;
                            _guestOf = '';
                          }
                        }),
                      ),
                      // The chime when a ticket comes in: on, unless this device is told to keep quiet.
                      if (_kitchen.isNotEmpty || _pass)
                        SwitchListTile(
                          key: const ValueKey('kitchen-sound-switch'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Sound when a ticket comes in'),
                          subtitle: const Text(
                            'A chime for a new ticket, and for a dish voided or changed after it was sent. '
                            'The device\'s own volume sets how loud.',
                          ),
                          value: _sound,
                          onChanged: (on) => setState(() => _sound = on),
                        ),
                      if ((_kitchen.isNotEmpty || _pass) && _sound && widget.bell != null)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            key: const ValueKey('kitchen-sound-try'),
                            icon: const Icon(Icons.volume_up_outlined),
                            label: const Text('Play it'),
                            onPressed: () => unawaited(widget.bell!.play()),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // The idle lock: the minutes this screen may go untouched, as buttons; kept with Save.
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lock_clock_outlined, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Lock this screen when idle', style: theme.textTheme.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _lockMinutes == 0
                            ? 'This screen never locks itself. Pick the minutes it may go untouched before it '
                                  'asks who is there.'
                            : 'After ${_lockMinutes == 1 ? '1 minute' : '$_lockMinutes minutes'} without a touch '
                                  'this screen asks who is there (PIN, face or tag). Nothing is closed: an open '
                                  'order is still there after signing in.',
                        key: const ValueKey('lock-line'),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final minutes in {0, ...Settings.lockChoices, _lockMinutes}.toList()..sort())
                            ChoiceChip(
                              key: ValueKey('lock:$minutes'),
                              label: Text(minutes == 0 ? 'Never' : '$minutes min'),
                              selected: _lockMinutes == minutes,
                              onSelected: (_) => setState(() => _lockMinutes = minutes),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // A screen several people share: after a send, leaving the check signs out.
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SwitchListTile(
                    key: const ValueKey('sign-out-after-send'),
                    value: _signOutAfterSend,
                    onChanged: (v) => setState(() => _signOutAfterSend = v),
                    secondary: const Icon(Icons.logout),
                    title: const Text('Back to sign-in after sending'),
                    subtitle: Text(
                      _signOutAfterSend
                          ? 'Once dishes are sent from a check, leaving that check signs out, so the next person '
                                'signs in. For a screen several people share.'
                          : 'Leaving a check goes back to the tables, still signed in. Turn on for a screen '
                                'several people share.',
                    ),
                  ),
                ),
              ),
              if (widget.api != null) ...[
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.face_outlined),
                    title: const Text('Face sign-in'),
                    subtitle: Text(_faceLine(), key: const ValueKey('face-line')),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _phoneOn,
                        onChanged: (v) => setState(() => _phoneOn = v),
                        title: const Text('Phone'),
                        subtitle: widget.phone == null
                            ? const Text('Take the restaurant\'s calls in this app: ring, answer, mute, hang up')
                            : ListenableBuilder(
                                listenable: widget.phone!,
                                builder: (context, _) => Text(phoneStatusLine(widget.phone!)),
                              ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _pbx,
                        decoration: const InputDecoration(
                          labelText: 'PBX address',
                          helperText:
                              'The FreePBX host, e.g. freepbx.chinasky.org (port 8089 unless written as host:port)',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _extension,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Extension',
                                helperText: 'This terminal\'s own, e.g. 301',
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextField(
                              controller: _secret,
                              obscureText: true,
                              decoration: const InputDecoration(labelText: 'Secret', helperText: 'From the extension'),
                            ),
                          ),
                        ],
                      ),
                      if (widget.push != null)
                        ListenableBuilder(
                          listenable: widget.push!,
                          builder: (context, _) {
                            final line = widget.push!.line;
                            if (line == null) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Text(
                                line,
                                key: const ValueKey('push-line'),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            );
                          },
                        ),
                      if (_missing != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'For calls and desk-phone pick-ups with the screen off, this device must allow: $_missing.',
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _prepare,
                                icon: const Icon(Icons.notifications_active_outlined),
                                label: const Text('Allow'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!widget.firstRun) ...[
                const SizedBox(height: 16),
                SmoothnessCard(frames: widget.frames ?? FrameWatch.shared),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
