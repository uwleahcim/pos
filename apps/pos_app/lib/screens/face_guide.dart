import 'package:flutter/material.dart';

/// The oval over a camera preview that shows where a face should be, in the colour of how things stand.
class FaceGuide extends StatelessWidget {
  const FaceGuide({super.key, required this.color, this.width = 120, this.height = 156});

  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(Radius.elliptical(width / 2, height / 2)),
          border: Border.all(color: color.withValues(alpha: 0.85), width: 2.5),
        ),
      ),
    ),
  );
}
