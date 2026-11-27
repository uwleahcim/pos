import 'package:flutter/material.dart';

import '../table_timers.dart' show TimerLevel;
import 'compact.dart';
import 'home_menu.dart';
import 'theme.dart';

/// Where a way out of the home screen stands in its menu (docs/home-screen.md): the groups, in the order
/// the menu lists them.
enum HomeSection {
  service('Guests & orders'),
  shift('Shift'),
  manage('Manager'),
  device('This device');

  const HomeSection(this.label);

  /// The words over the group in the menu.
  final String label;
}

/// One way out of the home screen: a screen or a dialog it opens, or something it switches. Every one of
/// them is a tile of the menu behind **More**, under its [section]. A [quick] one also stands in the bar of
/// a tablet or a Mac while the bar has the room.
///
/// A new feature adds one of these to the list in `orders_screen.dart` and nothing else: the bar and the
/// menu lay themselves out.
@immutable
class HomeEntry {
  const HomeEntry(
    this.id,
    this.label,
    this.icon,
    this.onTap, {
    this.section = HomeSection.service,
    this.note,
    this.count = 0,
    this.level = TimerLevel.ok,
    this.on = false,
    this.attention = false,
    this.quick = false,
  });

  /// What the tests and the keys call it ("ahead"): it stays when the words change.
  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final HomeSection section;

  /// A few words under the label on its tile: what is going on behind it ("3 waiting").
  final String? note;

  /// A number on its tile (parties waiting), in the colour of its [level]; 0 shows none.
  final int count;
  final TimerLevel level;

  /// It is a switch, and it is on: its tile is filled.
  final bool on;

  /// Something behind it wants a look: a dot on its tile, and on **More** while it is not in the bar.
  final bool attention;

  /// It may stand in the bar where the bar is wide enough.
  final bool quick;
}

/// The waitlist's button as the bar shows it: the icon with its counts, what it says when pointed at, and
/// where it leads. The orders screen draws the icon, since the counts and their colours are its to know;
/// it is asked whether the icon stands beside its word in an outline, where the counts keep inside it.
@immutable
class HomeWaitlist {
  const HomeWaitlist({required this.icon, required this.tooltip, required this.onTap});

  final Widget Function({required bool worded}) icon;
  final String tooltip;
  final VoidCallback onTap;
}

/// The bar of the home screen, one row (docs/home-screen.md).
///
/// From the left: the camera's picture (the sign that the person at the screen may be photographed, and it
/// must be on the screen for the camera to run) with who is signed in; the switch between the floor map
/// and the list of checks, which shows the one that is up; then, pushed to the right, the buttons a
/// service needs in one tap, the connection, and **More**, behind which is everything else as a menu of
/// tiles ([showHomeMenu]).
///
/// A phone keeps to icons: the waitlist's button (while [waitlist] is given), the connection and More. A
/// tablet or a Mac also names the device under the person, has **Sign out** beside them, and puts the
/// [HomeEntry.quick] entries in the bar: with their words while all of them fit, as icons while they do not,
/// and the last of them only in the menu when even the icons do not. So the bar never runs off the screen,
/// however many entries there are.
class HomeBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeBar({
    super.key,
    required this.name,
    required this.role,
    required this.device,
    required this.camera,
    required this.floor,
    required this.onFloor,
    required this.status,
    required this.entries,
    required this.onSignOut,
    this.waitlist,
  });

  /// Who is signed in, their role as the staff list names it ("Manager"), and this device's name.
  final String name;
  final String role;
  final String device;

  /// The camera's live picture.
  final Widget camera;

  /// Whether the floor map is up (the list of checks otherwise), and what a tap on the other one calls.
  final bool floor;
  final ValueChanged<bool> onFloor;

  /// The connection's icon.
  final Widget status;

  /// Every way out of the screen, in the order the menu lists them within each group.
  final List<HomeEntry> entries;
  final VoidCallback onSignOut;

  /// The waitlist's button, while it stands in the bar.
  final HomeWaitlist? waitlist;

  static const _gap = 6.0;
  static const _nameAtLeast = 56.0;
  static const _nameAtMost = 150.0;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  Future<void> _more(BuildContext context) async {
    final action = await showHomeMenu(
      context,
      name: name,
      role: role,
      device: device,
      entries: entries,
      onSignOut: onSignOut,
    );
    action?.call();
  }

  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: false,
    titleSpacing: 0,
    // the row is the whole of the bar: nothing of it is the bar's own title or actions
    title: SizedBox(
      height: kToolbarHeight,
      child: LayoutBuilder(builder: (context, constraints) => _row(context, constraints.maxWidth)),
    ),
  );

  /// The row for a bar [width] wide. What each thing takes is worked out here, from the screen's own type,
  /// so nothing is asked to fit that cannot: the name gives way first (it fades, then is its first letter,
  /// then is gone), then the words of the switch and of the buttons, then the last of the quick buttons.
  /// The waitlist, the connection and More give way to nothing; in the one case left (a phone 320 wide
  /// whose softphone also cannot register) they are drawn a little smaller.
  Widget _row(BuildContext context, double width) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = compact(context);
    final wait = waitlist;
    final quick = small
        ? const <HomeEntry>[]
        : [
            for (final entry in entries)
              if (entry.quick) entry,
          ];
    // how wide an icon's button is here: a finger's on a phone or a tablet, tighter under a mouse
    final button = theme.materialTapTargetSize == MaterialTapTargetSize.padded ? 48.0 : 40.0;
    final nameStyle = theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.15);
    final deviceStyle = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.15);

    final more = IconButton(
      key: const ValueKey('home-more'),
      tooltip: 'More',
      onPressed: () => _more(context),
      icon: Badge(
        // something in the menu wants a look, and nothing in the bar says so
        isLabelVisible: entries.any((entry) => entry.attention && (small || !entry.quick)),
        smallSize: 9,
        backgroundColor: scheme.error,
        child: const Icon(Icons.grid_view_rounded),
      ),
    );
    final side = small ? 36.0 : 40.0;
    final picture = Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: camera),
    );
    // The name whole where it fits; fading out at the edge where most of it does; where there is room for
    // a letter or two (a small phone set to large type), its first letter alone; and with no room for
    // that, nothing: the menu behind More says who is signed in on every screen.
    final nameWide = _wide(context, name, nameStyle);
    bool named(double room) => room >= nameWide || room >= _nameAtLeast;
    Widget who(double room) => !named(room) && room < MediaQuery.textScalerOf(context).scale(nameStyle?.fontSize ?? 16)
        ? const SizedBox.shrink()
        : Text(
            named(room) || name.trim().isEmpty ? name : name.trim().characters.first,
            key: const ValueKey('home-name'),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: nameStyle,
          );
    // The end of the row, against its right edge. It is the one part that may be drawn smaller.
    Widget end(List<Widget> buttons) => Expanded(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Row(mainAxisSize: MainAxisSize.min, children: [...buttons, status, more]),
      ),
    );
    // what gives way to nothing: the waitlist while it is in the row, the connection, More
    final kept = (wait == null ? 2 : 3) * button;

    if (small) {
      // the waitlist's count of booked tables hangs off its icon's left: room for it
      final beforeEnd = wait == null ? 2.0 : 8.0;
      final lead = 12 + side + 8;
      final room = width - lead - _gap - ViewSwitch.widthOf(context, labeled: false) - beforeEnd - kept - 4;
      return Row(
        children: [
          const SizedBox(width: 12),
          picture,
          const SizedBox(width: 8),
          SizedBox(
            width: room.clamp(0, double.infinity),
            child: Align(alignment: Alignment.centerLeft, child: who(room)),
          ),
          const SizedBox(width: _gap),
          ViewSwitch(floor: floor, onFloor: onFloor),
          SizedBox(width: beforeEnd),
          end([
            if (wait != null)
              IconButton(
                key: const ValueKey('waitlist-open'),
                tooltip: wait.tooltip,
                onPressed: wait.onTap,
                icon: wait.icon(worded: false),
              ),
          ]),
          const SizedBox(width: 4),
        ],
      );
    }

    // A tablet or a Mac. Everything but the name and the switch, up to the quick buttons:
    final lead = 12 + side + 10 + button + _gap + _gap + 4;
    final person = [
      nameWide,
      if (device.isNotEmpty) _wide(context, device, deviceStyle),
    ].fold<double>(0, (most, one) => one > most ? one : most).clamp(0.0, _nameAtMost);
    // The switch has its words while the name, what is kept and every quick button as an icon still fit.
    final worded = ViewSwitch.widthOf(context, labeled: true);
    final wordedSwitch = width - lead - worded - person - kept - quick.length * button >= 0;
    final view = wordedSwitch ? worded : ViewSwitch.widthOf(context, labeled: false);
    final nameRoom = (width - lead - view - kept).clamp(0.0, person);
    // What is left for the quick buttons and the waitlist's: with their words while all of them fit, as
    // icons otherwise, and then the waitlist first and as many of the others as fit, in their order.
    final room = width - lead - view - nameRoom - 2 * button;
    final words = [for (final entry in quick) entry.label, if (wait != null) 'Waitlist'];
    final asWords = words.fold<double>(0, (sum, label) => sum + HomePill.widthOf(context, label)) + _gap * words.length;
    final labeled = words.isNotEmpty && asWords <= room;
    final most = labeled ? quick.length : ((room - (wait == null ? 0 : button)) / button).floor();
    final shown = quick.take(most.clamp(0, quick.length)).toList();
    return Row(
      children: [
        const SizedBox(width: 12),
        picture,
        const SizedBox(width: 10),
        SizedBox(
          width: nameRoom,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              who(nameRoom),
              if (device.isNotEmpty && named(nameRoom))
                Text(device, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: deviceStyle),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('home-sign-out'),
          tooltip: 'Sign out',
          onPressed: onSignOut,
          icon: const Icon(Icons.logout_rounded),
        ),
        const SizedBox(width: _gap),
        ViewSwitch(floor: floor, onFloor: onFloor, labeled: wordedSwitch),
        const SizedBox(width: _gap),
        end([
          for (final entry in shown) ...[
            HomePill(
              key: ValueKey('home-quick:${entry.id}'),
              icon: Badge(
                isLabelVisible: entry.attention,
                smallSize: 9,
                backgroundColor: scheme.error,
                child: Icon(entry.icon, size: 22),
              ),
              label: entry.label,
              labeled: labeled,
              onTap: entry.onTap,
            ),
            if (labeled) const SizedBox(width: _gap),
          ],
          if (wait != null) ...[
            HomePill(
              key: const ValueKey('waitlist-open'),
              icon: wait.icon(worded: labeled),
              label: 'Waitlist',
              tooltip: wait.tooltip,
              labeled: labeled,
              onTap: wait.onTap,
            ),
            if (labeled) const SizedBox(width: _gap),
          ],
        ]),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// How wide [words] are in [style], as this screen sets its type.
double _wide(BuildContext context, String words, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: words, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width.ceilToDouble() + 1;
}

/// The switch between the floor map and the list of checks: two halves side by side, the one that is up
/// raised and in the restaurant's colour, so the bar says where the screen is and the other half is where
/// it goes. With [labeled] each half has its word; a phone has the icons alone.
class ViewSwitch extends StatelessWidget {
  const ViewSwitch({super.key, required this.floor, required this.onFloor, this.labeled = false});

  final bool floor;
  final ValueChanged<bool> onFloor;
  final bool labeled;

  static const _floorWord = 'Floor';
  static const _checksWord = 'Checks';
  static const _edge = 3.0; // around the two halves
  static const _between = 2.0;
  static const _icon = 22.0;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700);

  /// How wide a half is: its icon, and with [word] the word, set in the weight of the half that is up so a
  /// tap does not move anything.
  static double _half(BuildContext context, String? word) =>
      word == null ? 2 + 2 * 9 + _icon : 2 + 2 * 12 + _icon + 6 + _wide(context, word, _style(context));

  /// How wide the switch is, with its words or without.
  static double widthOf(BuildContext context, {required bool labeled}) =>
      2 * _edge + _between + _half(context, labeled ? _floorWord : null) + _half(context, labeled ? _checksWord : null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('home-view'),
      height: 40,
      padding: const EdgeInsets.all(_edge),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(13)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _side(context, forFloor: true, tooltip: 'Floor map', word: _floorWord, icon: Icons.table_restaurant_rounded),
          const SizedBox(width: _between),
          _side(context, forFloor: false, tooltip: 'List of checks', word: _checksWord, icon: Icons.list_alt_rounded),
        ],
      ),
    );
  }

  Widget _side(
    BuildContext context, {
    required bool forFloor,
    required String tooltip,
    required String word,
    required IconData icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final up = floor == forFloor;
    final ink = up ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: up,
        label: tooltip,
        excludeSemantics: true,
        // The half is as wide as it is at once: a screen turned on its side gains the words in one step,
        // with no moment in which they do not fit. Only its raising is animated.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: up ? scheme.surfaceContainerLowest : scheme.surfaceContainerLowest.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: up ? scheme.outlineVariant : scheme.outlineVariant.withValues(alpha: 0)),
          ),
          child: SizedBox(
            // less the outline, which is drawn inside it
            width: _half(context, labeled ? word : null) - 2,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey(forFloor ? 'home-view:floor' : 'home-view:checks'),
                borderRadius: BorderRadius.circular(10),
                // a tap on the half that is up changes nothing
                onTap: () => up ? null : onFloor(forFloor),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: _icon, color: ink),
                    if (labeled) ...[
                      const SizedBox(width: 6),
                      Text(
                        word,
                        maxLines: 1,
                        softWrap: false,
                        style: _style(context)
                            ?.copyWith(color: ink, fontWeight: up ? FontWeight.w700 : FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A button of the bar: an icon with its word beside it in a rounded outline, or, not [labeled], the icon
/// alone, which says its word when pointed at. [tooltip] is said instead where it says more than the word
/// (the waitlist's counts).
class HomePill extends StatelessWidget {
  const HomePill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.labeled = true,
  });

  final Widget icon;
  final String label;
  final String? tooltip;
  final bool labeled;
  final VoidCallback onTap;

  static const _pad = 12.0;
  static const _iconRoom = 24.0;
  static const _iconGap = 8.0;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600);

  /// How wide the button is with its word [label], as this screen sets its type.
  static double widthOf(BuildContext context, String label) =>
      _pad * 2 + _iconRoom + _iconGap + _wide(context, label, _style(context)) + 2; // and its outline

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!labeled) {
      return IconButton(tooltip: tooltip ?? label, onPressed: onTap, icon: icon);
    }
    final button = Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _pad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: _iconRoom,
                  child: IconTheme.merge(
                    data: IconThemeData(color: scheme.onSurfaceVariant),
                    child: Center(child: icon),
                  ),
                ),
                const SizedBox(width: _iconGap),
                Text(label, maxLines: 1, softWrap: false, style: _style(context)),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// A count in the colour of its level, as the waitlist's badge has it: the restaurant's colour while all is
/// well, amber when something is near its time and red when it is past it.
(Color, Color) levelColors(BuildContext context, TimerLevel level) {
  final scheme = Theme.of(context).colorScheme;
  final pos = PosColors.of(context);
  return switch (level) {
    TimerLevel.ok => (scheme.primary, scheme.onPrimary),
    TimerLevel.warn => (pos.timerWarn, pos.timerWarnText),
    TimerLevel.late => (pos.timerLate, pos.timerLateText),
  };
}
