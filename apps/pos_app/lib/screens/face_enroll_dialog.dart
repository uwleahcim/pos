import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../camera.dart';
import '../face_signin.dart';
import '../faces.dart';
import 'face_guide.dart';

/// A manager enrolls one staff member's face: the person looks at this screen's camera and turns their head
/// a little while frames go to the hub, which keeps each view that is good and new until it has enough. The
/// hub refuses a view that already matches someone else, so the manager's own face cannot slip in.
class FaceEnrollDialog extends StatefulWidget {
  const FaceEnrollDialog({
    super.key,
    required this.api,
    required this.token,
    required this.staff,
    required this.camera,
    required this.device,
    this.interval = const Duration(milliseconds: 600),
  });

  final PosApi api;
  final String token;
  final StaffEntry staff;
  final EventCamera camera;
  final String device;
  final Duration interval;

  @override
  State<FaceEnrollDialog> createState() => _FaceEnrollDialogState();
}

class _FaceEnrollDialogState extends State<FaceEnrollDialog> {
  EnrollStep? _last;
  String? _hint;
  String? _error;
  bool _first = true; // the first view of a fresh enrollment drops the views kept before
  bool _done = false;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(widget.camera.watch()); // frames at hand while the dialog is up
    FaceSignIn.hold(); // the face in front of the camera is being enrolled, not signed in
    _schedule(Duration.zero);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.camera.unwatch();
    FaceSignIn.release();
    super.dispose();
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_step()));
  }

  Future<void> _step() async {
    if (_done || _busy || !mounted) return;
    _busy = true;
    try {
      final jpeg = await widget.camera.frame();
      if (!mounted) return;
      if (jpeg == null) {
        _schedule(const Duration(seconds: 1));
        return;
      }
      final step = await widget.api.enrollFace(
        widget.token,
        widget.staff.staffId,
        device: widget.device,
        jpeg: jpeg,
        replace: _first,
      );
      _first = false;
      if (!mounted) return;
      setState(() {
        _last = step;
        _error = null;
        _hint = _hintFor(step);
        _done = step.done || step.reason == 'full';
      });
      if (!_done) _schedule(widget.interval);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() => _error = err.detail?['message'] as String? ?? err.message);
      _schedule(const Duration(seconds: 3));
    } finally {
      _busy = false;
    }
  }

  String _hintFor(EnrollStep step) {
    final name = widget.staff.name;
    if (step.done) return 'Enrolled: $name can sign in by face now';
    return switch (step.reason) {
      null => 'Good. Now turn the head a little',
      'no_face' => 'Ask $name to look at the camera',
      'several_faces' => 'Only $name in the picture, please',
      'too_small' => 'Closer to the camera',
      'blurry' => 'Hold still',
      'same_view' => 'Turn the head a little: to a side, up, down',
      'looks_like' => 'This looks like ${step.looksLike}. Is $name the one at the camera?',
      'full' => 'That is plenty',
      'not_ready' => 'The hub has no face models yet',
      _ => step.reason!,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = _last;
    final wanted = last?.wanted ?? 5;
    final samples = last?.samples ?? 0;
    return AlertDialog(
      title: Text(_done ? '${widget.staff.name} enrolled' : 'Enroll ${widget.staff.name}'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 280,
              height: 210,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.camera.preview(),
                    FaceGuide(
                      color: _done
                          ? scheme.tertiary
                          : last == null || last.accepted
                          ? scheme.primary
                          : scheme.outline,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              key: const ValueKey('enroll-progress'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < wanted; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < samples ? scheme.primary : scheme.surfaceContainerHighest,
                      border: Border.all(color: i < samples ? scheme.primary : scheme.outlineVariant, width: 1.5),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _error ?? _hint ?? 'Ask ${widget.staff.name} to look at the camera',
              key: const ValueKey('enroll-hint'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: _error != null ? scheme.error : scheme.onSurface),
            ),
            const SizedBox(height: 4),
            Text(
              '$samples of $wanted views',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        if (!_done)
          TextButton(
            key: const ValueKey('enroll-cancel'),
            onPressed: () => Navigator.of(context).pop(samples),
            child: Text(samples > 0 ? 'Stop here' : 'Cancel'),
          ),
        if (_done)
          FilledButton(
            key: const ValueKey('enroll-done'),
            onPressed: () => Navigator.of(context).pop(samples),
            child: const Text('Done'),
          ),
      ],
    );
  }
}
