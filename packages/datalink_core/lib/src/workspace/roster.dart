/// Roster rules that the old page enforced in JavaScript (`app.js`): matching a
/// bubbled ID to a roster, parsing a pasted roster, walking a class in order,
/// and deciding what the review dialog says. Ported so they can be tested.
library;

import '../protocol/errors.dart';
import '../protocol/python_compat.dart';

/// Whether two student IDs are the same student.
///
/// The scanner writes the ID field as it was bubbled, which can carry leading
/// zeros a roster typed by hand does not. Comparing the two as plain strings
/// quietly failed to match, and the sheet fell back to roster order.
bool sameStudentId(Object? left, Object? right) {
  String tidy(Object? value) {
    final text = pyStrip(value == null ? '' : value.toString());
    // JS: replace(/^0+(?=\d)/, '') - strip leading zeros but keep the last digit.
    return text.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
  }

  final a = tidy(left);
  return a.isNotEmpty && a == tidy(right);
}

/// One student on a roster.
typedef RosterStudent = ({String id, String name});

/// Parse a roster typed or pasted as `id, name` lines.
///
/// Throws a [DataLinkError] `Fix roster line: <line>` for the first line that
/// has no numeric ID or no name.
List<RosterStudent> parseRoster(String text) {
  final students = <RosterStudent>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = pyStrip(raw);
    if (line.isEmpty) continue;
    final comma = line.indexOf(',');
    final id = pyStrip(comma >= 0 ? line.substring(0, comma) : '');
    final name = pyStrip(comma >= 0 ? line.substring(comma + 1) : '');
    if (!RegExp(r'^[0-9]+$').hasMatch(id) || name.isEmpty) {
      throw DataLinkError('Fix roster line: $line');
    }
    students.add((id: id, name: name));
  }
  return students;
}

/// How `studentMatching` is set.
enum StudentMatching {
  /// Any order: the bubbled ID decides who a sheet belongs to.
  id,

  /// Roster order; the ID area is ignored.
  roster,

  /// Every sheet asks.
  manual;

  static StudentMatching parse(String? value) => switch (value) {
        'roster' => StudentMatching.roster,
        'manual' => StudentMatching.manual,
        _ => StudentMatching.id,
      };
}

/// Where scanning a class has got to. Kept per class for the life of the app.
class RosterWalk {
  RosterWalk(this.students, [this.index = 0]);

  final List<RosterStudent> students;
  int index;

  RosterStudent? get current => index >= 0 && index < students.length ? students[index] : null;

  int indexForId(Object? id) => students.indexWhere((s) => sameStudentId(s.id, id));

  void advance() {
    if (index < students.length) index++;
  }

  void reset() => index = 0;

  /// "P4 · 30 students · 4 handled · 26 remaining".
  String summary(String className) {
    if (students.isEmpty) return 'No saved roster. Student IDs will be entered manually.';
    final handled = index < students.length ? index : students.length;
    final remaining = students.length - index;
    return '$className · ${students.length} students · $handled handled · '
        '${remaining < 0 ? 0 : remaining} remaining';
  }
}

/// What to do with a sheet the reader put up for review.
class ReviewPlan {
  const ReviewPlan({
    required this.autoSave,
    required this.title,
    required this.intro,
    required this.needsStudentId,
    required this.idPrefill,
    required this.namePrefill,
    required this.matchIndex,
    required this.studentName,
  });

  /// Save without asking: the scanner read an ID, nothing is doubtful, and the
  /// student is on the roster (or there is no roster).
  final bool autoSave;
  final String title;
  final String intro;
  final bool needsStudentId;
  final String idPrefill;
  final String namePrefill;

  /// Index of the roster student this sheet matched, or -1.
  final int matchIndex;

  /// For an auto-save: the name to file under (empty when unlisted).
  final String studentName;
}

/// Port of `renderReview` / `saveDetectedStudent` decisions in `app.js`.
ReviewPlan planReview({
  required Map<String, Object?> review,
  required RosterWalk roster,
  required StudentMatching matching,
  required String className,
}) {
  final scannerId = review['scanner_id'] as String?;
  final hasScannerId = scannerId != null && scannerId.isNotEmpty;
  final useScannerId = matching == StudentMatching.id && hasScannerId;
  final detected = useScannerId ? roster.indexForId(scannerId) : -1;
  final ambiguities = (review['ambiguities'] as List?) ?? const [];
  final idRequired = review['student_id_required'] == true;

  final canAutoSave = matching == StudentMatching.id &&
      idRequired &&
      hasScannerId &&
      ambiguities.isEmpty &&
      (roster.students.isEmpty || detected >= 0);
  if (canAutoSave) {
    final match = detected >= 0 ? roster.students[detected] : null;
    return ReviewPlan(
      autoSave: true,
      title: '',
      intro: '',
      needsStudentId: true,
      idPrefill: scannerId,
      namePrefill: match?.name ?? '',
      matchIndex: detected,
      studentName: match?.name ?? '',
    );
  }

  final number = review['number']! as int;
  final label = review['role'] == 'key' ? 'answer key' : 'student sheet ${number - 1}';
  final matchIndex = useScannerId ? roster.indexForId(scannerId) : roster.index;
  final RosterStudent? next;
  if (!idRequired || matching == StudentMatching.manual) {
    next = null;
  } else if (useScannerId) {
    next = matchIndex >= 0 && matchIndex < roster.students.length
        ? roster.students[matchIndex]
        : null;
  } else {
    next = roster.current;
  }
  final hasAmbiguities = ambiguities.isNotEmpty;

  final title = next != null
      ? 'Confirm ${next.name}'
      : hasAmbiguities
          ? 'Check the scan'
          : 'Enter the student ID';
  final String intro;
  if (hasAmbiguities) {
    intro = 'The scanner found more than one mark on the $label. '
        'Please resolve each item before continuing.';
  } else if (useScannerId) {
    intro = roster.students.isNotEmpty && matchIndex < 0
        ? 'ID $scannerId is not in $className. Check the sheet or save it as an unlisted student.'
        : 'The scanner read ID $scannerId. Confirm the student before continuing.';
  } else {
    intro = 'The $label was captured. Enter the ID bubbled on the sheet '
        'before scanning the next student.';
  }
  return ReviewPlan(
    autoSave: false,
    title: title,
    intro: intro,
    needsStudentId: idRequired,
    idPrefill: (useScannerId ? scannerId : null) ?? next?.id ?? '',
    namePrefill: next?.name ?? '',
    matchIndex: matchIndex,
    studentName: '',
  );
}
