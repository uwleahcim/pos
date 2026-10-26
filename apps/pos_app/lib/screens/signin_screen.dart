import 'package:flutter/material.dart';

import '../camera.dart';
import '../session.dart';
import '../settings.dart';

/// PIN pad with the camera preview beside it. Tags and face come in the sign-in hardware spike.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.session, required this.settings, required this.camera, this.onSettings});

  final Session session;
  final Settings settings;
  final EventCamera camera;
  final VoidCallback? onSettings;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  String _pin = '';
  String? _message;
  bool _busy = false;

  Future<void> _submit() async {
    if (_pin.length < 4 || _busy) return;
    setState(() => _busy = true);
    final message = await widget.session.signInWithPin(widget.settings.device, _pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
      _pin = '';
    });
  }

  void _tap(String key) {
    setState(() {
      _message = null;
      if (key == 'C') {
        _pin = '';
      } else if (key == '⌫') {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      } else if (_pin.length < 6) {
        _pin += key;
      }
    });
    if (_pin.length == 4) _submit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Sign in · ${widget.settings.device}'),
        actions: [
          if (widget.onSettings != null)
            IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: widget.onSettings),
        ],
      ),
      body: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 32,
          runSpacing: 24,
          children: [
            SizedBox(
              width: 280,
              height: 210,
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: widget.camera.preview()),
            ),
            SizedBox(
              width: 260,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_pin.isEmpty ? 'Enter your PIN' : '●' * _pin.length, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 24,
                    child: Text(_message ?? '', style: TextStyle(color: theme.colorScheme.error)),
                  ),
                  const SizedBox(height: 8),
                  for (final row in const [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                    ['C', '0', '⌫'],
                  ])
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final key in row)
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: SizedBox(
                              width: 72,
                              height: 64,
                              child: FilledButton.tonal(
                                onPressed: _busy ? null : () => _tap(key),
                                child: Text(key, style: theme.textTheme.titleLarge),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
