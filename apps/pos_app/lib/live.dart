import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';

/// What the hub said changed since it last said anything.
class LiveChange {
  const LiveChange({
    this.orders = const {},
    this.everything = false,
    this.menu = false,
    this.settings = false,
    this.notes = false,
    this.waitlist = false,
    this.reservations = false,
    this.online = false,
    this.floor = false,
    this.prints = false,
    this.calls = false,
    this.texts = false,
    this.shipday = false,
  });

  /// The orders that changed, by id.
  final Set<String> orders;

  /// Read everything again: the feed has just (re)connected, so anything may have changed meanwhile, or
  /// more changed than the hub cared to name.
  final bool everything;

  /// The menu was saved, or the 86 board changed.
  final bool menu;

  /// A location setting was written (the courses, the quote times, ...).
  final bool settings;

  /// A note for the shift was put up, changed or taken down (docs/shift-notes.md).
  final bool notes;

  /// A party was put on the waitlist, changed, sat down or taken off (docs/waitlist.md).
  final bool waitlist;

  /// A table was booked, or a reservation changed or ended (docs/reservations.md).
  final bool reservations;

  /// There is an online order to look at, or somebody looked (docs/online-orders.md).
  final bool online;

  /// Who is in tonight's turn for a table changed: a host's word, or the time clock (docs/table-servers.md).
  final bool floor;

  /// The print log has a new print, or one printed or failed (docs/printing.md, "The print log").
  final bool prints;

  /// The phone server has a call recording that is new or changed: an order may list another call
  /// (docs/call-recordings.md).
  final bool calls;

  /// A customer's text came, one of ours went or was delivered, or a conversation was read
  /// (docs/text-inbox.md).
  final bool texts;

  /// Shipday's deliveries or drivers read differently than last time, or the hub's key for it changed
  /// (docs/shipday.md).
  final bool shipday;

  /// Whether a screen showing this order has something to read.
  bool touches(String orderId) => everything || orders.contains(orderId);

  /// Whether a screen showing many orders (the list, the floor, which also carries the courses) has.
  bool get anyOrder => everything || settings || orders.isNotEmpty;

  @override
  String toString() =>
      'LiveChange(${[if (everything) 'everything', if (menu) 'menu', if (settings) 'settings', if (notes) 'notes', if (waitlist) 'waitlist', if (reservations) 'reservations', if (online) 'online', if (floor) 'floor', if (prints) 'prints', if (calls) 'calls', if (texts) 'texts', if (shipday) 'shipday', ...orders].join(', ')})';
}

/// Where the feed stands.
enum LiveState {
  /// Not started, or no backend answers at all.
  off,

  /// A backend answers and the feed is being opened (or opened again): the screens ask meanwhile.
  connecting,

  /// The feed is open and the hub was heard from in time: the screens wait to be told.
  live,

  /// The backend that answers is older than the feed: the screens ask, as they always did.
  unsupported,
}

/// The hub's change feed, held open: the hub says which orders changed, that the menu did, that a setting
/// did, the moment they do, and the screens read just that instead of asking every two seconds.
///
/// One request (`GET /live`, server-sent events) to the backend the other calls found ([PosApi.connection]).
/// The feed says *that* something changed; a screen then reads it with the call it always used, which
/// answers "the one you have" when it already has it. So nothing here is needed to be right: while the
/// feed is not [isLive] (an older hub, a connection that just dropped, a test) every screen polls exactly as
/// before, and while it is, each still asks on its own now and then ([SafetyPoll]).
///
/// The hub writes a line every second when it has no news. Silence for three of those means the hub or the
/// network is gone: the feed stops being live at once (the screens ask again), asks the backends for their
/// health so the terminal moves to the standby or shows the outage without waiting for anyone's tap, and
/// opens the feed again on whichever backend answers.
class LiveFeed extends ChangeNotifier {
  LiveFeed(
    this._api, {
    this.retryFirst = const Duration(seconds: 1),
    this.retryMost = const Duration(seconds: 8),
    this.unsupportedRetry = const Duration(minutes: 1),
  });

  final PosApi _api;

  /// The wait before opening a feed that dropped again, doubling up to [retryMost] while it keeps failing.
  final Duration retryFirst;
  final Duration retryMost;

  /// How often a hub that had no feed is asked again: it may have been updated since.
  final Duration unsupportedRetry;

  final _changes = StreamController<LiveChange>.broadcast();
  LiveState _state = LiveState.off;
  bool _started = false;
  bool _disposed = false;
  String? _endpoint; // the backend the feed is open on, or being opened on
  StreamSubscription<String>? _lines;
  Timer? _silence;
  Timer? _retry;
  Duration _staleAfter = const Duration(seconds: 3);
  int _attempt = 0; // answers to an earlier attempt are dropped
  int _failures = 0;
  String _event = '';
  String _data = '';

  /// What the hub said changed, as it says it; `everything` each time the feed connects.
  Stream<LiveChange> get changes => _changes.stream;

  LiveState get state => _state;

  /// The feed is open and the hub is heard from: a screen need not ask to know nothing changed.
  bool get isLive => _state == LiveState.live;

  /// Opens the feed on the backend that answers, and keeps it open from then on: again when it drops, on
  /// another backend when the terminal moves to one.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _api.connection.addListener(_onConnection);
    _connect();
  }

  /// Back in front after a sleep: the connection the device slept on is not trusted, the feed is opened
  /// afresh (and every screen reads once when it is).
  void wake() {
    if (!_started || _disposed) return;
    _attempt++;
    _hangUp();
    _failures = 0;
    unawaited(_connect(fresh: true));
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) _api.connection.removeListener(_onConnection);
    _attempt++;
    _hangUp();
    _retry?.cancel();
    unawaited(_changes.close());
    super.dispose();
  }

  /// The terminal moved to another backend, lost them all, or found one: the feed goes where the calls go.
  void _onConnection() {
    final endpoint = _api.connection.value.endpoint;
    if (endpoint == _endpoint) return;
    _attempt++;
    _hangUp();
    _retry?.cancel();
    _failures = 0;
    _connect(fresh: true);
  }

  /// Opens the feed on the backend that answers now. [fresh]: on a backend not tried yet, so what was found
  /// out about the last one (that it has no feed) no longer holds.
  Future<void> _connect({bool fresh = false}) async {
    _retry?.cancel();
    if (!_started || _disposed) return;
    final endpoint = _api.connection.value.endpoint;
    _endpoint = endpoint;
    if (endpoint == null) return _become(LiveState.off); // found again by the screens' own asking
    if (fresh || _state != LiveState.unsupported) _become(LiveState.connecting);
    final attempt = ++_attempt;
    final http.StreamedResponse response;
    try {
      response = await _api.openLive(endpoint);
    } catch (_) {
      return _lost(attempt);
    }
    if (attempt != _attempt) return _letGo(response);
    if (response.statusCode == 404 || response.statusCode == 405) {
      // A hub from before the feed: nothing is wrong, the screens ask as they always did.
      _letGo(response);
      _become(LiveState.unsupported);
      _retry = Timer(unsupportedRetry, _connect);
      return;
    }
    final type = response.headers['content-type'] ?? '';
    if (response.statusCode != 200 || !type.startsWith('text/event-stream')) {
      _letGo(response);
      return _lost(attempt);
    }
    _event = _data = '';
    _heard(attempt);
    _lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(attempt, line),
          onError: (Object _) => _lost(attempt),
          onDone: () => _lost(attempt),
          cancelOnError: true,
        );
  }

  /// An answer nobody is waiting for any more: closed, so its connection is not left open.
  static void _letGo(http.StreamedResponse response) =>
      unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());

  /// Something arrived: the hub is there. Nothing for [_staleAfter] means it is not.
  void _heard(int attempt) {
    _silence?.cancel();
    _silence = Timer(_staleAfter, () => _lost(attempt));
  }

  void _onLine(int attempt, String line) {
    if (attempt != _attempt) return;
    _heard(attempt);
    if (line.isEmpty) {
      final event = _event, data = _data;
      _event = _data = '';
      if (event.isNotEmpty) _onEvent(event, data);
    } else if (line.startsWith('event:')) {
      _event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      _data = line.substring(5).trim();
    } // a line starting with a colon is the heartbeat: hearing it was the point
  }

  void _onEvent(String event, String data) {
    final Map<String, dynamic> json;
    try {
      json = data.isEmpty ? const {} : jsonDecode(data) as Map<String, dynamic>;
    } on Object {
      return; // a line this build cannot read: the safety poll covers whatever it meant
    }
    switch (event) {
      case 'hello':
        final beat = (json['heartbeat'] as num?)?.toDouble() ?? 1.0;
        _staleAfter = Duration(milliseconds: (beat * 3000).round().clamp(1500, 60000));
        _failures = 0;
        _become(LiveState.live);
        // Whatever changed while nobody was telling: every screen reads once.
        _changes.add(const LiveChange(everything: true));
      case 'changed':
        if (!isLive) return;
        final topics = (json['topics'] as List?)?.cast<String>() ?? const <String>[];
        _changes.add(
          LiveChange(
            orders: {...(json['orders'] as List?)?.cast<String>() ?? const <String>[]},
            everything: json['everything'] == true,
            menu: topics.contains('menu'),
            settings: topics.contains('settings'),
            notes: topics.contains('notes'),
            waitlist: topics.contains('waitlist'),
            reservations: topics.contains('reservations'),
            online: topics.contains('online'),
            floor: topics.contains('floor'),
            prints: topics.contains('prints'),
            calls: topics.contains('calls'),
            texts: topics.contains('texts'),
            shipday: topics.contains('shipday'),
          ),
        );
    }
  }

  /// The feed ended, went silent or could not be opened. The screens ask again from now, the backends are
  /// asked for their health at once (which moves the terminal to another one, or shows the outage), and
  /// the feed is opened again after a wait that grows while it keeps failing.
  void _lost(int attempt) {
    if (attempt != _attempt || _disposed) return;
    _attempt++;
    _hangUp();
    if (_state != LiveState.unsupported) _become(LiveState.connecting);
    final wait = retryFirst * (1 << _failures.clamp(0, 16));
    _failures++;
    _retry?.cancel();
    _retry = Timer(wait > retryMost ? retryMost : wait, _connect);
    unawaited(_probe());
  }

  Future<void> _probe() async {
    try {
      await _api.health();
    } on ApiException {
      // no backend answers: the connection says so now, and the screens' own asking finds one again
    }
  }

  void _hangUp() {
    _silence?.cancel();
    _silence = null;
    final lines = _lines;
    _lines = null;
    if (lines != null) unawaited(lines.cancel());
  }

  void _become(LiveState next) {
    if (_state == next || _disposed) return;
    _state = next;
    notifyListeners();
  }
}

/// Whether a screen should ask anyway, decided on each tick of the timer it used to poll with: on every
/// tick while the feed is not live (as before there was one), and on every [every]th while it is, so a
/// change the feed never told still shows within half a minute.
class SafetyPoll {
  SafetyPoll(this._feed, {this.every = 15});

  final LiveFeed _feed;
  final int every;
  int _quiet = 0;

  /// Call on each tick; true when the screen should read now.
  bool due() {
    if (!_feed.isLive) return true;
    if (++_quiet < every) return false;
    _quiet = 0;
    return true;
  }

  /// The screen just read (told to, or by itself): the count starts over.
  void asked() => _quiet = 0;
}

/// A screen's one way to read: never two reads at a time, and told reads no more often than [gap].
///
/// Told that something changed ([call]), it reads at once after a quiet spell and at most once more per
/// [gap] for whatever it was told meanwhile, so a burst of changes is one read now and one after it. Asked
/// outright ([now]: the screen came up, the operator did something, the timer came round), it reads at once
/// whatever the gap. One read at a time matters once reads are no longer two seconds apart: an answer asked
/// for earlier can no longer land after a later one and put the screen back.
class Paced {
  Paced(this.gap, this.run);

  final Duration gap;
  final Future<void> Function() run;
  Timer? _cooling;
  Future<void>? _running;
  bool _again = false;
  bool _cancelled = false;

  /// Something changed: read, now or when the gap since the last read is over.
  void call() {
    if (_cancelled) return;
    if (_running != null || _cooling != null) {
      _again = true;
      return;
    }
    unawaited(_go());
  }

  /// Read now. While a read is under way, one more follows it with [must]; without, the one under way will do.
  Future<void> now({bool must = true}) {
    if (_cancelled) return Future.value();
    final running = _running;
    if (running != null) {
      if (must) _again = true;
      return running;
    }
    return _go();
  }

  Future<void> _go() {
    _again = false;
    _cooling?.cancel();
    _cooling = Timer(gap, _cooled);
    return _running = _read();
  }

  Future<void> _read() async {
    try {
      await run();
    } finally {
      _running = null;
      if (_again && _cooling == null && !_cancelled) unawaited(_go());
    }
  }

  void _cooled() {
    _cooling = null;
    if (_again && _running == null && !_cancelled) unawaited(_go());
  }

  /// The screen is gone: nothing more is read.
  void cancel() {
    _cancelled = true;
    _cooling?.cancel();
    _cooling = null;
  }
}
