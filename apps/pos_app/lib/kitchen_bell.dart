/// The sound of a kitchen screen (docs/kitchen-screens.md): a chime when a ticket comes in, the way a ticket
/// printer is heard across the kitchen. A screen is looked at when it sounds, so it sounds for whatever a
/// cook has to read anew: a new ticket, a dish of a ticket voided or changed after it was sent, an allergy
/// told late. It stays quiet for the kitchen's own taps (a dish made, a ticket recalled) and for a ticket
/// that only leaves.
library;

import 'dart:async';

import 'kitchen_screen.dart';

/// Something that can make the sound once: the asset player on a device, a fake in tests.
abstract interface class Chime {
  Future<void> play();
}

/// What of a board a cook reads: each ticket standing on it, and of each dish what the paper would say.
/// Whether a dish is made is not among it, so a tap adds nothing here; neither is the table or the seat.
Set<String> kitchenReads(KitchenBoard board, {bool recent = false}) => {
  for (final ticket in recent ? board.recent : board.tickets) ...[
    ticket.id,
    if (ticket.allergies.isNotEmpty) '${ticket.id}\nallergies\n${ticket.allergies.join('\n')}',
    for (final line in ticket.lines)
      [
        ticket.id,
        line.lineId,
        line.qty,
        line.label,
        line.modifiers.join('\n'),
        line.note,
        line.allergy,
        if (line.isVoid) 'void',
      ].join('\n'),
  ],
};

/// Sounds the chime for what came onto a kitchen screen since it was last looked at. One for the app, for
/// as long as it runs: the screen itself goes away whenever somebody signs in on the device, and what came
/// in meanwhile sounds when it stands again.
class KitchenBell {
  KitchenBell(this._chime, {this.quiet});

  final Chime _chime;

  /// Says when the device must not sound, whatever came in: it is on a call.
  final bool Function()? quiet;

  String? _screen; // the screen whose tickets it knows
  Set<String> _known = const {}; // what stood on it at the last look, finished tickets too

  /// The chime by itself, for whoever sets the device up to hear how loud it is.
  Future<void> play() => _chime.play();

  /// Looks at what [screen] (its stations, and whether it is the pass) just read from the hub, and sounds
  /// once if anything on a ticket still to make is new to it; however many tickets came, it is one chime.
  /// The first look at a screen is silent: those tickets were there before anybody listened. With [on]
  /// false it only remembers what it saw, so switching the sound on later sounds for nothing old.
  ///
  /// Returns whether anything was new.
  bool heard(String screen, KitchenBoard board, {bool on = true}) {
    final open = kitchenReads(board);
    final news = _screen == screen && open.any((read) => !_known.contains(read));
    _screen = screen;
    // (a ticket brought back from the finished ones is nothing new, so those are remembered as well)
    _known = {...open, ...kitchenReads(board, recent: true)};
    if (news && on && !(quiet?.call() ?? false)) unawaited(_chime.play());
    return news;
  }
}
