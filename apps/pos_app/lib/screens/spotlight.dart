import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../setting_search.dart';

/// Takes whoever searched for a setting to it: the page under it is scrolled until the setting's [Spot] is
/// on the screen, and the setting is lit for a moment (a ring in the theme's colour that fades), so the eye
/// lands on it among everything else on the page.
///
/// Around a page that a search result opens, with the [spot] to look for once the page is up; or around a
/// page that stays, asked later with [SpotlightState.show]. The page itself knows nothing of it: a spot is
/// the key a setting's widget already has, or the words that head it. A page that is still reading from the
/// hub is waited for a little, and a long list that builds only what is near the screen is looked down.
/// A spot that is not on the page (a part of it that is not shown as things stand) lights nothing.
class Spotlight extends StatefulWidget {
  const Spotlight({super.key, this.spot, required this.child});

  /// What to bring up and light as soon as the page is there; null for nothing.
  final Spot? spot;

  final Widget child;

  /// The built widget [spot] names under [root], if there is one: the first with its key, or the first
  /// text that reads its words.
  static Element? find(Element root, Spot spot) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (spot.key != null) {
        final key = widget.key;
        if (key is ValueKey<String> && key.value == spot.key) found = element;
      } else if (widget is RichText && widget.text.toPlainText().trim() == spot.words) {
        found = element;
      }
      if (found == null) element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  @override
  State<Spotlight> createState() => SpotlightState();
}

class SpotlightState extends State<Spotlight> with SingleTickerProviderStateMixin {
  /// How long a page that is still loading is waited for before the search gives the spot up.
  static const _patience = Duration(milliseconds: 2500);

  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  Element? _lit; // what is lit now
  bool _words = false; // it is a line of text, which gets a little room around it
  RenderBox? _within; // the list it scrolls in: the ring is not drawn past where the list ends
  bool _sideways = false; // that list scrolls left and right
  int _turn = 0; // each ask counts on: an older one still on its way gives up

  @override
  void initState() {
    super.initState();
    final spot = widget.spot;
    if (spot != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(show(spot, arriving: true));
      });
    }
  }

  @override
  void dispose() {
    _turn++;
    _glow.dispose();
    super.dispose();
  }

  /// Brings [spot] onto the screen and lights it; [or] instead when [spot] is not on the page. True once
  /// it is lit, false when neither is there. [arriving] is for a page that is just opening: it is put at
  /// the spot at once, and the light waits until the page has come in. Otherwise the page scrolls there.
  /// With [focus], the keyboard goes on from the spot (not into a text box, which would bring a touch
  /// screen's keyboard up).
  Future<bool> show(Spot spot, {Spot? or, bool arriving = false, bool focus = false}) async {
    final turn = ++_turn;
    final found = await _seek(turn, [spot, ?or]);
    if (found == null || !mounted || turn != _turn) return false;
    // what is whole on the screen already is lit where it is: the page does not move for it
    if (!_inView(found)) {
      await Scrollable.ensureVisible(
        found,
        alignment: 0.2,
        duration: arriving ? Duration.zero : const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted || turn != _turn) return false;
    if (arriving) await _arrived();
    if (!mounted || turn != _turn || !found.mounted) return false;
    if (focus) _focusIn(found);
    final list = found.findAncestorStateOfType<ScrollableState>();
    setState(() {
      _lit = found;
      _words = found.widget is RichText;
      _within = list?.context.findRenderObject() as RenderBox?;
      _sideways = list != null && axisDirectionToAxis(list.axisDirection) == Axis.horizontal;
    });
    _glow.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && turn == _turn) setState(() => _lit = null);
    });
    return true;
  }

  /// The first of [spots] that is on the page. A page still loading is looked at again each frame for a
  /// while; a long list is looked down once, and again when it has grown.
  Future<Element?> _seek(int turn, List<Spot> spots) async {
    Element? look() {
      for (final spot in spots) {
        final found = Spotlight.find(context as Element, spot);
        if (found != null) return found;
      }
      return null;
    }

    Duration? began;
    double? looked; // the length of the list when it was last looked down
    while (mounted && turn == _turn) {
      var found = look();
      if (found != null) return found;
      final list = _list();
      if (list != null && list.maxScrollExtent != looked) {
        looked = list.maxScrollExtent;
        found = await _lookDown(turn, list, look);
        if (found != null) return found;
        if (!mounted || turn != _turn) return null;
      }
      final now = await _nextFrame();
      began ??= now;
      if (now - began > _patience) return null;
    }
    return null;
  }

  /// Done when the next frame is drawn, with the time that frame was drawn for.
  Future<Duration> _nextFrame() {
    final drawn = Completer<Duration>();
    SchedulerBinding.instance
      ..addPostFrameCallback(drawn.complete)
      ..scheduleFrame();
    return drawn.future;
  }

  /// The page's own list, when it has more than fits the screen: the first one down the page that scrolls
  /// up and down.
  ScrollPosition? _list() {
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) return;
      if (element case StatefulElement(state: final ScrollableState scrollable)) {
        final position = scrollable.position;
        if (position.axis == Axis.vertical && position.hasContentDimensions && position.maxScrollExtent > 0) {
          found = position;
          return;
        }
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  /// Goes down [list] a screen at a time, from its top, until [look] finds something: a list builds only
  /// the rows near the screen, so a row far down it is not there to be found before. Left where it was
  /// when nothing is found.
  Future<Element?> _lookDown(int turn, ScrollPosition list, Element? Function() look) async {
    final from = list.pixels;
    var at = list.minScrollExtent;
    while (true) {
      list.jumpTo(at);
      await _nextFrame();
      // the page went, or rebuilt its list, while this was looking
      if (!mounted || turn != _turn || !identical(_list(), list)) return null;
      final found = look();
      if (found != null) return found;
      if (at >= list.maxScrollExtent) break;
      at = math.min(at + list.viewportDimension * 0.8, list.maxScrollExtent);
    }
    list.jumpTo(from.clamp(list.minScrollExtent, list.maxScrollExtent));
    return null;
  }

  /// Whether [spot] is whole inside every list it scrolls in: nothing has to move for it to be seen.
  bool _inView(Element spot) {
    final drawn = spot.renderObject;
    if (drawn is! RenderBox || !drawn.attached || !drawn.hasSize) return false;
    final where = MatrixUtils.transformRect(drawn.getTransformTo(null), Offset.zero & drawn.size);
    BuildContext at = spot;
    while (true) {
      final list = at.findAncestorStateOfType<ScrollableState>();
      if (list == null) return true;
      final view = list.context.findRenderObject();
      if (view is! RenderBox || !view.hasSize) return false;
      final seen = MatrixUtils.transformRect(view.getTransformTo(null), Offset.zero & view.size);
      if (where.top < seen.top - 0.5 || where.bottom > seen.bottom + 0.5) return false;
      at = list.context;
    }
  }

  /// Done once the page has come in (a dialog fades in, a screen slides): a light that fades with it would
  /// be half gone before the page is there to see.
  Future<void> _arrived() async {
    final coming = ModalRoute.of(context)?.animation;
    if (coming == null || coming.status != AnimationStatus.forward) return;
    final there = Completer<void>();
    void heard(AnimationStatus status) {
      if (status != AnimationStatus.forward && !there.isCompleted) there.complete();
    }

    coming.addStatusListener(heard);
    await there.future;
    coming.removeStatusListener(heard);
  }

  /// The keyboard's focus goes to the first thing in [spot] that can hold it, so Enter and the arrows go on
  /// from the setting that was found.
  void _focusIn(Element spot) {
    for (final node in FocusManager.instance.rootScope.descendants) {
      if (node is FocusScopeNode || node.skipTraversal || !node.canRequestFocus) continue;
      final at = node.context;
      if (at == null || !at.mounted) continue;
      var inside = at == spot;
      if (!inside) {
        at.visitAncestorElements((above) {
          inside = above == spot;
          return !inside && above != context;
        });
      }
      if (!inside) continue;
      final box = at.findAncestorStateOfType<EditableTextState>();
      if (box != null && box.widget.focusNode == node) continue;
      node.requestFocus();
      return;
    }
  }

  /// Where the light is now, in this widget's own measure; null while nothing is lit.
  @visibleForTesting
  Rect? get litRect => _where();

  /// Where the lit spot is now, in this widget's own measure; null when it is gone.
  Rect? _where() {
    final lit = _lit;
    if (lit == null || !lit.mounted) return null;
    final spot = _rect(lit.renderObject);
    if (spot == null) return null;
    return _words ? spot.inflate(4).inflateXY(6, 0) : spot.inflate(2);
  }

  Rect? _rect(RenderObject? drawn) {
    final mine = context.findRenderObject();
    if (drawn is! RenderBox || mine is! RenderBox || !drawn.attached || !drawn.hasSize) return null;
    return MatrixUtils.transformRect(drawn.getTransformTo(mine), Offset.zero & drawn.size);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _lit == null ? null : _Ring(this, Theme.of(context).colorScheme.primary),
      child: widget.child,
    );
  }
}

extension on Rect {
  Rect inflateXY(double dx, double dy) => Rect.fromLTRB(left - dx, top - dy, right + dx, bottom + dy);
}

/// The light on a spot: a rounded ring with a tint inside, quickly up, held, and faded out. It is drawn
/// where the spot is at each frame, so it stays on it while the page moves.
class _Ring extends CustomPainter {
  _Ring(this.state, this.color) : super(repaint: state._glow);

  final SpotlightState state;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final where = state._where();
    if (where == null) return;
    final t = state._glow.value;
    final strength = (t < 0.07 ? t / 0.07 : (t > 0.65 ? (1 - t) / 0.35 : 1.0)).clamp(0.0, 1.0);
    final within = state._rect(state._within);
    canvas.save();
    if (within != null) {
      // cut off only the way the list scrolls: a spot as wide as its list (a row of a dialog) has the
      // sides of its ring in the list's margin
      canvas.clipRect(
        state._sideways
            ? Rect.fromLTRB(within.left, 0, within.right, size.height)
            : Rect.fromLTRB(0, within.top, size.width, within.bottom),
      );
    }
    final ring = RRect.fromRectAndRadius(where, const Radius.circular(12));
    canvas.drawRRect(ring, Paint()..color = color.withValues(alpha: 0.13 * strength));
    canvas.drawRRect(
      ring.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: strength),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Ring old) => true;
}
