/// The recorded calls of an order (docs/call-recordings.md), as the hub lists them
/// (`GET /orders/{id}/calls`). The phone server records the calls and the hub finds the ones with the
/// order's phone number; the app lists them on the order and plays one for whoever may listen.
library;

import 'package:flutter/foundation.dart';

/// One recorded call with the order's customer.
@immutable
class RecordedCall {
  const RecordedCall({
    required this.id,
    required this.startedMs,
    this.out = false,
    this.seconds,
    this.stereo = false,
    this.extension = '',
    this.opened = false,
  });

  factory RecordedCall.fromJson(Map<String, dynamic> json) => RecordedCall(
    id: json['id'] as String? ?? '',
    startedMs: (json['started_ms'] as num?)?.toInt() ?? 0,
    out: json['direction'] == 'out',
    seconds: (json['seconds'] as num?)?.toInt(),
    stereo: json['stereo'] == true,
    extension: json['extension'] as String? ?? '',
    opened: json['opened'] == true,
  );

  /// The call's id on the phone server.
  final String id;

  /// When the call began.
  final int startedMs;

  /// The restaurant called the customer; otherwise the customer called.
  final bool out;

  /// How long it runs; null where the hub cannot tell before it is played.
  final int? seconds;

  /// The two sides are apart: the customer in the left ear, the restaurant in the right.
  final bool stereo;

  /// The extension that dialed, for a call out.
  final String extension;

  /// The order was opened during this call: the one it was taken on.
  final bool opened;

  /// Who called whom, in a few words.
  String get who => out ? 'We called them' : 'They called';

  @override
  bool operator ==(Object other) =>
      other is RecordedCall &&
      other.id == id &&
      other.startedMs == startedMs &&
      other.out == out &&
      other.seconds == seconds &&
      other.stereo == stereo &&
      other.extension == extension &&
      other.opened == opened;

  @override
  int get hashCode => Object.hash(id, startedMs, out, seconds, stereo, extension, opened);
}

/// What the hub says of an order's calls.
@immutable
class OrderCalls {
  const OrderCalls({this.calls = const [], this.linked = false, this.problem});

  factory OrderCalls.fromJson(Map<String, dynamic> json) => OrderCalls(
    calls: [
      for (final call in json['calls'] as List? ?? const [])
        if (call is Map<String, dynamic>) RecordedCall.fromJson(call),
    ],
    linked: json['linked'] == true,
    problem: json['problem'] as String?,
  );

  /// Nothing: an order with no calls, a hub that reads no recordings, or one older than them.
  static const none = OrderCalls();

  /// Oldest first.
  final List<RecordedCall> calls;

  /// Whether the hub reads a phone server's recordings at all.
  final bool linked;

  /// Why the list may be behind: the phone server did not answer the hub's last look.
  final String? problem;

  bool get isEmpty => calls.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is OrderCalls && other.linked == linked && other.problem == problem && listEquals(other.calls, calls);

  @override
  int get hashCode => Object.hash(linked, problem, Object.hashAll(calls));
}

/// A length of time as a player shows it: "0:07", "1:35", "1:02:05".
String callLength(Duration length) {
  final seconds = length.inSeconds < 0 ? 0 : length.inSeconds;
  final two = (seconds % 60).toString().padLeft(2, '0');
  if (seconds < 3600) return '${seconds ~/ 60}:$two';
  return '${seconds ~/ 3600}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:$two';
}

/// "1 recorded call", "3 recorded calls".
String callsCount(int count) => count == 1 ? '1 recorded call' : '$count recorded calls';
