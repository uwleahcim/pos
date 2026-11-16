import 'package:flutter/material.dart';

import '../idle_lock.dart';
import '../session.dart';

/// Tells the idle lock that someone is at the screen: a finger or a click going down, a drag, the mouse
/// moving over the app, the wheel. It only looks: every touch goes on to what it was meant for. (Keys are
/// the lock's own to hear, wherever the keyboard's focus is.)
class Touches extends StatelessWidget {
  const Touches({super.key, required this.lock, required this.child});

  /// The device's idle lock; null on a screen without one, which then only shows [child].
  final IdleLock? lock;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lock = this.lock;
    if (lock == null) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => lock.touched(),
      onPointerMove: (_) => lock.touched(),
      onPointerHover: (_) => lock.touched(),
      onPointerSignal: (_) => lock.touched(),
      child: child,
    );
  }
}

/// The app's screens, and over them the sign-in pad ([pad]) while the screen is locked for standing idle
/// ([Session.locked]). The screens stay as they are underneath, built and unchanged, so the person who
/// comes back finds what they left; they take no touch and no key meanwhile (a badge reader's typing lands
/// nowhere). The pad lies over the navigator itself, so nothing a screen opens while locked (an order for
/// a call picked up on the desk phone beside it) can come up in front of it.
class LockLayer extends StatelessWidget {
  const LockLayer({super.key, required this.session, required this.pad, required this.child});

  final Session session;
  final WidgetBuilder pad;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    child: child,
    builder: (context, child) {
      final locked = session.locked;
      return Stack(
        fit: StackFit.expand,
        children: [
          // always here, in the same place, so locking and unlocking never builds the screens anew
          IgnorePointer(
            ignoring: locked,
            child: ExcludeFocus(
              excluding: locked,
              child: ExcludeSemantics(excluding: locked, child: child),
            ),
          ),
          if (locked) KeyedSubtree(key: const ValueKey('lock-pad'), child: pad(context)),
        ],
      );
    },
  );
}
