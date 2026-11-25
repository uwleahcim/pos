import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// A tiny round badge for a map service that lists addresses (docs/delivery.md, "A list of addresses while
/// typing"): the service's first letter in a circle, and a ring around it for how much of its free amount
/// is left this month. The ring is whole at the start of a month and unwinds counter-clockwise to twelve
/// o'clock as lookups are used, like a table's countdown on the floor plan; amber when a fifth is left, red
/// when nearly none. Pressed or hovered, it says who it is and how many lookups are left.
///
/// It stands where nothing moves it: at the top of the list, in the column of the lines' little pictures,
/// never after an address, whose length changes with every letter (Mike, 2026-11-25).
class ServiceBadge extends StatelessWidget {
  const ServiceBadge({super.key, required this.service, required this.title, this.share, this.words});

  /// The hub's name for the service (`geocodio`, `google`, `mapbox`, `azure`), and what a screen calls it.
  final String service;
  final String title;

  /// How much of the month's free amount is left (of the day's lookups, for a service that is asked a
  /// delivery's drive), from 1 (all of it) to 0; null where the hub did not say.
  final double? share;

  /// What is left, in words, for the tooltip and for a reader ("9,412 of 9,500 free lookups left this month").
  final String? words;

  static const size = 20.0;

  /// The letter in the circle; two for Geocodio, which Google has the G of.
  static String letterOf(String service, String title) => switch (service) {
    'geocodio' => 'Ge',
    'google' => 'G',
    'mapbox' => 'M',
    'azure' => 'A',
    _ => title.isEmpty ? '?' : title.substring(0, 1).toUpperCase(),
  };

  /// The ring's colour for what is left.
  static Color ringColor(BuildContext context, double share) {
    final colors = PosColors.of(context);
    if (share <= 0.05) return colors.timerLate;
    if (share <= 0.2) return colors.timerWarn;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final said = words == null ? title : '$title: $words';
    final left = share?.clamp(0.0, 1.0);
    final letter = letterOf(service, title);
    return Tooltip(
      message: said,
      triggerMode: TooltipTriggerMode.tap,
      excludeFromSemantics: true, // a reader hears the same words once, below
      child: Semantics(
        container: true,
        label: said,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _RingPainter(
              share: left,
              track: scheme.outlineVariant,
              ring: left == null ? scheme.outlineVariant : ringColor(context, left),
            ),
            child: Center(
              child: Text(
                letter,
                textScaler: TextScaler.noScaling, // a picture, not words: it keeps its size
                style: TextStyle(
                  fontSize: letter.length > 1 ? 8 : 10,
                  height: 1,
                  letterSpacing: letter.length > 1 ? -0.3 : null,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.share, required this.track, required this.ring});

  final double? share;
  final Color track;
  final Color ring;

  static const width = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final box = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = track;
    canvas.drawOval(box, paint);
    final left = share;
    if (left == null || left <= 0) return;
    // what is left, from twelve o'clock round: it unwinds counter-clockwise as lookups are used
    paint
      ..color = ring
      ..strokeCap = left >= 1 ? StrokeCap.butt : StrokeCap.round;
    canvas.drawArc(box, -math.pi / 2, 2 * math.pi * left, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share || old.track != track || old.ring != ring;
}
