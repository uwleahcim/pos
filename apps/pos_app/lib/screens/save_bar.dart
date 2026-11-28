import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Why a Save did not go through: what the hub or the page said, and on a page with several subjects the
/// one it is about ("Courses").
typedef SaveProblem = ({String? about, String text});

/// "Courses", "Courses and desk phones", "Courses, desk phones and the time clock": names in a sentence,
/// the first as it is written and the rest as they come.
String inSentence(List<String> names) {
  if (names.length < 2) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Asks before a page with changes that are not saved is left: true to leave and lose them. [unsaved] says
/// what is not saved, as a sentence.
Future<bool> confirmLeave(BuildContext context, String unsaved) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Leave without saving?'),
      content: Text(unsaved),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep editing')),
        FilledButton(
          key: const ValueKey('leave-discard'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Discard changes'),
        ),
      ],
    ),
  );
  return leave ?? false;
}

/// A settings page, and the one way its settings are saved: nothing on the page takes effect as it is
/// changed. Once something is [changed] a bar with Save comes up at the bottom of the screen and stays
/// there however the page is scrolled, above the keyboard too; scrolled all the way down it rests at the
/// end of the page (its line goes), and it follows again as the page is scrolled back up. Once saved, or
/// once everything is put back as it was, the bar goes. Leaving the page with changes waiting asks first.
///
/// [child] is the page's list. A page built this way has no Save button of its own. The bar is the
/// scaffold's own bottom bar, so what the page says in passing ("Printers saved") comes up above it and
/// never over Save.
class SaveBarScaffold extends StatefulWidget {
  const SaveBarScaffold({
    super.key,
    required this.changed,
    required this.onSave,
    required this.child,
    this.appBar,
    this.always = false,
    this.onBack,
    this.saveKey,
    this.label = 'Save',
    this.waiting = 'Changes not saved',
    this.problems = const [],
    this.unsaved = 'Your changes are not saved.',
    this.maxWidth = 640,
  });

  /// Something on the page differs from what is saved.
  final bool changed;

  /// Saves what is waiting; null while a save is on its way, which greys the button.
  final VoidCallback? onSave;

  /// The page's list.
  final Widget child;

  /// The page's bar at the top.
  final PreferredSizeWidget? appBar;

  /// The bar stays up with nothing changed here: for a page that has something to save all the same (a
  /// terminal's first set-up, printers the hub was handed some other way). Leaving asks only for a change.
  final bool always;

  /// What Back does before the page is left, when the page has something of its own open that Back
  /// closes first (its search): Back calls this and the page stays. Null for a page that Back leaves.
  final VoidCallback? onBack;

  /// The key of the Save button.
  final Key? saveKey;

  /// The Save button's words.
  final String label;

  /// What is waiting, beside the button: "Changes not saved", or the parts of the page by name.
  final String waiting;

  /// Why the last save did not go through, above the button; empty when it did or none was tried.
  final List<SaveProblem> problems;

  /// What the question before leaving says is not saved, as a sentence.
  final String unsaved;

  /// The width of the page's column, which the bar's words and button keep to.
  final double maxWidth;

  @override
  State<SaveBarScaffold> createState() => _SaveBarScaffoldState();
}

class _SaveBarScaffoldState extends State<SaveBarScaffold> with SingleTickerProviderStateMixin {
  late final AnimationController _up = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: _wanted ? 1 : 0,
  );
  late final CurvedAnimation _rise = CurvedAnimation(parent: _up, curve: Curves.easeOutCubic);

  /// The list is scrolled all the way down (or has nothing to scroll): the bar rests at the page's end.
  final ValueNotifier<bool> _atEnd = ValueNotifier(true);
  ScrollPosition? _position;

  /// The list was at its end when the bar came up: it is kept there while the bar takes its room.
  bool _keepEnd = false;

  /// What the bar said while it was wanted: it goes down saying that, not "0 changes".
  late String _waiting = widget.waiting;
  late String _label = widget.label;
  late List<SaveProblem> _problems = widget.problems;

  bool get _wanted => widget.changed || widget.always;

  @override
  void initState() {
    super.initState();
    _up.addStatusListener(_statusChanged);
  }

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && _keepEnd) {
      // the bar has all its room once this frame is laid out: the list is put at its end one last time
      SchedulerBinding.instance.addPostFrameCallback((_) {
        final position = _position;
        if (mounted && _keepEnd && position != null && position.hasContentDimensions) {
          position.jumpTo(position.maxScrollExtent);
        }
        _keepEnd = false;
      });
    }
    // the bar leaves the tree once it is down, and comes back as it starts up
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(SaveBarScaffold old) {
    super.didUpdateWidget(old);
    final was = old.changed || old.always;
    if (_wanted == was) return;
    if (_wanted) {
      final position = _position;
      _keepEnd = position != null && position.pixels > 0 && position.extentAfter < 1;
      _up.forward();
    } else {
      _keepEnd = false;
      _up.reverse();
    }
  }

  @override
  void dispose() {
    _up.removeStatusListener(_statusChanged);
    _rise.dispose();
    _up.dispose();
    _atEnd.dispose();
    super.dispose();
  }

  /// The page's own list moved or changed its length (not a field or a list inside it).
  void _listMoved(ScrollMetrics metrics, BuildContext? from, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    if (from != null) _position = Scrollable.maybeOf(from)?.position ?? _position;
    // a list can say it stopped in the middle of a layout, when nothing may be moved or rebuilt
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _follow());
    } else {
      _follow();
    }
  }

  /// Takes the list as it stands now: kept at its end while the bar comes up over it, and the bar at rest
  /// or not.
  void _follow() {
    final position = _position;
    if (!mounted || position == null || !position.hasContentDimensions) return;
    if (_keepEnd && position.extentAfter > 0) {
      position.jumpTo(position.maxScrollExtent);
      return;
    }
    _atEnd.value = position.extentAfter < 1;
  }

  @override
  Widget build(BuildContext context) {
    if (_wanted) {
      _waiting = widget.waiting;
      _label = widget.label;
      _problems = widget.problems;
    }
    return PopScope(
      canPop: !widget.changed && widget.onBack == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (widget.onBack case final back?) return back();
        final navigator = Navigator.of(context);
        if (await confirmLeave(context, widget.unsaved)) navigator.pop();
      },
      child: Scaffold(
        appBar: widget.appBar,
        body: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) {
            _listMoved(n.metrics, n.context, n.depth);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              _listMoved(n.metrics, n.context, n.depth);
              return false;
            },
            child: widget.child,
          ),
        ),
        // the scaffold's bottom bar stays at the bottom of the screen, under a keyboard: this one is
        // lifted to stand on it
        bottomNavigationBar: _wanted || !_up.isDismissed
            ? Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                child: SizeTransition(sizeFactor: _rise, alignment: Alignment.topCenter, child: _bar(context)),
              )
            : null,
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: _atEnd,
      builder: (context, atEnd, bar) => AnimatedContainer(
        key: const ValueKey('save-bar'),
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: scheme.surface,
          // the line says there is more of the page under the bar; at the page's end there is none
          border: Border(top: BorderSide(color: atEnd ? scheme.surface : scheme.outlineVariant)),
        ),
        child: bar,
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final problem in _problems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (problem.about != null)
                              TextSpan(
                                text: '${problem.about}: ',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            TextSpan(text: problem.text),
                          ],
                        ),
                        key: const ValueKey('save-problem'),
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _waiting,
                          key: const ValueKey('save-waiting'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(key: widget.saveKey, onPressed: _wanted ? widget.onSave : null, child: Text(_label)),
                    ],
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
