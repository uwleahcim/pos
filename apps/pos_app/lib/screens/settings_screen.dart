import 'package:flutter/material.dart';

import '../settings.dart';

/// Device name and backend addresses. Shown on first start, and from the orders screen afterwards.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings, this.firstRun = false});

  final Settings settings;
  final bool firstRun;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _device = TextEditingController(text: widget.settings.device);
  late final TextEditingController _endpoints = TextEditingController(text: widget.settings.endpoints.join('\n'));

  @override
  void dispose() {
    _device.dispose();
    _endpoints.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.settings.save(device: _device.text, endpoints: _endpoints.text.split('\n'));
    if (!mounted) return;
    if (widget.firstRun) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Set up this terminal' : 'Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _device,
            decoration: const InputDecoration(
              labelText: 'Device name',
              helperText: 'Letters and digits, unique per terminal, e.g. bar1 or ipad3',
            ),
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
