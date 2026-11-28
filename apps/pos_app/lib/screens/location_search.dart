import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../setting_search.dart';

/// The search box of Location settings, in the place of the screen's title: what is typed lists the
/// settings it finds under it, as it is typed. Enter goes to the first one found; Escape closes the search.
class SettingSearchBox extends StatelessWidget {
  const SettingSearchBox({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: SizedBox(
        height: 40,
        child: TextField(
          key: const ValueKey('location-search-box'),
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          autocorrect: false,
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted(),
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            hintText: hint,
            hintMaxLines: 1,
          ),
        ),
      ),
    );
  }
}

/// A row of Location settings as the screen has it at this moment: its icon, and whether a tap on it opens
/// a page or a dialog (it has what it needs from the hub) or it is set where it stands.
typedef RowSeen = ({IconData? icon, bool opens});

/// What the search of Location settings found, best first: each setting by its name with the part that
/// was typed in bold, and under it what it is for, or the row it is in. A tap goes to it.
class SettingResults extends StatelessWidget {
  const SettingResults({super.key, required this.typed, required this.found, required this.rows, required this.onPick});

  /// What was typed.
  final String typed;

  final List<SettingEntry> found;

  /// The rows the screen shows now, by their key.
  final Map<String, RowSeen> rows;

  final ValueChanged<SettingEntry> onPick;

  /// The key of a result's row, for the tests.
  static String idOf(SettingEntry entry) =>
      entry.spot == null ? entry.row : '${entry.row}/${entry.spot!.key ?? entry.spot!.words}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (found.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 36, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'Nothing here is called "${typed.trim()}"',
                key: const ValueKey('location-search-none'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Try another word for it, or a shorter one: "printer", "tax", "PIN".',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('location-search-results'),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (index, entry) in found.indexed) ...[
                if (index > 0) const Divider(height: 1),
                _result(context, entry),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _result(BuildContext context, SettingEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // what is inside a row, or under one, has that row's icon and says where it is
    final holder = entry.isRow ? null : locationRows[entry.under ?? entry.row];
    final own = rows[entry.row];
    final seen = entry.spot == null && own != null ? own : rows[holder?.row ?? entry.row];
    final String says;
    if (entry.spot != null && holder != null) {
      says = 'In ${holder.title}';
    } else if (entry.about.isNotEmpty) {
      says = entry.about;
    } else if (holder != null) {
      says = 'Under ${holder.title}';
    } else {
      says = '';
    }
    return ListTile(
      key: ValueKey('found:${idOf(entry)}'),
      leading: Icon(own?.icon ?? seen?.icon ?? Icons.tune, color: scheme.onSurfaceVariant),
      title: Text.rich(_marked(entry.title, theme.textTheme.bodyLarge), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: says.isEmpty ? null : Text(says, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: (seen?.opens ?? false) ? const Icon(Icons.chevron_right) : null,
      onTap: () => onPick(entry),
    );
  }

  /// [title] with the parts that were typed in bold.
  TextSpan _marked(String title, TextStyle? style) {
    final bold = style?.copyWith(fontWeight: FontWeight.w800);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in foundIn(typed, title)) {
      if (start > at) spans.add(TextSpan(text: title.substring(at, start)));
      spans.add(TextSpan(text: title.substring(start, end), style: bold));
      at = end;
    }
    if (at < title.length) spans.add(TextSpan(text: title.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}
