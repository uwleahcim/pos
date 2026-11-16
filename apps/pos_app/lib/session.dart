import 'package:flutter/foundation.dart';

import 'api.dart';

/// Who is signed in on this terminal. The backend decides; the app only remembers the answer.
class Session extends ChangeNotifier {
  Session(this.api);

  final PosApi api;
  Staff? staff;

  /// What the signed-in person set for themselves: text size, contrast, language, and whether the floor map
  /// picks out their own tables. The backend keeps it, so it comes with the sign-in and follows them to the
  /// next device.
  DisplayPrefs prefs = const DisplayPrefs();

  bool get signedIn => staff != null;

  /// Who was signed in when the screen locked itself for standing idle ([lock]); null while it is not
  /// locked. While it is, nobody is signed in, and what that person had open waits under the sign-in pad.
  Staff? lockedFrom;

  bool get locked => lockedFrom != null;

  /// The screen stood idle too long: nobody is signed in until somebody signs in again, by PIN, face or
  /// tag, as on the sign-in screen. Unlike a sign-out it closes nothing: the same person finds the screen
  /// as they left it, and another carries on with the order that was open (docs/idle-lock.md).
  void lock() {
    final was = staff;
    if (was == null) return;
    lockedFrom = was;
    staff = null;
    notifyListeners();
  }

  /// Returns null on success, or the message to show on the PIN pad.
  Future<String?> signInWithPin(String device, String pin) async {
    try {
      applySignIn(await api.signIn(device: device, pin: pin));
      return null;
    } on ApiException catch (err) {
      if (err.status == 401) return 'Wrong PIN';
      if (err.status == 423) return 'Too many tries. Wait a minute.';
      return err.message;
    }
  }

  /// The sign-in as the backend answered it, by PIN or by face: who, and their own display settings.
  void applySignIn(Map<String, dynamic> json) {
    staff = Staff.fromJson(json);
    prefs = DisplayPrefs.fromJson(json['preferences'] as Map<String, dynamic>?);
    lockedFrom = null;
    notifyListeners();
  }

  /// Applies the new settings on this screen at once and sends them to the backend for every other
  /// device. Returns null when saved, or why the backend did not keep them (they stay applied here).
  Future<String?> savePrefs(DisplayPrefs next) async {
    prefs = next;
    notifyListeners();
    final id = staff?.staffId;
    if (id == null) return null;
    try {
      await api.putPreferences(id, next.toJson());
      return null;
    } on ApiException catch (err) {
      return err.message;
    }
  }

  void signOut() {
    staff = null;
    lockedFrom = null;
    prefs = const DisplayPrefs();
    notifyListeners();
  }
}

class Staff {
  const Staff({required this.staffId, required this.name, required this.role, required this.method});

  factory Staff.fromJson(Map<String, dynamic> json) => Staff(
    staffId: json['staff_id'] as String,
    name: json['name'] as String? ?? '',
    role: json['role'] as String? ?? '',
    method: json['method'] as String? ?? 'pin',
  );

  final String staffId;
  final String name;
  final String role;
  final String method;
}

/// A staff member's own display settings, as the backend stores them.
@immutable
class DisplayPrefs {
  const DisplayPrefs({this.textScale = 1.0, this.highContrast = false, this.locale = 'en', this.myTables = false});

  factory DisplayPrefs.fromJson(Map<String, dynamic>? json) => DisplayPrefs(
    textScale: (json?['text_scale'] as num?)?.toDouble() ?? 1.0,
    highContrast: json?['high_contrast'] as bool? ?? false,
    locale: json?['locale'] as String? ?? 'en',
    myTables: json?['my_tables'] as bool? ?? false,
  );

  /// The text sizes offered, as a factor on every font size with its name: the backend accepts 0.8 to 1.6.
  static const textScales = [(0.9, 'Small'), (1.0, 'Normal'), (1.15, 'Large'), (1.3, 'Larger')];

  final double textScale;
  final bool highContrast;
  final String locale;

  /// "Mine" on the floor map: this person's own tables stand out and the other servers' fade.
  final bool myTables;

  DisplayPrefs copyWith({double? textScale, bool? highContrast, String? locale, bool? myTables}) => DisplayPrefs(
    textScale: textScale ?? this.textScale,
    highContrast: highContrast ?? this.highContrast,
    locale: locale ?? this.locale,
    myTables: myTables ?? this.myTables,
  );

  Map<String, dynamic> toJson() => {
    'text_scale': textScale,
    'high_contrast': highContrast,
    'locale': locale,
    'my_tables': myTables,
  };

  @override
  bool operator ==(Object other) =>
      other is DisplayPrefs &&
      other.textScale == textScale &&
      other.highContrast == highContrast &&
      other.locale == locale &&
      other.myTables == myTables;

  @override
  int get hashCode => Object.hash(textScale, highContrast, locale, myTables);
}
