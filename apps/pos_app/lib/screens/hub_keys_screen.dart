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

/// Where the page says what came of adding or removing an account: under the button that adds one.
const _accountsSaid = 'online-accounts';

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

  /// Another account with GloriaFood: its name, its key and whether it is for testing, typed in one dialog.
  Future<void> _addAccount() async {
    final saved = await showDialog<HubKeys>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OnlineAccountDialog(api: widget.api, token: widget.token),
    );
    if (saved == null || !mounted) return;
    setState(() => _said.remove(_accountsSaid));
    final added = saved.added;
    _stand(
      saved,
      added == null ? _accountsSaid : OnlineAccount.slotOf(added),
      'Added. The hub asks it every minute from now on.',
    );
  }

  /// An account's name, and whether it is the one for testing.
  Future<void> _editAccount(OnlineAccount account) async {
    final saved = await showDialog<HubKeys>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OnlineAccountDialog(api: widget.api, token: widget.token, was: account),
    );
    if (saved == null || !mounted) return;
    _stand(saved, account.key.name, 'Saved. Orders that come from now on say so.');
  }

  /// A further account is taken away whole, its key with it.
  Future<void> _removeAccount(OnlineAccount account) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: Text(
          '${account.called}. The hub stops asking GloriaFood for its orders, and its key is forgotten. The orders '
          'already on the POS stay as they are. It can be added again at any time.',
        ),
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
    final name = account.key.name;
    setState(() {
      _busy = name;
      _said.remove(name);
    });
    try {
      final saved = await widget.api.removeOnlineAccount(widget.token, account.id);
      if (mounted) _stand(saved, _accountsSaid, 'Removed ${account.called}. The hub no longer asks it.');
    } on ApiException catch (err) {
      if (mounted) setState(() => _said[name] = (words: 'Not removed. ${_refusal(err)}', bad: true));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
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

  /// GloriaFood is asked for orders now, as the button "Ask now" does. Where the hub asks several accounts
  /// it asks them all, and what is said here is what [account] answered.
  Future<void> _tryOnline(String name, OnlineAccount? account) => _trying(name, () async {
    final asked = await widget.api.onlineFetch();
    final mine = account == null || !asked.asked ? null : asked.wordsFor(account.id);
    if (mine != null) return (words: mine, bad: asked.answeredFor(account!.id) == false);
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

  void _try(HubKey key, OnlineAccount? account) {
    switch (key.name) {
      case 'maps':
        _tryMaps(key.name, 'geocodio', 'Geocodio');
      case 'maps_google':
        _tryMaps(key.name, 'google', 'Google Maps');
      case 'push_apple':
        _tryApple(key.name);
      case _ when account != null || key.name == 'online':
        _tryOnline(key.name, account);
    }
  }

  /// One key's card. [account] is the account of GloriaFood's the key belongs to, on a hub that knows of
  /// accounts: its card can also be named, marked for testing and, but for the first, taken away whole.
  Widget _card(BuildContext context, HubKey key, HubKeyInfo info, {OnlineAccount? account}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final busy = _busy == key.name;
    final said = _said[key.name];
    // a further account goes with its key: there is no hub's file behind it to fall back on
    final whole = account != null && !account.isFirst;
    return Card(
      key: ValueKey('key-${key.name}'),
      margin: EdgeInsets.zero,
      child: Padding(
        // an account's card has a pencil at the end of its title, which is taller than the title: the room
        // for it comes out of the card's own edge, so the title stands where every card's does
        padding: EdgeInsets.fromLTRB(16, account != null ? 4 : 12, account != null ? 8 : 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: account != null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: account != null ? 0 : 2, right: 8),
                  child: Icon(
                    key.set ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: key.set ? scheme.primary : scheme.outline,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: account != null ? 8 : 0),
                    child: Text(info.title, style: theme.textTheme.titleMedium),
                  ),
                ),
                if (account != null && account.test)
                  Container(
                    key: ValueKey('account-${account.id}-test'),
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      'For testing',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onInverseSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                // its name and whether it is for testing: at the title it changes, and off the row of
                // buttons, which a fourth one would push onto a second line on a phone
                if (account != null)
                  IconButton(
                    key: ValueKey('account-${account.id}-edit'),
                    tooltip: 'Name, and whether it is for testing',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    iconSize: 20,
                    onPressed: _busy != null ? null : () => _editAccount(account),
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            if (account == null) const SizedBox(height: 4),
            Text(
              key.words(widget.clock()),
              key: ValueKey('key-${key.name}-state'),
              style: theme.textTheme.bodyMedium?.copyWith(color: key.unreadable ? scheme.error : null),
            ),
            const SizedBox(height: 4),
            Text(
              [
                info.about,
                if (!key.set) info.without,
                if (account != null && account.test) 'Its orders say TEST ORDER on every ticket and screen.',
              ].join(' '),
              style: quiet,
            ),
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
                    onPressed: _busy != null ? null : () => _try(key, account),
                    child: const Text('Try it'),
                  ),
                if (key.set || key.unreadable || whole)
                  TextButton(
                    key: ValueKey('key-${key.name}-remove'),
                    onPressed: _busy != null ? null : () => whole ? _removeAccount(account) : _remove(key, info),
                    child: const Text('Remove'),
                  ),
                if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (said != null) _saidLine(context, said, ValueKey('key-${key.name}-said')),
          ],
        ),
      ),
    );
  }

  /// What a try or a change came to, under the buttons it belongs to.
  Widget _saidLine(BuildContext context, _Said said, Key key) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
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
              key: key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: said.bad ? scheme.error : scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// GloriaFood's part of the page: a card for each of the restaurant's accounts there, and, on a hub that
  /// can hold several, the way to add another.
  List<Widget> _online(BuildContext context, HubKeyInfo info) {
    final theme = Theme.of(context);
    final accounts = _keys.accounts;
    final several = accounts.length > 1;
    final can = _keys.onlineAccounts != null; // a hub from before there could be several has the one key
    final said = _said[_accountsSaid];
    return [
      for (final account in accounts) ...[
        const SizedBox(height: 12),
        _card(
          context,
          account.key,
          several || account.name.isNotEmpty ? info.titled('GloriaFood · ${account.called}') : info,
          account: can ? account : null,
        ),
      ],
      if (can)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('account-add'),
                  onPressed: _busy != null ? null : _addAccount,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add another GloriaFood account'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'For a second website, or an account you only test with. Each has its own key.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              // several accounts and the first one still nameless: its orders would say no website
              if (several && accounts.first.name.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(
                    'The first account has no name yet. Tap the pencil on its card, so that its orders say which '
                    'website they came from too.',
                    key: const ValueKey('account-first-unnamed'),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              if (said != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _saidLine(context, said, const ValueKey('accounts-said')),
                ),
            ],
          ),
        ),
    ];
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
              for (final key in known)
                if (key.name == 'online')
                  ..._online(context, hubKeyInfo[key.name]!)
                else ...[
                  const SizedBox(height: 12),
                  _card(context, key, hubKeyInfo[key.name]!),
                ],
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

/// One of the restaurant's accounts with GloriaFood, typed by a manager: a new one ([was] is null) with its
/// name, its key and whether it is for testing, or the name and the testing of one that is there. The
/// dialog sends it to the hub itself, so what the hub says of it shows here with everything still in the
/// boxes. Pops with how the keys stand once the hub took it.
class OnlineAccountDialog extends StatefulWidget {
  const OnlineAccountDialog({super.key, required this.api, required this.token, this.was});

  final PosApi api;
  final String token;

  /// The account that is changed; null to add one.
  final OnlineAccount? was;

  @override
  State<OnlineAccountDialog> createState() => _OnlineAccountDialogState();
}

class _OnlineAccountDialogState extends State<OnlineAccountDialog> {
  late final _name = TextEditingController(text: widget.was?.name ?? '');
  final _key = TextEditingController();
  late bool _test = widget.was?.test ?? false;
  bool _hidden = true;
  bool _busy = false;
  String? _message;

  bool get _adding => widget.was == null;

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final key = _key.text.trim();
    final was = widget.was;
    // the first account may go without a name: with one account nothing needs telling apart
    if (name.isEmpty && !(was?.isFirst ?? false)) {
      setState(() => _message = 'Give the account a name: it is how its orders are told from the others\'.');
      return;
    }
    if (_adding && key.isEmpty) {
      setState(() => _message = 'Type or paste the key first.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = was == null
          ? await widget.api.addOnlineAccount(widget.token, name: name, key: key, test: _test)
          : await widget.api.changeOnlineAccount(widget.token, was.id, name: name, test: _test);
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
    return AlertDialog(
      title: Text(_adding ? 'Add a GloriaFood account' : 'GloriaFood account'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('account-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                onSubmitted: (_) => _busy || _adding ? null : _save(),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Name',
                  hintText: 'Sushi site',
                  helperText: 'Yours to choose. It is said on the account\'s orders and their tickets',
                  helperMaxLines: 2,
                ),
              ),
              if (_adding) ...[
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('key-field'),
                  controller: _key,
                  obscureText: _hidden,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _busy ? null : _save(),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'The key',
                    helperText:
                        'In that account\'s GloriaFood admin: Others, Third party integrations, the key of the '
                        'integration Poll Accepted Order v2',
                    helperMaxLines: 3,
                    suffixIcon: IconButton(
                      key: const ValueKey('key-show'),
                      tooltip: _hidden ? 'Show what is typed' : 'Hide what is typed',
                      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey('account-test'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _test,
                onChanged: _busy ? null : (value) => setState(() => _test = value),
                title: const Text('For testing'),
                subtitle: const Text(
                  'Its orders go on the POS and print, with TEST ORDER, DO NOT MAKE on every ticket and screen. '
                  'Void them when you are done.',
                ),
              ),
              if (_adding) Text('The hub asks it at once, and every minute. The hub is not restarted.', style: quiet),
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
        FilledButton(
          key: const ValueKey('key-save'),
          onPressed: _busy ? null : _save,
          child: Text(_adding ? 'Add' : 'Save'),
        ),
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
