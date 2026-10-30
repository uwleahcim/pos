import 'package:flutter/material.dart';

import '../api.dart';
import '../print_relay.dart';
import '../settings.dart';

/// Device name and backend addresses. Shown on first start, and from the orders screen afterwards.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings, this.firstRun = false, this.api, this.relay});

  final Settings settings;
  final bool firstRun;
  final PosApi? api;
  final PrintRelay? relay;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _device = TextEditingController(text: widget.settings.device);
  late final TextEditingController _endpoints = TextEditingController(text: widget.settings.endpoints.join('\n'));
  late bool _relay = widget.settings.printRelay;
  String? _printMessage;

  @override
  void dispose() {
    _device.dispose();
    _endpoints.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.settings.save(device: _device.text, endpoints: _endpoints.text.split('\n'), printRelay: _relay);
    if (!mounted) return;
    if (widget.firstRun) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } else {
      Navigator.of(context).pop();
    }
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
              const SizedBox(height: 24),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
