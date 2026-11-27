import 'package:flutter/material.dart';

import '../print_log.dart';

/// A paper as it came out of a printer, drawn on the screen from the steps the hub wrote down
/// ([PaperStep]): the same lines, big where the paper is big, white on black where the paper is, the rules
/// and the gaps, and a torn edge where the printer cut. Several papers of one job (an order's bag labels)
/// stand one under the other.
///
/// It is a picture of the paper, so it is paper in a dark room too, and its letters are a printer's: one
/// width each, forty-eight to the line, sized to the paper's width. The paper takes the width it is given,
/// up to [width] at the reader's text size.
class PaperView extends StatelessWidget {
  const PaperView({super.key, required this.pages, this.width = 340});

  final List<List<PaperStep>> pages;

  /// How wide the paper is drawn at most, before the reader's text size.
  final double width;

  static const paper = Color(0xFFFFFEFA);
  static const ink = Color(0xFF1A1A1A);

  /// How many letters fit on a line of an 80 mm paper, and how wide a letter of the paper's kind is for
  /// its size.
  static const columns = 48;
  static const _advance = 0.602;
  static const _margin = 12.0;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth.isFinite ? box.maxWidth.clamp(160.0, width * scale) : width * scale;
        final letter = (wide - 2 * _margin) / columns;
        return MediaQuery.withNoTextScaling(
          child: SizedBox(
            width: wide,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (n, page) in pages.indexed) ...[
                  if (n > 0) const SizedBox(height: 10),
                  _Sheet(steps: page, letter: letter),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One paper: its steps down to the cut.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.steps, required this.letter});

  final List<PaperStep> steps;

  /// How wide one letter of the paper's ordinary size is drawn.
  final double letter;

  TextStyle _style(PaperStep step, {bool inverted = false}) {
    final size = letter / PaperView._advance * (step.big ? 2 : 1);
    return TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['monospace', 'Roboto Mono', 'Courier New', 'Courier'],
      fontSize: size,
      height: 1.25,
      fontWeight: step.bold ? FontWeight.w700 : FontWeight.w400,
      color: inverted ? PaperView.paper : PaperView.ink,
      letterSpacing: 0,
    );
  }

  Widget _line(PaperStep step) {
    final words = Text(
      step.text.isEmpty ? ' ' : step.text,
      style: _style(step, inverted: step.invert),
      textAlign: step.center ? TextAlign.center : TextAlign.start,
    );
    if (!step.invert) return SizedBox(width: double.infinity, child: words);
    return Container(width: double.infinity, color: PaperView.ink, child: words);
  }

  Widget _columns(PaperStep step) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: Text(step.text, style: _style(step))),
      SizedBox(width: letter),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: letter * PaperView.columns * 0.6),
        child: Text(step.right, style: _style(step), textAlign: TextAlign.end),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final row = letter / PaperView._advance * 1.25; // the height of one ordinary line
    final rows = <Widget>[];
    for (final step in steps) {
      switch (step.kind) {
        case 'line':
          rows.add(_line(step));
        case 'cols':
          rows.add(_columns(step));
        case 'rule':
          rows.add(
            SizedBox(
              height: row,
              width: double.infinity,
              child: CustomPaint(painter: _Dashes(letter)),
            ),
          );
        case 'feed':
          rows.add(SizedBox(height: row * step.count.clamp(0, 6)));
      }
      // a cut ends the paper, and a beep and a drawer pulse leave no mark on it
    }
    return PhysicalShape(
      clipper: const _TornEdge(),
      color: PaperView.paper,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(PaperView._margin, 14, PaperView._margin, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }
}

/// A printed rule: a row of dashes across the paper.
class _Dashes extends CustomPainter {
  const _Dashes(this.letter);

  final double letter;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = PaperView.ink
      ..strokeWidth = 1;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += letter) {
      canvas.drawLine(Offset(x + letter * 0.15, y), Offset(x + letter * 0.85, y), stroke);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.letter != letter;
}

/// The paper's outline: straight at the top and the sides, and the teeth of the printer's cutter along the
/// bottom.
class _TornEdge extends CustomClipper<Path> {
  const _TornEdge();

  static const _tooth = 8.0;
  static const _depth = 5.0;

  @override
  Path getClip(Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - _depth);
    final teeth = (size.width / _tooth).ceil();
    final each = size.width / teeth;
    for (var n = teeth; n > 0; n--) {
      path
        ..lineTo((n - 0.5) * each, size.height)
        ..lineTo((n - 1) * each, size.height - _depth);
    }
    return path..close();
  }

  @override
  bool shouldReclip(_TornEdge old) => false;
}
