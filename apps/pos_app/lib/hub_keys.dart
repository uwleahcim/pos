/// The hub's keys for the services outside the restaurant (docs/hub-keys.md): the map services a
/// delivery's distance is asked of, GloriaFood for the website's orders, and Apple for waking a locked
/// iPhone. A manager types them under Location, Keys and connections; the hub keeps them sealed and uses
/// them at once. What the hub tells a screen about a key (`GET /hub/keys`) is never the key: whether one is
/// in force, where it came from, its last characters, and who typed it and when.
///
/// GloriaFood's key comes in several: a restaurant with more than one website there, or an account it only
/// tests with, has a key for each ([OnlineAccount]; docs/online-orders.md, "Several accounts").
///
/// Two of the keys are for GloriaFood's own pushes (docs/online-orders.md, "Push"): the key a push must
/// carry, and the token of the Cloudflare Tunnel that brings pushes in. The hub says how that way in stands
/// ([WayIn]) and can try it ([WayTried]).
library;

import 'takeout.dart' show clockTime;

/// One key as the hub describes it.
class HubKey {
  const HubKey({
    required this.name,
    this.set = false,
    this.source,
    this.ending = '',
    this.shown = const {},
    this.by = '',
    this.atMs,
    this.removed = false,
    this.unreadable = false,
  });

  factory HubKey.fromJson(Map<String, dynamic> json) => HubKey(
    name: json['name'] as String? ?? '',
    set: json['set'] == true,
    source: json['source'] as String?,
    ending: json['ending'] as String? ?? '',
    shown: {
      for (final entry in (json['shown'] as Map? ?? const {}).entries)
        if (entry.value is String) entry.key as String: entry.value as String,
    },
    by: json['by'] as String? ?? '',
    atMs: (json['at_ms'] as num?)?.toInt(),
    removed: json['removed'] == true,
    unreadable: json['unreadable'] == true,
  );

  /// `maps`, `maps_google`, `online`, `online_push`, `online_tunnel` or `push_apple`; `online:<id>` for a
  /// further account of GloriaFood's.
  final String name;

  /// A key is in force on the hub.
  final bool set;

  /// Where the one in force comes from: `app` (typed here), `hub` (put on the hub in its terminal, with
  /// hubctl), or null when there is none.
  final String? source;

  /// The key's last characters, to tell one key from another; empty for a short key and for Apple's.
  final String ending;

  /// What belongs to a key and is no secret: Apple's `key_id`, `team_id` and `bundle_id`, and of a tunnel's
  /// token the start of the tunnel's id at Cloudflare (`tunnel`).
  final Map<String, String> shown;

  /// Who typed or removed it in the app last, and when; empty and null when nobody has.
  final String by;
  final int? atMs;

  /// A manager removed it in the app: none is in force, whatever the hub's own file says.
  final bool removed;

  /// It was typed in the app, but on another hub, and this hub cannot open it.
  final bool unreadable;

  /// How it stands, in one line. [now] is the hub's clock.
  String words(DateTime now) {
    final who = by.isEmpty ? '' : ' by $by';
    final at = atMs == null ? null : DateTime.fromMillisecondsSinceEpoch(atMs!);
    final when = at == null ? '' : ', ${keyDay(at, now)}';
    final tail = switch (name) {
      'push_apple' => shown['key_id'] == null ? '' : ' · key ${shown['key_id']}, team ${shown['team_id'] ?? ''}',
      'online_tunnel' => (shown['tunnel'] ?? '').isEmpty ? '' : ' · tunnel ${shown['tunnel']}',
      _ => ending.isEmpty ? '' : ' · ends in $ending',
    };
    if (unreadable) {
      final meanwhile = set ? " The one from this hub's terminal is used meanwhile$tail." : '';
      return 'Typed in the app$who, but on another hub, and this hub cannot read it. Type it again here.$meanwhile';
    }
    if (set && source == 'app') return 'Set$tail · typed here$who$when';
    if (set) return "Set in the hub's terminal$tail";
    if (removed) return 'Not set · removed here$who$when';
    return 'Not set';
  }
}

/// A day for the line under a key: "today", "yesterday", or "Nov 24" (with the year when it is another).
String keyDay(DateTime at, DateTime now) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final day = DateTime(at.year, at.month, at.day);
  final days = DateTime(now.year, now.month, now.day).difference(day).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  return '${months[at.month - 1]} ${at.day}${at.year == now.year ? '' : ', ${at.year}'}';
}

/// One of the restaurant's accounts with GloriaFood: a website of its own there, or the account it tries
/// things out with. Each has its own key for asking, and its orders say which account brought them.
class OnlineAccount {
  const OnlineAccount({required this.id, this.name = '', this.test = false, required this.key});

  factory OnlineAccount.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final key = json['key'];
    return OnlineAccount(
      id: id,
      name: json['name'] as String? ?? '',
      test: json['test'] == true,
      key: key is Map ? HubKey.fromJson(key.cast<String, dynamic>()) : HubKey(name: slotOf(id)),
    );
  }

  /// The first account: the one a hub had before there could be several. It is always there.
  static const first = 'main';

  /// The name an account's key is kept under on the hub.
  static String slotOf(String id) => id == first ? 'online' : 'online:$id';

  /// The hub's own name for it, never shown.
  final String id;

  /// What the restaurant calls it ("Sushi site"); the first account may have none.
  final String name;

  /// It is the account the restaurant only tests with: its orders say TEST wherever they show.
  final bool test;

  /// Its key for asking, as the hub describes it.
  final HubKey key;

  bool get isFirst => id == first;

  /// What to call it where it has to be told from the others.
  String get called => name.isNotEmpty ? name : 'First account';
}

/// How the Cloudflare Tunnel stands, as the hub's tunnel program says.
class TunnelState {
  const TunnelState({this.there = false, this.state = 'off', this.sinceMs, this.reason, this.said = ''});

  factory TunnelState.fromJson(Map<String, dynamic> json) => TunnelState(
    there: json['there'] == true,
    state: json['state'] as String? ?? 'off',
    sinceMs: (json['since_ms'] as num?)?.toInt(),
    reason: json['reason'] as String?,
    said: json['said'] as String? ?? '',
  );

  /// The hub runs a tunnel program that says how it stands. False on a hub that was not updated, or
  /// whose tunnel program stopped.
  final bool there;

  /// `off` (it has no token), `starting`, `connected` or `failing`.
  final String state;
  final int? sinceMs;

  /// While it is failing: `refused` (Cloudflare did not take the token), `unreachable`, `slow`, `missing`
  /// (the hub has no tunnel program), or `trouble`, with Cloudflare's program's own last word in [said].
  final String? reason;
  final String said;

  bool get connected => there && state == 'connected';

  /// Something a person has to do something about, on a hub that has a token.
  bool get bad => !there || state == 'failing';

  /// How the tunnel of a hub that has a token stands, in a line or two. [now] is the terminal's clock.
  String words(DateTime now) {
    if (!there) return "The hub's tunnel program is not running. Update the hub (sudo hubctl update).";
    var since = '';
    if (sinceMs != null) {
      final day = keyDay(DateTime.fromMillisecondsSinceEpoch(sinceMs!), now);
      since = day == 'today' ? ' since ${clockTime(sinceMs!)}' : ' since $day';
    }
    return switch (state) {
      'connected' => 'Connected to Cloudflare$since.',
      'failing' => switch (reason) {
        'refused' =>
          'Not connected: Cloudflare did not take the token. Copy it again from the tunnel at Cloudflare, and '
              'replace it here.',
        'unreachable' => "Not connected: the hub cannot reach Cloudflare. Look at the restaurant's internet.",
        'slow' => 'Not connected yet: it is taking long to reach Cloudflare.',
        'missing' => 'Not connected: this hub has no tunnel program. Update the hub (sudo hubctl update).',
        _ => said.isEmpty ? 'Not connected to Cloudflare.' : "Not connected. Cloudflare's program says: $said",
      },
      _ => 'On its way to Cloudflare, not connected yet.',
    };
  }
}

/// The way in for GloriaFood's pushes, as the hub describes it beside its keys.
class WayIn {
  const WayIn({this.address = '', this.door, this.tunnel = const TunnelState()});

  factory WayIn.fromJson(Map<String, dynamic> json) => WayIn(
    address: json['address'] as String? ?? '',
    door: json['door'] as bool?,
    tunnel: json['tunnel'] is Map
        ? TunnelState.fromJson((json['tunnel'] as Map).cast<String, dynamic>())
        : const TunnelState(),
  );

  /// The name on the internet GloriaFood sends its pushes to, as a manager typed it; empty when none was.
  final String address;

  /// Whether the hub could tell the push door its key; null on a machine that runs no door.
  final bool? door;
  final TunnelState tunnel;

  /// What goes into GloriaFood's admin as the endpoint, or null while no address is known.
  String? get endpoint => address.isEmpty ? null : 'https://$address/online/push';
}

/// What a try of the way in came to: the hub knocked at its own push door, and, where an address is known,
/// from outside at the address GloriaFood sends to.
class WayTried {
  const WayTried({required this.doorOk, this.doorReason, this.doorCode, this.outside});

  factory WayTried.fromJson(Map<String, dynamic> json) {
    final door = (json['door'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final outside = (json['outside'] as Map?)?.cast<String, dynamic>();
    return WayTried(
      doorOk: door['ok'] == true,
      doorReason: door['reason'] as String?,
      doorCode: (door['code'] as num?)?.toInt(),
      outside: outside == null
          ? null
          : (
              address: outside['address'] as String? ?? '',
              ok: outside['ok'] == true,
              reason: outside['reason'] as String?,
              code: (outside['code'] as num?)?.toInt(),
            ),
    );
  }

  final bool doorOk;
  final String? doorReason;
  final int? doorCode;

  /// The knock from outside; null when no address is known, and when the door did not open.
  final ({String address, bool ok, String? reason, int? code})? outside;

  /// The whole way in works, as far as it was tried.
  bool get ok => doorOk && (outside?.ok ?? true);

  /// Something is wrong. A door that opens with no address to try from outside is not.
  bool get bad => !ok;

  String get words {
    if (!doorOk) {
      return switch (doorReason) {
        'no_answer' => 'The push door is not running on this hub. Update the hub (sudo hubctl update).',
        'shut' => 'The push door is shut: it was not told the key. Replace the key here, or update the hub.',
        'api' => 'The push door is up, but could not hand a push on to the hub.',
        _ => 'The push door answered in a way this hub does not know (${doorCode ?? 'nothing'}).',
      };
    }
    final tried = outside;
    if (tried == null) {
      return 'The push door is open and leads to this hub. Give the address GloriaFood sends to, and the way in '
          'from outside is tried too.';
    }
    final at = tried.address;
    if (tried.ok) {
      return 'The whole way in works: https://$at/online/push reaches this hub. That is the address for '
          "GloriaFood's admin. No key was sent anywhere.";
    }
    final why = switch (tried.reason) {
      'no_answer' => 'nothing answers at $at. Check the name, and that the tunnel has a public hostname for it.',
      'late' => '$at did not answer in time.',
      'elsewhere' =>
        '$at answers, but not from this hub. At Cloudflare, the public hostname must be handed to '
            'http://door:8090.',
      'not_routed' =>
        '$at is known, but leads nowhere for /online/push. At Cloudflare, the public hostname needs the path '
            'online/push and the service http://door:8090.',
      'blocked' => '$at turned the call away (403). A rule at Cloudflare is in the way.',
      'tunnel_down' =>
        'Cloudflare answers for $at but cannot get to the push door (${tried.code}). Is the tunnel connected, '
            'and its service http://door:8090?',
      'redirect' => '$at sends callers on to another address (${tried.code}), which GloriaFood does not follow.',
      _ => "$at answered ${tried.code ?? 'nothing'}, which is not what this hub's door answers.",
    };
    return 'The push door is open, but from outside $why';
  }
}

/// Every key the hub holds, as it stands.
class HubKeys {
  const HubKeys({required this.keys, this.kept = true, this.onlineAccounts, this.added, this.wayIn, this.tried});

  factory HubKeys.fromJson(Map<String, dynamic> json) => HubKeys(
    keys: [
      for (final key in json['keys'] as List? ?? const [])
        if (key is Map) HubKey.fromJson(key.cast<String, dynamic>()),
    ],
    kept: json['kept'] != false,
    onlineAccounts: json['online_accounts'] is List
        ? [
            for (final account in json['online_accounts'] as List)
              if (account is Map && account['id'] is String) OnlineAccount.fromJson(account.cast<String, dynamic>()),
          ]
        : null,
    added: json['added'] as String?,
    wayIn: json['way_in'] is Map ? WayIn.fromJson((json['way_in'] as Map).cast<String, dynamic>()) : null,
    tried: json['tried'] is Map ? WayTried.fromJson((json['tried'] as Map).cast<String, dynamic>()) : null,
  );

  /// The account that was just added, in the answer to adding one.
  final String? added;

  /// The way in for GloriaFood's pushes; null from a hub older than setting it in the app.
  final WayIn? wayIn;

  /// What a try of the way in came to, in the answer to trying it.
  final WayTried? tried;

  final List<HubKey> keys;

  /// False on a hub that has nowhere to keep a typed key over a restart.
  final bool kept;

  /// The restaurant's accounts with GloriaFood, the first account first; null on a hub from before there
  /// could be several, which has the one key `online` and nothing to add.
  final List<OnlineAccount>? onlineAccounts;

  /// The accounts as the page lists them: the hub's own list, or, on a hub that knows of one only, that one.
  List<OnlineAccount> get accounts {
    final listed = onlineAccounts;
    if (listed != null && listed.isNotEmpty) return listed;
    final only = named('online');
    return [if (only != null) OnlineAccount(id: OnlineAccount.first, key: only)];
  }

  HubKey? named(String name) {
    for (final key in keys) {
      if (key.name == name) return key;
    }
    return null;
  }

  /// One line for the row under Location: which are set and which are not, by the names on the page.
  String get summary {
    final known = [
      for (final key in keys)
        if (hubKeyInfo[key.name] != null) key,
    ];
    if (known.isEmpty) return 'This hub holds no keys the app knows';
    // GloriaFood with several accounts: set as far as its accounts are, and the ones without a key by name
    final several = accounts.length > 1;
    final asked = accounts.where((account) => account.key.set).length;
    String word(HubKey key, {required bool set}) {
      final short = hubKeyInfo[key.name]!.short;
      if (key.name != 'online' || !several) return short;
      if (set) return '$short ($asked ${asked == 1 ? 'account' : 'accounts'})';
      return '$short (${[for (final account in accounts)
        if (!account.key.set) account.called].join(', ')})';
    }

    bool isOn(HubKey key) => key.name == 'online' && several ? asked > 0 : key.set;
    bool isOff(HubKey key) => key.name == 'online' && several ? asked < accounts.length : !key.set;
    final on = [
      for (final key in known)
        if (isOn(key)) word(key, set: true),
    ];
    final off = [
      for (final key in known)
        if (isOff(key)) word(key, set: false),
    ];
    if (off.isEmpty) return 'All set: ${on.join(', ')}';
    if (on.isEmpty) return 'None set yet: ${off.join(', ')}';
    return 'Set: ${on.join(', ')} · Not set: ${off.join(', ')}';
  }
}

/// How the page words one key.
class HubKeyInfo {
  const HubKeyInfo({
    required this.title,
    required this.short,
    required this.about,
    required this.without,
    required this.where,
    required this.removing,
  });

  /// The same words under another title: one of several accounts of the same service.
  HubKeyInfo titled(String title) =>
      HubKeyInfo(title: title, short: short, about: about, without: without, where: where, removing: removing);

  /// The card's title, and the name in the dialogs.
  final String title;

  /// A word or two for the row under Location.
  final String short;

  /// What the hub does with it.
  final String about;

  /// What happens while there is none.
  final String without;

  /// Where the owner finds the key.
  final String where;

  /// What stops when it is removed, for the question before removing.
  final String removing;
}

/// The keys the app knows, in the order the page shows them. One the hub lists and the app does not know
/// is left alone and not shown.
const hubKeyInfo = <String, HubKeyInfo>{
  'maps': HubKeyInfo(
    title: 'Map service (Geocodio)',
    short: 'map service',
    about: 'Asked how far a delivery is, so the form can pick the delivery fee.',
    without: 'Without it no distance is looked up, and the delivery fee is picked by hand.',
    where: 'At geocod.io: sign in, API Keys, and create a key that has the Distance permission.',
    removing: 'The hub stops asking Geocodio how far a delivery is.',
  ),
  'maps_google': HubKeyInfo(
    title: 'Google Maps',
    short: 'Google Maps',
    about: 'Asked when the map service gives no distance, and about the roads right now for live traffic.',
    without: 'Without it there is no second map service, and live traffic cannot be used.',
    where:
        'In the Google Cloud console: Keys & Credentials, Create credentials, API key, restricted to the '
        'Routes API.',
    removing: 'The hub stops asking Google Maps. Live traffic, if it is on, is no longer used.',
  ),
  'online': HubKeyInfo(
    title: 'GloriaFood (online orders)',
    short: 'GloriaFood',
    about: 'The hub asks GloriaFood with it, every minute, for the orders accepted on the website.',
    without: 'Without it the hub asks GloriaFood for nothing.',
    where:
        "In GloriaFood's admin: Others, Third party integrations, the key of the integration Poll Accepted "
        'Order v2.',
    removing: 'The hub stops asking GloriaFood for orders. The orders already on the POS stay as they are.',
  ),
  'online_push': HubKeyInfo(
    title: 'GloriaFood push key',
    short: 'GloriaFood push',
    about:
        'GloriaFood sends an order to the hub the moment it is accepted, and every push must carry this key. '
        'The asking every minute stays on beside it.',
    without: 'Without it every push is turned away, and orders arrive by the asking alone.',
    where:
        'Yours to make: press Make one, copy it, and save. Then put the same key into GloriaFood\'s admin, as '
        'the master key of the integration Push Accepted Order.',
    removing: 'The hub turns every push away, and the push door shuts. Orders still arrive by the asking.',
  ),
  'online_tunnel': HubKeyInfo(
    title: 'Cloudflare Tunnel (the way in)',
    short: 'Cloudflare tunnel',
    about:
        'The hub calls out to Cloudflare and holds the line, and GloriaFood\'s pushes come down it to the push '
        'door. Nothing is opened on your router.',
    without: 'Without it nothing from outside reaches the hub, unless your own router brings pushes to the door.',
    where:
        'In Cloudflare\'s dashboard: Zero Trust, Networks, Tunnels, your tunnel. Copy the command it shows for '
        'installing it and paste it here whole, or only the long word in it that starts with eyJ.',
    removing: 'The tunnel is closed: nothing from outside reaches the hub. Orders still arrive by the asking.',
  ),
  'push_apple': HubKeyInfo(
    title: 'Apple push key',
    short: 'Apple push',
    about: 'The hub wakes a locked iPhone or iPad with it, for a call or for a desk-phone pick-up.',
    without: 'Without it a locked iPhone or iPad is not woken. Screens that stay on are not affected.',
    where:
        "In Apple's developer account: Certificates, IDs & Profiles, Keys. The file is named "
        'AuthKey_<key id>.p8 and can be downloaded once.',
    removing: 'The hub stops waking locked iPhones and iPads.',
  ),
};
