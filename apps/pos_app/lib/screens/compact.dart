import 'package:flutter/widgets.dart';

/// A phone-sized screen, where every line of it counts: app bars keep only icons, and rows that stack on a
/// tablet share one line.
bool compact(BuildContext context) => MediaQuery.sizeOf(context).width < 600;
