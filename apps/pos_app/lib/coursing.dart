/// Coursing as the location sets it (`GET /settings/coursing`): whether dishes are coursed at all, the
/// courses by name in the order the kitchen serves them, and which one a new dish goes to. A manager edits
/// it under Location settings; an order line carries only the course's id, so names can change freely.
library;

class Course {
  const Course(this.id, this.name);
  factory Course.fromJson(Map<String, dynamic> json) =>
      Course(json['id'] as String? ?? '', json['name'] as String? ?? '');

  final String id;
  final String name;

  static const defaults = [
    Course('drinks', 'Drinks'),
    Course('1', 'Appetizers'),
    Course('2', 'Entrees'),
    Course('3', 'Dessert'),
  ];

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class Coursing {
  const Coursing({this.enabled = true, this.defaultCourse = '1', this.courses = Course.defaults});

  /// The hub's answer; an older hub that names no courses means the standard four, on.
  factory Coursing.fromJson(Map<String, dynamic> json) {
    final raw = json['courses'] as List?;
    if (raw == null) return Coursing(enabled: json['enabled'] as bool? ?? true);
    final list = raw.map((c) => Course.fromJson(c as Map<String, dynamic>)).toList();
    final wanted = json['default'] as String?;
    return Coursing(
      enabled: json['enabled'] as bool? ?? true,
      defaultCourse: list.any((c) => c.id == wanted) ? wanted : list.firstOrNull?.id,
      courses: list,
    );
  }

  static const defaults = Coursing();

  final bool enabled;

  /// The course a new dish goes to; null only when there are no courses.
  final String? defaultCourse;
  final List<Course> courses;

  /// The courses a dish can go to now: none while coursing is off.
  List<Course> get active => enabled ? courses : const [];

  /// A course's name, or its id when it is no longer on the list (lines keep the id).
  String nameOf(String id) => courses.where((c) => c.id == id).firstOrNull?.name ?? id;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'default': defaultCourse,
    'courses': [for (final c in courses) c.toJson()],
  };
}

/// An id for a course new on the screen, from its name (`Soup & Salad` becomes `soup-salad`), numbered when
/// that one is taken: the same rule as the hub's, which keeps whatever id it is sent. Ids never change after
/// that, since order lines carry them.
String newCourseId(String name, Set<String> taken) {
  var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.length > 28) base = base.substring(0, 28);
  if (base.isEmpty) base = 'course';
  if (!taken.contains(base)) return base;
  for (var n = 2; ; n++) {
    if (!taken.contains('$base-$n')) return '$base-$n';
  }
}
