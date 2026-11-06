import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../camera.dart';
import '../faces.dart';
import '../phone.dart';
import '../print_relay.dart';
import '../settings.dart';

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
    this.camera,
  });

  final Settings settings;
  final bool firstRun;
  final PosApi? api;
  final PrintRelay? relay;
  final PhoneClient? phone;
  final EventCamera? camera;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _device = TextEditingController(text: widget.settings.device);
  late final TextEditingController _endpoints = TextEditingController(text: widget.settings.endpoints.join('\n'));
  late bool _relay = widget.settings.printRelay;
  late final TextEditingController _pbx = TextEditingController(text: widget.settings.phone.server);
  late final TextEditingController _extension = TextEditingController(text: widget.settings.phone.extension);
  late final TextEditingController _secret = TextEditingController(text: widget.settings.phone.secret);
  late bool _phoneOn = widget.settings.phone.enabled;
  String? _printMessage;
  FaceStatus? _faceStatus;
  String? _faceError;

  @override
  void initState() {
    super.initState();
    widget.camera?.addListener(_changed);
    unawaited(_askFaces());
  }

  void _changed() {
    if (mounted) setState(() {});
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
        setState(() => _printMessage = 'The backend has no printers configured (POS_PRINTERS on the hub)');
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
