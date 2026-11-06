import 'package:flutter/material.dart';

import 'session.dart';

/// What the app does when the signed-in person changes under it, by a face or a tag as much as by the PIN pad
/// or the Sign out item: every screen and dialog above the first goes, so the next person starts at the orders
/// screen (never in the last person's order or settings), and a hands-free switch says hello.
class SessionWatcher {
  SessionWatcher(this.session, {required this.navigator, required this.messenger}) {
    _staffId = session.staff?.staffId;
    session.addListener(_changed);
  }

  final Session session;
  final GlobalKey<NavigatorState> navigator;
  final GlobalKey<ScaffoldMessengerState> messenger;
  String? _staffId;

  void _changed() {
    final staff = session.staff;
    final id = staff?.staffId;
    if (id == _staffId) return;
    final before = _staffId;
    _staffId = id;
    navigator.currentState?.popUntil((route) => route.isFirst);
    if (before != null && staff != null && (staff.method == 'face' || staff.method == 'tag')) {
      messenger.currentState
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Hi ${staff.name}'), duration: const Duration(seconds: 2)));
    }
  }

  void dispose() => session.removeListener(_changed);
}
