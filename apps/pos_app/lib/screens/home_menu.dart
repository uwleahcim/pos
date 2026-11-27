import 'package:flutter/material.dart';

import 'compact.dart';
import 'home_bar.dart';
import 'theme.dart';

/// The menu behind **More** on the home screen (docs/home-screen.md): who is signed in with **Sign out**
/// beside them, and under that every way out of the screen as a tile, in its group. On a phone it comes up
/// from the bottom, where the thumb is; on a tablet or a Mac it opens under the button, at the top right.
///
/// It answers what was tapped (an entry's own action, or [onSignOut]) once it is closed, for the screen
/// underneath to do; null when it was closed with nothing tapped.
Future<VoidCallback?> showHomeMenu(
  BuildContext context, {
  required String name,
  required String role,
  required String device,
  required List<HomeEntry> entries,
  required VoidCallback onSignOut,
}) {
  Widget menu(BuildContext context) =>
      HomeMenu(name: name, role: role, device: device, entries: entries, onSignOut: onSignOut);
  if (compact(context)) {
    return showModalBottomSheet<VoidCallback>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: menu(context)),
      ),
    );
  }
  return showGeneralDialog<VoidCallback>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'More',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) {
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Material(
              key: const ValueKey('home-menu'),
              color: scheme.surfaceContainerLowest,
              elevation: 10,
              shadowColor: Colors.black54,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 580),
                child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: menu(context)),
              ),
            ),
          ),
        ),
      );
    },
    // it grows out of the corner its button is in
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          alignment: Alignment.topRight,
          child: child,
        ),
      );
    },
  );
}

/// What the menu shows: the person, and the tiles by group. A group with nothing in it for the person
/// signed in takes no room.
class HomeMenu extends StatelessWidget {
  const HomeMenu({
    super.key,
    required this.name,
    required this.role,
    required this.device,
    required this.entries,
    required this.onSignOut,
  });

  final String name;
  final String role;
  final String device;
  final List<HomeEntry> entries;
  final VoidCallback onSignOut;

  /// The least a tile is wide before the menu gives each row one tile fewer, at ordinary type.
  static const _tileWidth = 150.0;
  static const _spacing = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final first = entries.firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(
                name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase(),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
                textScaler: TextScaler.noScaling,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    [if (role.isNotEmpty) role, if (device.isNotEmpty) device].join(' · '),
                    key: const ValueKey('home-menu-who'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('home-menu-sign-out'),
              onPressed: () => Navigator.of(context).pop(onSignOut),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign out'),
            ),
          ],
        ),
        for (final section in HomeSection.values)
          if (entries.any((entry) => entry.section == section)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
              child: Text(
                section.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                // As many across as the width takes; larger type takes fewer, so the words keep their room.
                final across = (constraints.maxWidth / (_tileWidth * scale)).floor().clamp(1, 4);
                final width = (constraints.maxWidth - _spacing * (across - 1)) / across;
                return Wrap(
                  spacing: _spacing,
                  runSpacing: _spacing,
                  children: [
                    for (final entry in entries)
                      if (entry.section == section)
                        SizedBox(
                          width: width,
                          child: HomeTile(
                            key: ValueKey('home-tile:${entry.id}'),
                            entry: entry,
                            // the keyboard starts on the first tile: arrows, Enter, and Escape to close
                            autofocus: identical(entry, first),
                            onTap: () => Navigator.of(context).pop(entry.onTap),
                          ),
                        ),
                  ],
                );
              },
            ),
          ],
      ],
    );
  }
}

/// A tile of the menu: the entry's icon in the colour of its group with its count on the corner, its name,
/// and under the name what is going on behind it. A switch that is on is filled.
class HomeTile extends StatelessWidget {
  const HomeTile({super.key, required this.entry, required this.onTap, this.autofocus = false});

  final HomeEntry entry;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pos = PosColors.of(context);
    final on = entry.on;
    final (tint, ink) = on
        ? (scheme.primary, scheme.onPrimary)
        : switch (entry.section) {
            HomeSection.service => (scheme.primaryContainer, scheme.onPrimaryContainer),
            HomeSection.shift => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
            HomeSection.manage => (pos.fired, pos.firedText),
            HomeSection.device => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
          };
    final note = entry.note;
    final (countFill, countInk) = levelColors(context, entry.level);
    return PressableScale(
      pressedScale: 0.97,
      child: Material(
        color: on ? scheme.primaryContainer : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 1.6 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          autofocus: autofocus,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 10, 8),
              child: Row(
                children: [
                  // its count on the corner of its icon, as an app's icon carries one; a dot where
                  // something wants a look and there is nothing to count
                  Badge(
                    key: entry.count > 0 ? ValueKey('home-count:${entry.id}:${entry.level.name}') : null,
                    isLabelVisible: entry.count > 0 || entry.attention,
                    label: entry.count > 0 ? Text(entry.count > 99 ? '99+' : '${entry.count}') : null,
                    smallSize: 10,
                    backgroundColor: entry.count > 0 ? countFill : scheme.error,
                    textColor: countInk,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(11)),
                      child: Icon(entry.icon, size: 22, color: ink),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label,
                          // a name alone may take the note's line too
                          maxLines: note == null ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: on ? scheme.onPrimaryContainer : scheme.onSurface,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        if (note != null)
                          Text(
                            note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                              height: 1.25,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
