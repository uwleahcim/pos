import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../outbox.dart';
import '../settings.dart';
import 'kitchen_screen.dart';
import 'pickup_board_screen.dart';

/// What a screen shows while nobody is signed in on it: the sign-in pad or, on a device set to stand as
/// something, that: a station's kitchen screen or the pass (`Settings.kitchenStations`,
/// `Settings.kitchenPass`, docs/kitchen-screens.md) or the pickup board (`Settings.pickupBoard`,
/// docs/pickup-board.md), with the pad one tap away for the staff.
///
/// [pad] builds the sign-in pad; it is handed the way back to the standing screen, for its bar. A pad nobody
/// touches for [backAfter] goes back by itself, so the screen on the wall never stays on a PIN pad because
/// somebody tapped Staff and walked off. Signing in takes the whole of this away, pad and screen.
class StandingGate extends StatefulWidget {
  const StandingGate({
    super.key,
    required this.settings,
    required this.api,
    required this.outbox,
    required this.pad,
    this.backAfter = const Duration(minutes: 1),
  });

  final Settings settings;
  final PosApi api;

  /// Where a kitchen screen's marks go, like every other change to an order.
  final Outbox outbox;
  final Widget Function(BuildContext context, VoidCallback? back) pad;
  final Duration backAfter;

  @override
  State<StandingGate> createState() => _StandingGateState();
}

class _StandingGateState extends State<StandingGate> {
  bool _staff = false; // one of the staff asked for the pad
  Timer? _back;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettings);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    _back?.cancel();
    super.dispose();
  }

  // The device was just made a board or a kitchen screen, from Settings behind the pad: it comes up when
  // Settings closes.
  void _onSettings() {
    if (mounted) setState(() {});
  }

  void _toPad() {
    setState(() => _staff = true);
    _touched();
  }

  void _toScreen() {
    _back?.cancel();
    if (mounted) setState(() => _staff = false);
  }

  /// Somebody is at the pad: the minute starts over.
  void _touched() {
    if (!_staff) return;
    _back?.cancel();
    _back = Timer(widget.backAfter, _toScreen);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    if (!settings.stands) return widget.pad(context, null);
    if (!_staff) {
      if (settings.kitchen) {
        return KitchenScreen(
          key: const ValueKey('kitchen-screen'),
          api: widget.api,
          outbox: widget.outbox,
          stations: settings.kitchenStations,
          pass: settings.kitchenPass,
          onStaff: _toPad,
        );
      }
      return PickupBoardScreen(key: const ValueKey('pickup-board'), api: widget.api, onStaff: _toPad);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touched(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, _) {
          _touched(); // a PIN typed on a keyboard, a tag held to the reader
          return KeyEventResult.ignored;
        },
        child: widget.pad(context, _toScreen),
      ),
    );
  }
}
