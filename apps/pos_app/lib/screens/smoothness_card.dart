import 'package:flutter/material.dart';

import '../frames.dart';

/// Settings › Smoothness: how many frames this device drew late since the app started, and the latest of
/// them with where their time went ([FrameWatch]). The way to see what a tablet or a phone struggles with:
/// start over, do what feels slow, come back here.
class SmoothnessCard extends StatelessWidget {
  const SmoothnessCard({super.key, required this.frames});

  final FrameWatch frames;

  static String _count(int n) {
    final digits = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(DateTime at, {bool seconds = false}) =>
      '${_two(at.hour)}:${_two(at.minute)}${seconds ? ':${_two(at.second)}' : ''}';

  String _summary() {
    final since = _clock(frames.since);
    if (frames.frames == 0) return 'No frames counted since $since';
    final drawn = '${_count(frames.frames)} ${frames.frames == 1 ? 'frame' : 'frames'} since $since';
    if (frames.late == 0) return '$drawn, none late. The slowest took ${millis(frames.worst)}.';
    final share = (frames.frames / frames.late).round();
    return '$drawn, ${_count(frames.late)} late${share > 1 ? ' (1 in ${_count(share)})' : ''}. '
        'The slowest took ${millis(frames.worst)}.';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: frames,
    builder: (context, _) {
      final theme = Theme.of(context);
      final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
      return Card(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: const Text('Smoothness'),
                subtitle: Text(_summary(), key: const ValueKey('smoothness-line')),
                trailing: TextButton(
                  key: const ValueKey('smoothness-reset'),
                  onPressed: frames.reset,
                  child: const Text('Start over'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'At 60 frames a second a frame has ${millis(FrameWatch.budget)}. One that takes longer is late, '
                      'and the screen stutters. To see what is slow on this device: Start over, do it, and look here.',
                      style: small,
                    ),
                    for (final frame in frames.latest)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${_clock(frame.at, seconds: true)}  '
                          '${millis(frame.build)} building the screen, ${millis(frame.paint)} painting it',
                          key: ValueKey('late-frame:${frames.latest.indexOf(frame)}'),
                          style: small?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
