/// Conversations by text with customers, as the hub answers them (docs/text-inbox.md).
///
/// The hub keeps every text by the customer's number: what they wrote to the restaurant's number, what
/// somebody here answered, and the POS's own texts to an order. It reads the customers' texts from Twilio
/// and hands the answers to it. The hub makes every rule; this is its answers read into names, and the
/// words the screens say about them.
library;

import 'phone.dart' show formatPhoneNumber;
import 'shift_notes.dart' show dayWords;
import 'takeout.dart' show clockTime;

String _s(Object? value, [String or = '']) => value is String ? value : or;
int _i(Object? value) => value is num ? value.toInt() : 0;
int? _ms(Object? value) => value is num ? value.toInt() : null;
Map<String, dynamic> _map(Object? value) => value is Map ? value.cast<String, dynamic>() : const {};
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) row.cast<String, dynamic>(),
];

/// The longest text the hub takes, in characters.
const textMax = 1600;

/// A picture (or another file) a text carries. The hub hands it over by the text's id and [n].
class TextPicture {
  const TextPicture({required this.n, this.type = '', this.image = false});

  factory TextPicture.fromJson(Map<String, dynamic> json) =>
      TextPicture(n: _i(json['n']), type: _s(json['type']), image: json['image'] == true);

  final int n;

  /// What it is, as Twilio names it: `image/jpeg`, `video/mp4`, `text/vcard`.
  final String type;

  /// Whether a screen can show it. Anything else is named and not opened.
  final bool image;
}

/// One text, in or out.
class TextMessage {
  const TextMessage({
    required this.id,
    this.phone = '',
    this.inbound = false,
    this.body = '',
    this.atMs = 0,
    this.state = 'waiting',
    this.channel = 'sms',
    this.pictures = const [],
    this.picturesN = 0,
    this.code,
    this.said = '',
    this.kind = '',
    this.orderId = '',
    this.by = '',
  });

  factory TextMessage.fromJson(Map<String, dynamic> json) => TextMessage(
    id: _s(json['id']),
    phone: _s(json['phone']),
    inbound: json['inbound'] == true,
    body: _s(json['body']),
    atMs: _i(json['at_ms']),
    state: _s(json['state'], 'waiting'),
    channel: _s(json['channel'], 'sms'),
    pictures: [for (final row in _rows(json['pictures'])) TextPicture.fromJson(row)],
    picturesN: _i(json['pictures_n']),
    code: _ms(json['code']),
    said: _s(json['said']),
    kind: _s(json['kind']),
    orderId: _s(json['order_id']),
    by: _s(json['by']),
  );

  final String id;
  final String phone;

  /// The customer wrote it; otherwise it went from the restaurant.
  final bool inbound;
  final String body;
  final int atMs;

  /// `received` for the customer's; for ours `waiting`, `sent`, `delivered`, `read` or `failed`.
  final String state;

  /// `sms`, `mms` or `rcs`.
  final String channel;

  /// The pictures the hub has learned of, and how many Twilio says there are.
  final List<TextPicture> pictures;
  final int picturesN;

  /// For one that failed: Twilio's number for why, and the hub's words for it.
  final int? code;
  final String said;

  /// Empty: a person typed it. `ready`, `out`, `delayed`: the POS's own text to an order. `elsewhere`:
  /// sent from the restaurant's number by something that is not the POS.
  final String kind;
  final String orderId;

  /// Who typed it.
  final String by;

  bool get failed => state == 'failed';
}

/// The newest text of a conversation, for its line in the list.
class TextLast {
  const TextLast({this.body = '', this.atMs = 0, this.inbound = false, this.state = '', this.picturesN = 0});

  factory TextLast.fromJson(Map<String, dynamic> json) => TextLast(
    body: _s(json['body']),
    atMs: _i(json['at_ms']),
    inbound: json['inbound'] == true,
    state: _s(json['state']),
    picturesN: _i(json['pictures_n']),
  );

  final String body;
  final int atMs;
  final bool inbound;
  final String state;
  final int picturesN;
}

/// Everything with one number.
class TextThread {
  const TextThread({
    required this.phone,
    this.digits = '',
    this.name = '',
    this.unread = 0,
    this.readBy = '',
    this.stoppedMs,
    this.last,
  });

  factory TextThread.fromJson(Map<String, dynamic> json) => TextThread(
    phone: _s(json['phone']),
    digits: _s(json['digits']),
    name: _s(json['name']),
    unread: _i(json['unread']),
    readBy: _s(json['read_by']),
    stoppedMs: _ms(json['stopped_ms']),
    last: json['last'] is Map ? TextLast.fromJson(_map(json['last'])) : null,
  );

  /// The number as the hub keeps conversations by: `+17815550142`.
  final String phone;

  /// The same number as the orders keep it: `7815550142`.
  final String digits;

  /// What the POS knows the customer by; empty for a number it has not met.
  final String name;

  /// How many of the customer's texts nobody has opened.
  final int unread;
  final String readBy;

  /// Since when the customer wants no more texts (they answered STOP); null while they take them.
  final int? stoppedMs;
  final TextLast? last;

  bool get stopped => stoppedMs != null;

  /// The number the way a screen says it: `781 555 0142`.
  String get number => formatPhoneNumber(phone);

  /// The name where there is one, the number otherwise.
  String get title => name.trim().isEmpty ? number : name.trim();
}

/// Whether the hub can hear Twilio.
class TextListening {
  const TextListening({this.ok, this.atMs, this.said = ''});

  factory TextListening.fromJson(Map<String, dynamic> json) => TextListening(
    ok: json['ok'] is bool ? json['ok'] as bool : null,
    atMs: _ms(json['at_ms']),
    said: _s(json['said']),
  );

  /// Whether Twilio answered the last time the hub asked; null before the first asking.
  final bool? ok;
  final int? atMs;

  /// Why not, in the hub's words.
  final String said;
}

/// What a text of the staff's can carry besides words (`send` of the hub's answers).
class TextSends {
  const TextSends({this.known = false, this.pictures = false, this.most = 5, this.bytes = 4500000});

  factory TextSends.fromJson(Object? json) {
    if (json is! Map) return const TextSends();
    final most = _i(json['most']), bytes = _i(json['bytes']);
    return TextSends(
      known: true,
      pictures: json['pictures'] == true,
      most: most > 0 ? most : 5,
      bytes: bytes > 0 ? bytes : 4500000,
    );
  }

  /// The hub knows of pictures in the staff's texts at all. A hub from before them says nothing.
  final bool known;

  /// A picture can go now: Twilio can fetch it from this hub (docs/text-inbox.md, "Instant delivery and
  /// pictures"). False until a manager has set that up.
  final bool pictures;

  /// How many pictures one text carries at the most, and how many bytes they may be together.
  final int most;
  final int bytes;
}

/// The list of conversations (`GET /texts`).
class TextInbox {
  const TextInbox({
    this.on = false,
    this.number = '',
    this.listening = const TextListening(),
    this.unread = 0,
    this.threads = const [],
    this.sends = const TextSends(),
  });

  factory TextInbox.fromJson(Map<String, dynamic> json) => TextInbox(
    on: json['on'] == true,
    number: _s(json['number']),
    listening: TextListening.fromJson(_map(json['listening'])),
    unread: _i(json['unread']),
    threads: [for (final row in _rows(json['threads'])) TextThread.fromJson(row)],
    sends: TextSends.fromJson(json['send']),
  );

  /// The hub has a Twilio account. Without one nothing comes and nothing goes.
  final bool on;

  /// The number the restaurant texts from, where the account names one.
  final String number;
  final TextListening listening;

  /// How many conversations hold something nobody has opened.
  final int unread;

  /// The one with the newest text first.
  final List<TextThread> threads;
  final TextSends sends;
}

/// What a button's badge needs (`GET /texts/unread`).
class TextsUnread {
  const TextsUnread({this.on = false, this.unread = 0});

  factory TextsUnread.fromJson(Map<String, dynamic> json) =>
      TextsUnread(on: json['on'] == true, unread: _i(json['unread']));

  final bool on;
  final int unread;

  @override
  bool operator ==(Object other) => other is TextsUnread && other.on == on && other.unread == unread;

  @override
  int get hashCode => Object.hash(on, unread);
}

/// One conversation (`GET /texts/with/{number}`).
class TextPage {
  const TextPage({
    required this.thread,
    this.on = false,
    this.texts = const [],
    this.more = false,
    this.before = '',
    this.after = '',
    this.sends = const TextSends(),
  });

  factory TextPage.fromJson(Map<String, dynamic> json) {
    final wrap = _map(json['wrap']);
    return TextPage(
      on: json['on'] == true,
      thread: TextThread.fromJson(_map(json['thread'])),
      texts: [for (final row in _rows(json['texts'])) TextMessage.fromJson(row)],
      more: json['more'] == true,
      before: _s(wrap['before']),
      after: _s(wrap['after']),
      sends: TextSends.fromJson(json['send']),
    );
  }

  final bool on;
  final TextThread thread;

  /// The oldest first.
  final List<TextMessage> texts;

  /// There are older ones than these.
  final bool more;

  /// What the hub puts around the first text to a number that has no conversation yet: who it is from
  /// before it, how to stop the texts after it. Both empty once there is a conversation.
  final String before;
  final String after;

  /// What a text typed here can carry.
  final TextSends sends;

  bool get wraps => before.isNotEmpty || after.isNotEmpty;

  /// This conversation with other [texts], and whether there are [more] before them.
  TextPage withTexts(List<TextMessage> texts, {bool? more}) => TextPage(
    on: on,
    thread: thread,
    texts: texts,
    more: more ?? this.more,
    before: before,
    after: after,
    sends: sends,
  );

  /// These texts with [older] ones in front (a page further back), each text once.
  TextPage withOlder(TextPage older) {
    final have = {for (final text in texts) text.id};
    return withTexts([
      for (final text in older.texts)
        if (!have.contains(text.id)) text,
      ...texts,
    ], more: older.more);
  }

  /// This page as newly read, keeping the [earlier] texts the screen had fetched from further back.
  TextPage keeping(TextPage? earlier) {
    if (earlier == null || texts.isEmpty || earlier.thread.phone != thread.phone) return this;
    final oldest = texts.first.atMs;
    final have = {for (final text in texts) text.id};
    final kept = [
      for (final text in earlier.texts)
        if (text.atMs <= oldest && !have.contains(text.id)) text,
    ];
    if (kept.isEmpty) return this;
    return withTexts([...kept, ...texts], more: earlier.more);
  }
}

/// A number as somebody typed it, the way the hub keeps conversations by (`+17815550142`); null for what
/// is no number a text can go to. Ten digits are a number of this country's.
String? textNumber(String typed) {
  final text = typed.trim();
  final digits = text.replaceAll(RegExp(r'\D'), '');
  if (text.startsWith('+')) return digits.length >= 8 && digits.length <= 15 ? '+$digits' : null;
  if (digits.length == 10 && !'01'.contains(digits[0])) return '+1$digits';
  if (digits.length == 11 && digits[0] == '1' && !'01'.contains(digits[1])) return '+$digits';
  return null;
}

/// When a text was, beside it: "16:05" today, "yesterday 22:10", "Sat Nov 14, 16:05".
String textWhen(int atMs, DateTime now) {
  final day = dayWords(DateTime.fromMillisecondsSinceEpoch(atMs), now);
  final time = clockTime(atMs);
  if (day == 'today') return time;
  return day == 'yesterday' ? 'yesterday $time' : '$day, $time';
}

/// When a conversation's newest text was, on its line of the list: the time today, the day before that.
String threadWhen(int atMs, DateTime now) {
  final day = dayWords(DateTime.fromMillisecondsSinceEpoch(atMs), now);
  return day == 'today' ? clockTime(atMs) : day;
}

/// The words for what a text carries besides words.
String picturesWords(int n) => n == 1 ? 'A picture' : '$n pictures';

/// A conversation's newest text as one line of the list.
String lastWords(TextLast last) {
  final body = last.body.replaceAll(RegExp(r'\s+'), ' ').trim();
  final said = body.isEmpty && last.picturesN > 0 ? picturesWords(last.picturesN) : body;
  if (last.inbound) return said;
  return last.state == 'failed' ? 'Not sent: $said' : 'You: $said';
}

/// What became of a text of ours, under it.
String stateWords(TextMessage text) => switch (text.state) {
  'waiting' => 'Sending',
  'sent' => 'Sent',
  'delivered' => 'Delivered',
  'read' => 'Read',
  'failed' => text.said.isEmpty ? 'Not sent' : 'Not sent: ${text.said}',
  _ => '',
};

/// Who or what sent a text of ours, under it: the person, or the POS for its own texts to an order.
String senderWords(TextMessage text) => switch (text.kind) {
  'ready' => 'The POS: order ready',
  'out' => 'The POS: order on its way',
  'delayed' => 'The POS: a new time',
  'elsewhere' => "From the restaurant's number, not the POS",
  _ => text.by,
};

/// Under a text: who, when, how it travelled when that is not a plain text, and what became of it.
String underWords(TextMessage text, DateTime now) => [
  if (!text.inbound && senderWords(text).isNotEmpty) senderWords(text),
  textWhen(text.atMs, now),
  if (text.channel == 'rcs') 'RCS',
  if (!text.inbound && stateWords(text).isNotEmpty) stateWords(text),
].join(' · ');

/// What a first text looks like on the customer's phone, with what the hub puts around it. With [pictures]
/// and no words it still says who it is from: the name without its colon, as the hub sends it.
String wrapped(TextPage page, String typed, {bool pictures = false}) {
  final words = typed.trim();
  if (words.isNotEmpty || !pictures) return '${page.before}$words${page.after}';
  final from = page.before.trimRight();
  return '${from.endsWith(':') ? from.substring(0, from.length - 1) : from}${page.after}'.trim();
}

/// What the Texts tile of the home screen's menu says under its name: how many conversations hold something
/// nobody has read. Nothing while none does.
String? unreadNote(int unread) => unread <= 0 ? null : '$unread not read';
