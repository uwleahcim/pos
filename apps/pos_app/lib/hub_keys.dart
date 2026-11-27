/// The hub's keys for the services outside the restaurant (docs/hub-keys.md): the map services a
/// delivery's distance is asked of, the ones that list addresses while one is typed, GloriaFood for the
/// website's orders, and Apple for waking a locked iPhone. A manager types them under Location, Keys and connections; the hub keeps them sealed and uses
/// them at once. What the hub tells a screen about a key (`GET /hub/keys`) is never the key: whether one is
/// in force, where it came from, its last characters, and who typed it and when.
///
/// GloriaFood's key comes in several: a restaurant with more than one website there, or an account it only
/// tests with, has a key for each ([OnlineAccount]; docs/online-orders.md, "Several accounts").
///
/// Two of the keys are for GloriaFood's own pushes (docs/online-orders.md, "Push"): the key a push must
/// carry, and the token of the Cloudflare Tunnel that brings pushes in. The hub says how that way in stands
/// ([WayIn]) and can try it ([WayTried]).
///
/// One is the restaurant's Twilio account (`texts`; docs/texts.md), which the texts to customers go out
/// with. The hub says how the texts are doing ([TextsState]) and can send one to try it ([TextTried]).
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

  /// `maps`, `maps_google`, `maps_mapbox`, `maps_azure`, `online`, `online_push`, `online_tunnel`,
  /// `push_apple` or `texts`; `online:<id>` for a further account of GloriaFood's.
  final String name;

  /// A key is in force on the hub.
  final bool set;

  /// Where the one in force comes from: `app` (typed here), `hub` (put on the hub in its terminal, with
  /// hubctl), or null when there is none.
  final String? source;

  /// The key's last characters, to tell one key from another; empty for a short key and for Apple's.
  final String ending;

  /// What belongs to a key and is no secret: Apple's `key_id`, `team_id` and `bundle_id`, of a tunnel's
  /// token the start of the tunnel's id at Cloudflare (`tunnel`), and of the Twilio account its Account
  /// SID (`account`), what the texts are sent from (`sender`) and an API key's SID (`key_sid`).
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
      'texts' => (shown['sender'] ?? '').isEmpty ? '' : ' · sent from ${shown['sender']}',
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

/// How the texts to customers are doing, as the hub says beside its keys (docs/texts.md). Nothing in it is
/// a customer's: no number and no words of a text.
class TextsState {
  const TextsState({this.provider = 'log', this.sender = '', this.texts = 0, this.failed = 0, this.lastFailed});

  factory TextsState.fromJson(Map<String, dynamic> json) {
    final day = (json['day'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final failed = (json['last_failed'] as Map?)?.cast<String, dynamic>();
    return TextsState(
      provider: json['provider'] as String? ?? 'log',
      sender: json['sender'] as String? ?? '',
      texts: (day['texts'] as num?)?.toInt() ?? 0,
      failed: (day['failed'] as num?)?.toInt() ?? 0,
      lastFailed: failed == null
          ? null
          : (
              orderNo: (failed['order_no'] as num?)?.toInt(),
              kind: failed['kind'] as String? ?? '',
              atMs: (failed['at_ms'] as num?)?.toInt(),
              said: failed['said'] as String? ?? '',
            ),
    );
  }

  /// `twilio` once the hub sends its texts through Twilio; `log` while it only writes them down.
  final String provider;

  /// What the texts are sent from: a number of the Twilio account's, or a Messaging Service's SID.
  final String sender;

  /// How many texts the hub was asked to send in the last 24 hours, and how many of those did not go.
  final int texts;
  final int failed;

  /// The last text of that day that did not go: for which order, which text, when, and why in words.
  final ({int? orderNo, String kind, int? atMs, String said})? lastFailed;

  /// The texts really go out.
  bool get on => provider == 'twilio';

  /// The last day in a line.
  String get dayWords {
    if (texts == 0) return 'No text has gone out in the last 24 hours.';
    final went = texts == 1 ? '1 text' : '$texts texts';
    if (failed == 0) return '$went in the last 24 hours. None failed.';
    return '$went in the last 24 hours. $failed did not go.';
  }

  /// The last text that did not go, in a line; null when none failed.
  String? get failedWords {
    final last = lastFailed;
    if (last == null) return null;
    final which = switch (last.kind) {
      'ready' => 'the ready text',
      'out' => 'the "on its way" text',
      'delayed' => 'the text with the new time',
      _ => 'a text',
    };
    final order = last.orderNo == null ? '' : ' for order #${last.orderNo}';
    final at = last.atMs == null ? '' : ', at ${clockTime(last.atMs!)}';
    final why = last.said.trim();
    final said = why.isEmpty ? '' : ' ${why[0].toUpperCase()}${why.substring(1)}${why.endsWith('.') ? '' : '.'}';
    return 'The last one that did not go: $which$order$at.$said';
  }
}

/// What a try of the texts came to: one text to a number the manager typed.
class TextTried {
  const TextTried({required this.ok, this.state = 'failed', this.code, this.said = ''});

  factory TextTried.fromJson(Map<String, dynamic> json) => TextTried(
    ok: json['ok'] == true,
    state: json['state'] as String? ?? 'failed',
    code: (json['code'] as num?)?.toInt(),
    said: json['said'] as String? ?? '',
  );

  final bool ok;

  /// `delivered` (the phone company said it arrived), `sent` (Twilio took it, and the phone company has
  /// not said yet) or `failed`.
  final String state;

  /// Twilio's own error number, where it gave one.
  final int? code;

  /// Why it did not go, in the hub's words.
  final String said;

  bool get bad => !ok;

  String get words {
    if (!ok) {
      final why = said.trim();
      if (why.isEmpty) return 'The text did not go.';
      return 'The text did not go. ${why[0].toUpperCase()}${why.substring(1)}${why.endsWith('.') ? '' : '.'}';
    }
    if (state == 'delivered') return 'Delivered. Look at that phone: the text is there. The account works.';
    return 'Twilio took the text, and the phone company has not said yet whether it arrived. Look at that phone. '
        'If nothing comes, the number the texts are sent from may not be registered for business texts yet '
        "(A2P 10DLC, in Twilio's console).";
  }
}

/// Twilio's way in, as the hub says beside its keys (docs/text-inbox.md, "Instant delivery and pictures"):
/// Twilio calls the hub the moment a text comes or changes, and fetches from it the pictures the staff
/// send. It comes by the push door and the tunnel, under an address the hub makes itself.
class TextsWay {
  const TextsWay({this.on = false, this.address = '', this.url, this.door, this.calledMs});

  factory TextsWay.fromJson(Map<String, dynamic> json) => TextsWay(
    on: json['on'] == true,
    address: json['address'] as String? ?? '',
    url: json['url'] is String && (json['url'] as String).isNotEmpty ? json['url'] as String : null,
    door: json['door'] as bool?,
    calledMs: (json['called_ms'] as num?)?.toInt(),
  );

  /// A manager turned it on: the hub has made its address for Twilio.
  final bool on;

  /// The hub's name on the internet, the same one GloriaFood sends to; empty while none was given.
  final String address;

  /// What goes into Twilio's console as "A message comes in"; null until it is on and the hub has a name.
  /// Whoever has it can call the hub as Twilio does, so it is copied, and shown with its middle left out.
  final String? url;

  /// Whether the hub could tell the push door of it; null on a machine that runs no door.
  final bool? door;

  /// When Twilio last called, by the hub's clock; null while it has not since the hub started.
  final int? calledMs;

  /// Twilio can be given the address: it is on and the hub has a name on the internet.
  bool get ready => url != null;

  /// [url] for the screen: the part only the hub and Twilio know left out.
  String get shown => address.isEmpty ? '' : 'https://$address/twilio/…/text';

  /// How it stands, in a line or two. [now] is the terminal's clock.
  String words(DateTime now) {
    if (!on) {
      return 'Off. The hub asks Twilio for new texts every few seconds, and a text carries no picture.';
    }
    if (!ready) {
      return "On, but the hub's name on the internet is not known here yet, so there is no address for Twilio. "
          'Press Try it and give the name.';
    }
    final called = calledMs;
    if (called == null) {
      return "On. Twilio has not called yet. Copy the address into Twilio's console, then text the restaurant.";
    }
    final day = keyDay(DateTime.fromMillisecondsSinceEpoch(called), now);
    return 'On. Twilio last called ${day == 'today' ? 'at ${clockTime(called)}' : day}.';
  }
}

/// What a try of Twilio's way in came to: the hub called its own address for Twilio at its push door, and,
/// where it has a name on the internet, from outside.
class TextsWayTried {
  const TextsWayTried({required this.doorOk, this.doorReason, this.doorCode, this.outside});

  factory TextsWayTried.fromJson(Map<String, dynamic> json) {
    final door = (json['door'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final outside = (json['outside'] as Map?)?.cast<String, dynamic>();
    return TextsWayTried(
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

  /// The call from outside; null when the hub has no name on the internet, and when the door did not open.
  final ({String address, bool ok, String? reason, int? code})? outside;

  bool get ok => doorOk && (outside?.ok ?? true);

  /// Something is wrong. A door that opens with no name to try from outside is not.
  bool get bad => !ok;

  String get words {
    if (!doorOk) {
      return switch (doorReason) {
        'no_answer' => 'The push door is not running on this hub. Update the hub (sudo hubctl update).',
        'shut' =>
          "This hub's push door does not let Twilio in yet. Update the hub (sudo hubctl update), then try again.",
        'api' => "The push door is up, but could not hand Twilio's call on to the hub.",
        _ => 'The push door answered in a way this hub does not know (${doorCode ?? 'nothing'}).',
      };
    }
    final tried = outside;
    if (tried == null) {
      return "The door is open for Twilio on this hub. Give the hub's name on the internet, and the way in from "
          'outside is tried too.';
    }
    final at = tried.address;
    if (tried.ok) {
      return "The whole way in works: a call to the address reaches this hub from the internet. Copy it into "
          "Twilio's console. Nothing was sent to Twilio, and nothing went on the POS.";
    }
    final why = switch (tried.reason) {
      'no_answer' => 'nothing answers at $at. Check the name, and that the tunnel has a public hostname for it.',
      'late' => '$at did not answer in time.',
      'elsewhere' =>
        '$at answers, but not from this hub. At Cloudflare, the public hostname must be handed to '
            'http://door:8090.',
      'not_routed' =>
        "$at is known, but lets only GloriaFood's path through. At Cloudflare, open the tunnel's public "
            'hostname and empty its Path box, or add a second public hostname with the path twilio and the '
            'service http://door:8090.',
      'blocked' => '$at turned the call away (403). A rule at Cloudflare is in the way.',
      'tunnel_down' =>
        'Cloudflare answers for $at but cannot get to the push door (${tried.code}). Is the tunnel connected, '
            'and its service http://door:8090?',
      'redirect' => '$at sends callers on to another address (${tried.code}), which Twilio does not follow here.',
      _ => "$at answered ${tried.code ?? 'nothing'}, which is not what this hub's door answers.",
    };
    return 'The door is open for Twilio, but from outside $why';
  }
}

/// Every key the hub holds, as it stands.
class HubKeys {
  const HubKeys({
    required this.keys,
    this.kept = true,
    this.onlineAccounts,
    this.added,
    this.wayIn,
    this.tried,
    this.texts,
    this.textTried,
    this.textsWay,
    this.textsWayTried,
  });

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
    // both tries answer under `tried`: the way in's says how its door fared, the texts' how the text did
    tried: json['tried'] is Map && (json['tried'] as Map).containsKey('door')
        ? WayTried.fromJson((json['tried'] as Map).cast<String, dynamic>())
        : null,
    texts: json['texts'] is Map ? TextsState.fromJson((json['texts'] as Map).cast<String, dynamic>()) : null,
    textTried: json['tried'] is Map && (json['tried'] as Map).containsKey('state')
        ? TextTried.fromJson((json['tried'] as Map).cast<String, dynamic>())
        : null,
    textsWay: json['texts_way'] is Map ? TextsWay.fromJson((json['texts_way'] as Map).cast<String, dynamic>()) : null,
    textsWayTried: json['way_tried'] is Map
        ? TextsWayTried.fromJson((json['way_tried'] as Map).cast<String, dynamic>())
        : null,
  );

  /// The account that was just added, in the answer to adding one.
  final String? added;

  /// The way in for GloriaFood's pushes; null from a hub older than setting it in the app.
  final WayIn? wayIn;

  /// What a try of the way in came to, in the answer to trying it.
  final WayTried? tried;

  /// How the texts to customers are doing; null from a hub older than texts that really go out.
  final TextsState? texts;

  /// What a try of the texts came to, in the answer to trying them.
  final TextTried? textTried;

  /// Twilio's way in; null from a hub older than instant delivery and pictures in a text.
  final TextsWay? textsWay;

  /// What a try of Twilio's way in came to, in the answer to trying it.
  final TextsWayTried? textsWayTried;

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
  'maps_mapbox': HubKeyInfo(
    title: 'Mapbox',
    short: 'Mapbox',
    about:
        'Asked for the list of addresses while one is typed, once Google has used up its free lookups for the '
        'month or is not answering. It is used once it is turned on under Location, Address list.',
    without: 'Without it Mapbox is passed over.',
    where:
        'At mapbox.com: make an account, open Tokens, and copy the default public token (it starts with pk.). '
        'It must have no URL restriction.',
    removing: 'The hub stops asking Mapbox for addresses.',
  ),
  'maps_azure': HubKeyInfo(
    title: 'Azure Maps',
    short: 'Azure Maps',
    about:
        'Asked for the list of addresses while one is typed, once the services before it have used up their '
        'free lookups for the month or are not answering. It is used once it is turned on under Location, '
        'Address list.',
    without: 'Without it Azure Maps is passed over.',
    where: 'In the Azure portal: create an Azure Maps account, open it, Authentication, and copy the Primary Key.',
    removing: 'The hub stops asking Azure Maps for addresses.',
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
  'texts': HubKeyInfo(
    title: 'Texts to customers (Twilio)',
    short: 'Twilio texts',
    about:
        'The hub sends the texts to customers with it: ready for pickup, on its way for a delivery, and the new '
        'time of an order that runs late. It is your own Twilio account, and Twilio bills it for each text.',
    without: 'Without it no text goes out: the hub only writes down what it would have sent.',
    where:
        "In Twilio's console (console.twilio.com), on the first page: the Account SID and the Auth Token. Send "
        "from one of the account's own numbers that can text.",
    removing: 'The hub stops texting customers.',
  ),
};
