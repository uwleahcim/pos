import 'package:flutter/foundation.dart';

/// Face sign-in as the hub reports it. The hub keeps the faces (as templates, never pictures) and does the
/// recognising; the app only sends frames off its camera and shows what the hub says.
@immutable
class FaceStatus {
  const FaceStatus({
    this.enabled = false,
    this.ready = false,
    this.active = false,
    this.enrolled = 0,
    this.model,
    this.error,
  });

  factory FaceStatus.fromJson(Map<String, dynamic> json) => FaceStatus(
    enabled: json['enabled'] as bool? ?? false,
    ready: json['ready'] as bool? ?? false,
    active: json['active'] as bool? ?? false,
    enrolled: (json['enrolled'] as num?)?.toInt() ?? 0,
    model: json['model'] as String?,
    error: json['error'] as String?,
  );

  /// The location's switch.
  final bool enabled;

  /// The hub has its models loaded.
  final bool ready;

  /// On, ready and someone enrolled: a sign-in screen looks for faces.
  final bool active;
  final int enrolled;
  final String? model;
  final String? error;

  /// One line on how the hub stands, for the manager's screen.
  String get line {
    if (error != null) return 'The hub could not load its face models: $error';
    if (!ready) return 'The hub has no face models yet (update the hub, or wait while they load)';
    return enrolled == 0 ? 'Hub ready, nobody enrolled yet' : 'Hub ready · $enrolled enrolled';
  }
}

/// What the hub says about one frame from the sign-in screen.
@immutable
class FaceFrame {
  const FaceFrame({required this.face, this.reason, this.candidate, this.score, this.signedIn});

  factory FaceFrame.fromJson(Map<String, dynamic> json) => FaceFrame(
    face: json['face'] as bool? ?? false,
    reason: json['reason'] as String?,
    candidate: json['candidate'] as String?,
    score: (json['score'] as num?)?.toDouble(),
    signedIn: json['signed_in'] as Map<String, dynamic>?,
  );

  /// A face was in the frame.
  final bool face;

  /// Why nobody was signed in: off | not_ready | no_face | too_small | unknown | again (one more frame).
  final String? reason;

  /// Who the frame looks like, before the next frame agrees.
  final String? candidate;
  final double? score;

  /// The sign-in, in the shape `POST /signin` answers for a PIN, once two frames agree.
  final Map<String, dynamic>? signedIn;
}

/// A staff member as the back office lists them, with the face enrollment.
@immutable
class StaffEntry {
  const StaffEntry({
    required this.staffId,
    required this.name,
    required this.role,
    this.samples = 0,
    this.updatedAt,
    this.stale = 0,
  });

  factory StaffEntry.fromJson(Map<String, dynamic> json) {
    final face = json['face'] as Map<String, dynamic>? ?? const {};
    final at = (face['updated_at'] as num?)?.toDouble() ?? 0;
    return StaffEntry(
      staffId: json['staff_id'] as String,
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      samples: (face['samples'] as num?)?.toInt() ?? 0,
      updatedAt: at > 0 ? DateTime.fromMillisecondsSinceEpoch((at * 1000).round()) : null,
      stale: (face['stale'] as num?)?.toInt() ?? 0,
    );
  }

  final String staffId;
  final String name;
  final String role;

  /// Views enrolled with the hub's current model.
  final int samples;
  final DateTime? updatedAt;

  /// Views enrolled with another model: the person signs in by PIN until enrolled again.
  final int stale;

  bool get enrolled => samples > 0;
}

/// The hub's answer to one view sent for the enrollment.
@immutable
class EnrollStep {
  const EnrollStep({
    required this.accepted,
    this.reason,
    required this.samples,
    this.wanted = 5,
    this.done = false,
    this.looksLike,
  });

  factory EnrollStep.fromJson(Map<String, dynamic> json) => EnrollStep(
    accepted: json['accepted'] as bool? ?? false,
    reason: json['reason'] as String?,
    samples: (json['samples'] as num?)?.toInt() ?? 0,
    wanted: (json['wanted'] as num?)?.toInt() ?? 5,
    done: json['done'] as bool? ?? false,
    looksLike: json['looks_like'] as String?,
  );

  final bool accepted;

  /// Why the view was not kept: not_ready | no_face | several_faces | too_small | blurry | same_view |
  /// looks_like | full.
  final String? reason;
  final int samples;
  final int wanted;
  final bool done;

  /// The staff member this view already matches (`looks_like`): the wrong person is in front of the camera.
  final String? looksLike;
}
