/// Desk phones linked to screens: a call taken on a desk phone opens the caller's order on the linked screen,
/// as if the screen had taken the call itself. The hub keeps the links (`GET/PUT /settings/desk_phones`; a
/// manager sets them under Location settings) and the answers (`GET /phones/answered?device=`), which
/// `DeskPhoneWatcher` collects for this device.
library;

import 'package:flutter/foundation.dart';

import 'phone.dart';

/// One desk phone (its extension on the PBX) and the screen it is linked to (the device name that screen
/// shows under Settings).
@immutable
class DeskPhoneLink {
  const DeskPhoneLink({required this.extension, required this.device});

  factory DeskPhoneLink.fromJson(Map<String, dynamic> json) =>
      DeskPhoneLink(extension: json['extension'] as String? ?? '', device: json['device'] as String? ?? '');

  final String extension;
  final String device;

  Map<String, dynamic> toJson() => {'extension': extension, 'device': device};

  @override
  bool operator ==(Object other) => other is DeskPhoneLink && other.extension == extension && other.device == device;

  @override
  int get hashCode => Object.hash(extension, device);
}

/// The links as the hub keeps them, each extension once.
class DeskPhoneLinks {
  const DeskPhoneLinks([this.links = const []]);

  factory DeskPhoneLinks.fromJson(Map<String, dynamic> json) => DeskPhoneLinks([
    for (final link in json['links'] as List? ?? const []) DeskPhoneLink.fromJson(link as Map<String, dynamic>),
  ]);

  final List<DeskPhoneLink> links;

  Map<String, dynamic> toJson() => {
    'links': [for (final link in links) link.toJson()],
  };
}

/// A call answered on a desk phone linked to this device, as the hub lists it.
@immutable
class DeskPhoneCall {
  const DeskPhoneCall({required this.id, required this.extension, required this.answeredAt, this.number, this.name});

  /// The hub says how long ago the phone was picked up (`age_ms`, on its own clock), so the time here is this
  /// device's [now] less that age: a device whose clock drifts still judges the call's age right.
  factory DeskPhoneCall.fromJson(Map<String, dynamic> json, {required DateTime now}) => DeskPhoneCall(
    id: json['id'] as String? ?? '',
    extension: json['extension'] as String? ?? '',
    answeredAt: now.subtract(Duration(milliseconds: (json['age_ms'] as num?)?.toInt() ?? 0)),
    number: json['number'] as String?,
    name: json['name'] as String?,
  );

  /// The same on every hub: the call's id on the PBX and the extension, so a call seen through two hubs is one.
  final String id;
  final String extension;
  final DateTime answeredAt;
  final String? number;
  final String? name;

  /// The caller as the order form and the hub's lookup want them.
  Caller get caller => Caller(number: number, name: name);
}

/// The hub's answer to `GET /phones/answered`: whether any desk phone is linked to the device at all, the
/// calls answered on its phones in the last two minutes, oldest first, and the hub's cursor, which the next
/// request brings back as `after` so the hub holds it until there is a newer call.
class AnsweredCalls {
  const AnsweredCalls({required this.linked, required this.calls, this.cursor = 0});

  final bool linked;
  final List<DeskPhoneCall> calls;
  final int cursor;
}
