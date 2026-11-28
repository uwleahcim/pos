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
///
/// With a search ([find]) the words it was searched for are marked wherever the paper has them, as with a
/// marker pen.
///
/// A paper does not change, so it is drawn once: the screen around it can be drawn again as often as it
/// likes (a list with fifty papers open is), and the paper is only drawn again for another paper, another
/// search, another width or another text size.
class PaperView extends StatefulWidget {
  const PaperView({super.key, required this.pages, this.width = 340, this.find});

  final List<List<PaperStep>> pages;

  /// How wide the paper is drawn at most, before the reader's text size.
  final double width;

  /// The search whose words are marked on the paper; none without.
  final PrintFind? find;

  static const paper = Color(0xFFFFFEFA);
  static const ink = Color(0xFF1A1A1A);

  /// The marker a search's words are marked with, and the words on it: on the paper and in the lines of
  /// the log, the same in a light room and a dark one.
  static const marker = Color(0xFFFFD84D);
  static const marked = TextStyle(backgroundColor: marker, color: ink);

  /// How many letters fit on a line of an 80 mm paper, and how wide a letter of the paper's kind is for
  /// its size.
  static const columns = 48;
  static const _advance = 0.602;
  static const _margin = 12.0;

  @override
  State<PaperView> createState() => _PaperViewState();
}

class _PaperViewState extends State<PaperView> {
  Widget? _drawn; // the paper as it was last drawn, for [_scale]
  double? _scale;

  @override
  void didUpdateWidget(PaperView old) {
    super.didUpdateWidget(old);
    if (!identical(old.pages, widget.pages) || old.find != widget.find || old.width != widget.width) _drawn = null;
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    if (scale != _scale) _drawn = null;
    _scale = scale;
    final (pages, width, find) = (widget.pages, widget.width, widget.find);
    return _drawn ??= LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth.isFinite ? box.maxWidth.clamp(160.0, width * scale) : width * scale;
        final letter = (wide - 2 * PaperView._margin) / PaperView.columns;
        return MediaQuery.withNoTextScaling(
          child: SizedBox(
            width: wide,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (n, page) in pages.indexed) ...[
                  if (n > 0) const SizedBox(height: 10),
                  _Sheet(steps: page, letter: letter, find: find),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A line's words with the places a search found on it ([hits], first to last) in the [marked] style, and
/// the rest as it was.
List<InlineSpan> markedSpans(String words, List<TextRange> hits, {TextStyle marked = PaperView.marked}) {
  final spans = <InlineSpan>[];
  var at = 0;
  for (final hit in hits) {
    if (hit.start > at) spans.add(TextSpan(text: words.substring(at, hit.start)));
    spans.add(TextSpan(text: words.substring(hit.start, hit.end), style: marked));
    at = hit.end;
  }
  if (at < words.length) spans.add(TextSpan(text: words.substring(at)));
  return spans;
}

/// One paper: its steps down to the cut.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.steps, required this.letter, this.find});

  final List<PaperStep> steps;

  /// How wide one letter of the paper's ordinary size is drawn.
  final double letter;
  final PrintFind? find;

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

  /// Words of the paper, with the places a search found on them marked.
  static Widget _words(String words, TextStyle style, List<TextRange> hits, {TextAlign align = TextAlign.start}) =>
      hits.isEmpty
      ? Text(words, style: style, textAlign: align)
      : Text.rich(
          TextSpan(children: markedSpans(words, hits)),
          style: style,
          textAlign: align,
        );

  Widget _line(PaperStep step) {
    final words = _words(
      step.text.isEmpty ? ' ' : step.text,
      _style(step, inverted: step.invert),
      find?.on(step.text) ?? const [],
      align: step.center ? TextAlign.center : TextAlign.start,
    );
    if (!step.invert) return SizedBox(width: double.infinity, child: words);
    return Container(width: double.infinity, color: PaperView.ink, child: words);
  }

  Widget _columns(PaperStep step) {
    final (left, right) = find?.across(step.text, step.right) ?? const (<TextRange>[], <TextRange>[]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _words(step.text, _style(step), left)),
        SizedBox(width: letter),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: letter * PaperView.columns * 0.6),
          child: _words(step.right, _style(step), right, align: TextAlign.end),
        ),
      ],
    );
  }

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
