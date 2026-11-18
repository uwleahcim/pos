/// The mark of food the kitchen has made that waits to be carried out (docs/kitchen-screens.md): its icon,
/// its colours and its words, the same on the floor map and over a check.
library;

import 'package:flutter/material.dart';

import 'theme.dart';

const readyIcon = Icons.ramen_dining_rounded;

/// The fill and the ink of the mark: the green of a dish the kitchen ticked, with ink that reads on it on a
/// light screen and on a dark one.
(Color, Color) readyColors(BuildContext context) {
  final colors = PosColors.of(context);
  return (colors.firedBorder, Theme.of(context).brightness == Brightness.dark ? colors.fired : Colors.white);
}

/// "1 dish ready", "3 dishes ready".
String readyInWords(int count) => '$count ${count == 1 ? 'dish' : 'dishes'} ready';
