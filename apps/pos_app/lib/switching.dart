import 'package:flutter/material.dart';

import 'session.dart';

/// What the app does when the signed-in person changes under it. A hands-free switch (a face, a tag) keeps
/// the order that is open, since the next person carries on with it (each dish they add is theirs on the
/// check), closes whatever sits above it (a sheet, a dialog, a manager's screen) and says hello; with no
/// order open it goes back to the orders screen. A sign-out, or a sign-in from nobody, closes everything
/// above the first screen, so nobody lands in the last person's order or settings.
class SessionWatcher {
  SessionWatcher(this.session, {required this.navigator, required this.messenger}) {
    _staffId = session.staff?.staffId;
    session.addListener(_changed);
  }

  /// The route name an order screen is pushed under, so a switch can tell it from the rest.
  static const orderRoute = 'order';

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
    final hello = before != null && staff != null && (staff.method == 'face' || staff.method == 'tag')
        ? staff.name
        : null;
    navigator.currentState?.popUntil((route) => route.isFirst || (hello != null && route.settings.name == orderRoute));
    if (hello != null) {
      messenger.currentState
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Hi $hello'), duration: const Duration(seconds: 2)));
    }
  }

  void dispose() => session.removeListener(_changed);
}
