/// The hub's keys for the services outside the restaurant (docs/hub-keys.md): the map services a
/// delivery's distance is asked of, GloriaFood for the website's orders, and Apple for waking a locked
/// iPhone. A manager types them under Location, Keys and connections; the hub keeps them sealed and uses
/// them at once. What the hub tells a screen about a key (`GET /hub/keys`) is never the key: whether one is
/// in force, where it came from, its last characters, and who typed it and when.
library;

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

  /// `maps`, `maps_google`, `online` or `push_apple`.
  final String name;

  /// A key is in force on the hub.
  final bool set;

  /// Where the one in force comes from: `app` (typed here), `hub` (put on the hub in its terminal, with
  /// hubctl), or null when there is none.
  final String? source;

  /// The key's last characters, to tell one key from another; empty for a short key and for Apple's.
  final String ending;

  /// What belongs to a key and is no secret: Apple's `key_id`, `team_id` and `bundle_id`.
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

/// Every key the hub holds, as it stands.
class HubKeys {
  const HubKeys({required this.keys, this.kept = true});

  factory HubKeys.fromJson(Map<String, dynamic> json) => HubKeys(
    keys: [
      for (final key in json['keys'] as List? ?? const [])
        if (key is Map) HubKey.fromJson(key.cast<String, dynamic>()),
    ],
    kept: json['kept'] != false,
  );

  final List<HubKey> keys;

  /// False on a hub that has nowhere to keep a typed key over a restart.
  final bool kept;

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
    String list(Iterable<HubKey> some) => [for (final key in some) hubKeyInfo[key.name]!.short].join(', ');
    final on = known.where((key) => key.set), off = known.where((key) => !key.set);
    if (off.isEmpty) return 'All set: ${list(on)}';
    if (on.isEmpty) return 'None set yet: ${list(off)}';
    return 'Set: ${list(on)} · Not set: ${list(off)}';
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
