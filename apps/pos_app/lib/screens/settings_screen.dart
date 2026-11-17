import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../call_screen.dart';
import '../camera.dart';
import '../faces.dart';
import '../frames.dart';
import '../phone.dart';
import '../print_relay.dart';
import '../push.dart';
import '../settings.dart';
import 'smoothness_card.dart';

/// Device name, backend addresses and the phone. Shown on first start, and from the orders screen afterwards.
/// With an [api] it also says how face sign-in stands, so a terminal that is not looking for faces says why.
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
  });

  final Settings settings;
  final bool firstRun;
  final PosApi? api;
  final PrintRelay? relay;
  final PhoneClient? phone;
  final EventCamera? camera;

  /// How smoothly this device draws; the app's own count when not given.
  final FrameWatch? frames;

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
  late final TextEditingController _pbx = TextEditingController(text: widget.settings.phone.server);
  late final TextEditingController _extension = TextEditingController(text: widget.settings.phone.extension);
  late final TextEditingController _secret = TextEditingController(text: widget.settings.phone.secret);
  late bool _phoneOn = widget.settings.phone.enabled;
  String? _printMessage;
  FaceStatus? _faceStatus;
  String? _faceError;
  Map<String, bool> _readiness = const {};

  @override
  void initState() {
    super.initState();
    widget.camera?.addListener(_changed);
    unawaited(_askFaces());
    unawaited(_checkReadiness());
  }

  void _changed() {
    if (mounted) setState(() {});
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
    await widget.settings.save(device: _device.text, endpoints: _endpoints.text.split('\n'), printRelay: _relay);
    await widget.settings.saveLockMinutes(_lockMinutes);
    await widget.settings.saveSignOutAfterSend(_signOutAfterSend);
    await widget.settings.saveOpensOn(_opensOn);
    await widget.settings.savePickupBoard(_pickupBoard);
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
    if (widget.firstRun) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } else {
      Navigator.of(context).pop();
    }
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Set up this terminal' : 'Settings')),
      body: Center(
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
                  onChanged: (on) => setState(() => _pickupBoard = on),
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
              const SizedBox(height: 24),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
