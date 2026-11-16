import 'package:flutter/material.dart';

import 'session.dart';

/// What the app does when the signed-in person changes under it. A hands-free switch (a face, a tag) keeps
/// the order that is open, since the next person carries on with it (each dish they add is theirs on the
/// check), closes whatever sits above it (a sheet, a dialog, a manager's screen) and says hello; with no
/// order open it goes back to the orders screen. A sign-out, or a sign-in from nobody, closes everything
/// above the first screen, so nobody lands in the last person's order or settings.
///
/// A screen that locks itself for standing idle ([Session.lock]) closes nothing: the sign-in pad lies over
/// what was open. The person who was there finds it all as they left it; anybody else signing in, by PIN
/// as well, takes the screen over as in a hands-free switch.
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
  String? _lockedId; // who was signed in when the screen locked, while it is locked

  void _changed() {
    final staff = session.staff;
    final id = staff?.staffId;
    if (session.locked) {
      // locked for standing idle: everything stays where it is, under the sign-in pad
      _lockedId ??= session.lockedFrom?.staffId;
      _staffId = null;
      return;
    }
    final unlocked = _lockedId;
    _lockedId = null;
    if (unlocked != null && id == unlocked) {
      _staffId = id; // back at their own screen: as they left it
      return;
    }
    if (id == _staffId && unlocked == null) return;
    final before = unlocked ?? _staffId;
    _staffId = id;
    // a switch from one person to another: by face or tag while signed in, or by any sign-in at a locked screen
    final hello =
        before != null && staff != null && (unlocked != null || staff.method == 'face' || staff.method == 'tag')
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
