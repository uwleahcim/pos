import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../hub_keys.dart';

/// What a try or a change of one key came to, for the line under its buttons.
typedef _Said = ({String words, bool bad});

/// [words] as a sentence: the hub's own words for a refusal start small and end without a stop.
String _sentence(String words) {
  final clean = words.trim();
  if (clean.isEmpty) return clean;
  final stopped = clean.endsWith('.') || clean.endsWith('?') || clean.endsWith('!');
  return '${clean[0].toUpperCase()}${clean.substring(1)}${stopped ? '' : '.'}';
}

/// What the hub's refusal of a change means, in words for whoever typed.
String _refusal(ApiException err) => switch (err.status) {
  401 => 'The PIN has run out. Go back and open Location again.',
  403 => 'Only a manager or an owner changes the hub\'s keys.',
  404 || 405 => 'This hub is older than keys typed in the app. Update it first.',
  null => 'The hub did not answer. Look whether it changed before trying again.',
  _ => _sentence(err.detail?['message'] as String? ?? err.message),
};

/// Keys and connections (docs/hub-keys.md): the hub's keys for the services outside the restaurant, each
/// with how it stands, and for a manager the buttons to type one, replace it, try it and remove it. What
/// used to be typed in the hub's terminal. The hub keeps a typed key sealed and uses it at once; this page
/// never has a key to show, only its last characters.
class HubKeysScreen extends StatefulWidget {
  const HubKeysScreen({
    super.key,
    required this.api,
    required this.token,
    required this.keys,
    this.onChanged,
    this.clock = DateTime.now,
  });

  final PosApi api;
  final String token;

  /// The keys as the hub has them.
  final HubKeys keys;

  /// Told how the keys stand after each change, for the row that opened this page.
  final ValueChanged<HubKeys>? onChanged;
  final DateTime Function() clock;

  @override
  State<HubKeysScreen> createState() => _HubKeysScreenState();
}

class _HubKeysScreenState extends State<HubKeysScreen> {
  late HubKeys _keys = widget.keys;
  String? _busy; // the key being tried or removed
  final _said = <String, _Said>{};

  void _stand(HubKeys keys, String name, String words) {
    setState(() {
      _keys = keys;
      _said[name] = (words: words, bad: false);
    });
    widget.onChanged?.call(keys);
  }

  Future<void> _type(HubKey key, HubKeyInfo info) async {
    final saved = await showDialog<HubKeys>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HubKeyDialog(api: widget.api, token: widget.token, was: key, info: info),
    );
    if (saved == null || !mounted) return;
    _stand(saved, key.name, 'Saved. The hub uses it from now on.');
  }

  Future<void> _remove(HubKey key, HubKeyInfo info) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this key?'),
        content: Text('${info.title}. ${info.removing} It can be typed again at any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          FilledButton(
            key: const ValueKey('key-remove-sure'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = key.name;
      _said.remove(key.name);
    });
    try {
      final saved = await widget.api.removeHubKey(widget.token, key.name);
      if (mounted) _stand(saved, key.name, 'Removed. The hub no longer uses it.');
    } on ApiException catch (err) {
      if (mounted) setState(() => _said[key.name] = (words: 'Not removed. ${_refusal(err)}', bad: true));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Runs one try of [name] and puts what it came to under the key's buttons.
  Future<void> _trying(String name, Future<_Said> Function() ask) async {
    setState(() {
      _busy = name;
      _said.remove(name);
    });
    _Said said;
    try {
      said = await ask();
    } on ApiException catch (err) {
      said = (
        words: err.status == null
            ? 'The hub did not answer.'
            : _sentence(err.detail?['message'] as String? ?? err.message),
        bad: true,
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = null;
      _said[name] = said;
    });
  }

  /// A map service is tried with an address: how far it is from the restaurant.
  Future<void> _tryMaps(String name, String via, String service) async {
    final address = await showDialog<String>(context: context, builder: (_) => const _AddressDialog());
    if (address == null || !mounted) return;
    await _trying(name, () async {
      try {
        final measured = await widget.api.tryMaps(address, via);
        return (words: '$service answered: ${measured.words} from the restaurant. The key works.', bad: false);
      } on ApiException catch (err) {
        final words = switch (err.detail?['reason']) {
          'refused' => '$service refused the key. Check it where it came from, and type it again.',
          'not_found' => '$service answered, so the key works, but it did not find that address.',
          'unreachable' => '$service is not answering. The hub may have no way out to the internet right now.',
          'limit' => '$service has been asked as often as it may be today, so it was not asked.',
          _ => null,
        };
        if (words == null) rethrow;
        return (words: words, bad: err.detail?['reason'] != 'not_found');
      }
    });
  }

  /// GloriaFood is asked for orders now, as the button "Ask now" does.
  Future<void> _tryOnline(String name) => _trying(name, () async {
    final asked = await widget.api.onlineFetch();
    final works = asked.asked && asked.answered ? ' The key works.' : '';
    return (words: '${asked.words}$works', bad: asked.bad || (!asked.asked && !asked.soon));
  });

  /// A notification to one iPhone or iPad that registered with the hub.
  Future<void> _tryApple(String name) async {
    final List<String> devices;
    try {
      final status = await widget.api.pushStatus();
      devices = {
        for (final row in status['list'] as List? ?? const [])
          if (row is Map && row['kind'] == 'alert' && row['device'] is String) row['device'] as String,
      }.toList()..sort();
    } on ApiException {
      if (mounted) setState(() => _said[name] = (words: 'The hub did not answer.', bad: true));
      return;
    }
    if (!mounted) return;
    if (devices.isEmpty) {
      setState(
        () => _said[name] = (
          words:
              'No iPhone or iPad has registered with this hub yet. Open the app on one, signed with push '
              'on, and try again.',
          bad: false,
        ),
      );
      return;
    }
    final device = devices.length == 1
        ? devices.single
        : await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Which screen gets the test?'),
              children: [
                for (final device in devices)
                  SimpleDialogOption(
                    key: ValueKey('key-try-device-$device'),
                    onPressed: () => Navigator.of(context).pop(device),
                    child: Text(device),
                  ),
              ],
            ),
          );
    if (device == null || !mounted) return;
    await _trying(name, () async {
      final answer = await widget.api.testPush(device);
      final sent = (answer['sent'] as num?)?.toInt() ?? 0;
      if (sent > 0) return (words: 'Apple took a notification for $device. It should show there now.', bad: false);
      final results = answer['results'] as List? ?? const [];
      final reason = results.isNotEmpty && results.first is Map ? '${(results.first as Map)['reason'] ?? ''}' : '';
      return (
        words: reason.isEmpty
            ? 'Nothing went out to $device.'
            : 'Apple did not take the notification for $device: $reason.',
        bad: true,
      );
    });
  }

  void _try(HubKey key) {
    switch (key.name) {
      case 'maps':
        _tryMaps(key.name, 'geocodio', 'Geocodio');
      case 'maps_google':
        _tryMaps(key.name, 'google', 'Google Maps');
      case 'online':
        _tryOnline(key.name);
      case 'push_apple':
        _tryApple(key.name);
    }
  }

  Widget _card(BuildContext context, HubKey key, HubKeyInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final busy = _busy == key.name;
    final said = _said[key.name];
    return Card(
      key: ValueKey('key-${key.name}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 8),
                  child: Icon(
                    key.set ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: key.set ? scheme.primary : scheme.outline,
                  ),
                ),
                Expanded(child: Text(info.title, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              key.words(widget.clock()),
              key: ValueKey('key-${key.name}-state'),
              style: theme.textTheme.bodyMedium?.copyWith(color: key.unreadable ? scheme.error : null),
            ),
            const SizedBox(height: 4),
            Text(key.set ? info.about : '${info.about} ${info.without}', style: quiet),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonal(
                  key: ValueKey('key-${key.name}-type'),
                  onPressed: _busy != null ? null : () => _type(key, info),
                  child: Text(key.set ? 'Replace' : 'Type the key'),
                ),
                if (key.set)
                  OutlinedButton(
                    key: ValueKey('key-${key.name}-try'),
                    onPressed: _busy != null ? null : () => _try(key),
                    child: const Text('Try it'),
                  ),
                if (key.set || key.unreadable)
                  TextButton(
                    key: ValueKey('key-${key.name}-remove'),
                    onPressed: _busy != null ? null : () => _remove(key, info),
                    child: const Text('Remove'),
                  ),
                if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (said != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1, right: 6),
                      child: Icon(
                        said.bad ? Icons.error_outline : Icons.check,
                        size: 16,
                        color: said.bad ? scheme.error : scheme.onSurface,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        said.words,
                        key: ValueKey('key-${key.name}-said'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: said.bad ? scheme.error : scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final known = [for (final name in hubKeyInfo.keys) ?_keys.named(name)];
    return Scaffold(
      appBar: AppBar(title: const Text('Keys and connections')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              Text(
                'The hub\'s keys for the services outside the restaurant. A key typed here is sealed on the '
                'hub and used at once. It is never shown again: only its last characters, to tell one key '
                'from another.',
                key: const ValueKey('keys-intro'),
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (!_keys.kept)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'This hub has nowhere to keep a typed key: one typed now lasts until the hub restarts. '
                    'Update the hub (sudo hubctl update) and type it then.',
                    key: const ValueKey('keys-not-kept'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
              if (known.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_keys.summary, key: const ValueKey('keys-none')),
                ),
              for (final key in known) ...[const SizedBox(height: 12), _card(context, key, hubKeyInfo[key.name]!)],
            ],
          ),
        ),
      ),
    );
  }
}

/// A manager types one key. The dialog sends it to the hub itself, so that what the hub says about it (not
/// a key, a wrong id) shows here with everything typed still in the boxes. Pops with how the keys stand
/// once the hub took it.
class HubKeyDialog extends StatefulWidget {
  const HubKeyDialog({super.key, required this.api, required this.token, required this.was, required this.info});

  final PosApi api;
  final String token;

  /// The key as it stands: Apple's ids start from the ones in force.
  final HubKey was;
  final HubKeyInfo info;

  @override
  State<HubKeyDialog> createState() => _HubKeyDialogState();
}

class _HubKeyDialogState extends State<HubKeyDialog> {
  final _key = TextEditingController();
  late final _keyId = TextEditingController(text: widget.was.shown['key_id'] ?? '');
  late final _teamId = TextEditingController(text: widget.was.shown['team_id'] ?? '');
  late final _bundleId = TextEditingController(text: widget.was.shown['bundle_id'] ?? '');
  bool _hidden = true;
  bool _busy = false;
  String? _message;

  bool get _apple => widget.was.name == 'push_apple';

  @override
  void dispose() {
    _key.dispose();
    _keyId.dispose();
    _teamId.dispose();
    _bundleId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _message = _apple ? 'Paste the text of the .p8 file first.' : 'Type or paste the key first.');
      return;
    }
    if (_apple && (_keyId.text.trim().isEmpty || _teamId.text.trim().isEmpty)) {
      setState(() => _message = 'Apple\'s key needs its Key ID and the Team ID.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.api.saveHubKey(widget.token, widget.was.name, {
        'key': key,
        if (_apple) ...{
          'key_id': _keyId.text.trim().toUpperCase(),
          'team_id': _teamId.text.trim().toUpperCase(),
          'bundle_id': _bundleId.text.trim(),
        },
      });
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _refusal(err);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final ids = [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), LengthLimitingTextInputFormatter(10)];
    return AlertDialog(
      title: Text(widget.info.title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.info.where, key: const ValueKey('key-where'), style: quiet),
              const SizedBox(height: 10),
              if (_apple)
                TextField(
                  key: const ValueKey('key-field'),
                  controller: _key,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 3,
                  maxLines: 5,
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'The text of the .p8 file',
                    alignLabelWithHint: true,
                    helperText: 'Open the file in a text editor, copy all of it, and paste it here',
                    helperMaxLines: 3,
                  ),
                )
              else
                TextField(
                  key: const ValueKey('key-field'),
                  controller: _key,
                  autofocus: true,
                  obscureText: _hidden,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _busy ? null : _save(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'The key',
                    suffixIcon: IconButton(
                      key: const ValueKey('key-show'),
                      tooltip: _hidden ? 'Show what is typed' : 'Hide what is typed',
                      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  ),
                ),
              if (_apple) ...[
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('key-id'),
                  controller: _keyId,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: ids,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Key ID',
                    helperText: 'The ten letters and digits in the file\'s name',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('key-team'),
                  controller: _teamId,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: ids,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Team ID',
                    helperText: 'In the Apple developer account, under Membership details',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('key-bundle'),
                  controller: _bundleId,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Bundle ID',
                    helperText: 'Leave it empty unless the app was renamed at Apple',
                    helperMaxLines: 2,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                widget.was.set
                    ? 'It takes the place of the key in use now, at once. The hub is not restarted.'
                    : 'The hub uses it at once. The hub is not restarted.',
                style: quiet,
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _message!,
                    key: const ValueKey('key-problem'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('key-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

/// An address to try a map service with.
class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _address = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _ask() {
    final address = _address.text.trim();
    if (address.isNotEmpty) Navigator.of(context).pop(address);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Try it with an address'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('key-try-address'),
              controller: _address,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _ask(),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'An address nearby',
                hintText: 'Number, street and town',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'The hub asks this one service how far it is from the restaurant. It counts as one question of '
              'the day, and nothing is kept.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('key-try-ask'), onPressed: _ask, child: const Text('Ask')),
      ],
    );
  }
}
