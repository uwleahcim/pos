import 'package:flutter/widgets.dart';

/// Which name of a dish the screens put first (docs/dish-names.md). The menu holds a dish and a category in
/// English and, for most of the kitchen's dishes, in Chinese. Each person says which they read; it is one
/// of their own settings, kept by the hub like their text size, so it follows them to every screen.
///
/// Stands over every screen and dialog (`main.dart`). A tile or a line of the check that asks
/// [chineseOf] is drawn again by itself when the person at the screen changes, also where its widget is
/// kept from frame to frame (the menu's tiles).
class DishLanguage extends InheritedWidget {
  const DishLanguage({super.key, required this.chinese, required super.child});

  /// The person at the screen reads dish names in Chinese.
  final bool chinese;

  /// Whether to put the Chinese name first here; English where nothing says (a screen shown on its own).
  static bool chineseOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DishLanguage>()?.chinese ?? false;

  @override
  bool updateShouldNotify(DishLanguage oldWidget) => oldWidget.chinese != chinese;
}

/// The setting a person stores for Chinese dish names, and for English.
const chineseNames = 'zh';
const englishNames = 'en';

/// Whether a stored language (`en`, `zh`, `zh-Hans`) means the Chinese names come first.
bool readsChinese(String locale) => locale.toLowerCase().startsWith('zh');

/// A name and its other one, the way round the person reads them: the first is the big one, the second
/// goes small under it. A dish the menu names in one language only has that name and nothing under it,
/// whoever reads it.
(String, String?) namesShown(String english, String? chinese, {required bool chineseFirst}) {
  final zh = chinese == null || chinese.trim().isEmpty || chinese == english ? null : chinese;
  if (zh == null) return (english, null);
  return chineseFirst ? (zh, english) : (english, zh);
}

/// What a line of the check is called in Chinese, from what the hub keeps with it (`priced`): the dish's
/// Chinese name, with its size after it as the English name has ("左宗棠鸡 (Quart)"). Null for a dish the
/// menu names in English only, a dish whose name was typed, and a line the hub has not priced.
String? chineseLineName(Object? priced) {
  if (priced is! Map) return null;
  final names = priced['names'];
  if (names is! Map) return null;
  final zh = names['zh'];
  if (zh is! String || zh.trim().isEmpty) return null;
  final en = names['en'], name = priced['name'];
  if (name is String && en is String && name.length > en.length + 3 && name.startsWith('$en (') && name.endsWith(')')) {
    final sizes = priced['variant_names'];
    final size = sizes is Map && sizes['zh'] is String && (sizes['zh'] as String).trim().isNotEmpty
        ? sizes['zh'] as String
        : name.substring(en.length + 2, name.length - 1);
    return '$zh ($size)';
  }
  return zh;
}
