import 'package:flutter/foundation.dart';

import 'api.dart';

/// Who is signed in on this terminal. The backend decides; the app only remembers the answer.
class Session extends ChangeNotifier {
  Session(this.api);

  final PosApi api;
  Staff? staff;

  bool get signedIn => staff != null;

  /// Returns null on success, or the message to show on the PIN pad.
  Future<String?> signInWithPin(String device, String pin) async {
    try {
      final json = await api.signIn(device: device, pin: pin);
      staff = Staff.fromJson(json);
      notifyListeners();
      return null;
    } on ApiException catch (err) {
      if (err.status == 401) return 'Wrong PIN';
      if (err.status == 423) return 'Too many tries. Wait a minute.';
      return err.message;
    }
  }

  void signOut() {
    staff = null;
    notifyListeners();
  }
}

class Staff {
  const Staff({required this.staffId, required this.name, required this.role, required this.method});

  factory Staff.fromJson(Map<String, dynamic> json) => Staff(
    staffId: json['staff_id'] as String,
    name: json['name'] as String,
    role: json['role'] as String? ?? '',
    method: json['method'] as String? ?? 'pin',
  );

  final String staffId;
  final String name;
  final String role;
  final String method;
}
