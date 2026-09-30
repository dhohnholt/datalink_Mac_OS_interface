/// The Course → Section → Unit → Test picker behind "Send to your site". A
/// port of `renderUploadPicker` and its change handlers in `app.js`: each choice
/// narrows the next, a selection survives a refresh of the list, and choosing
/// something higher up clears what was chosen below it.
library;

typedef Destination = Map<String, Object?>;

class UploadChoices {
  UploadChoices(List<Destination> destinations) {
    update(destinations);
  }

  List<Destination> _destinations = const [];
  String? _course;
  String? _section;
  String? _unit;
  String? _exam;

  String? get course => _course;
  String? get section => _section;
  String? get unit => _unit;
  String? get exam => _exam;

  List<(String value, String label)> courses = const [];
  List<(String value, String label)> sections = const [];
  List<(String value, String label)> units = const [];
  List<(String value, String label)> tests = const [];

  /// Take a new list (a refresh, or a change of site), keeping each choice that
  /// is still on offer.
  void update(List<Destination> destinations) {
    _destinations = destinations;
    _rebuild();
  }

  void chooseCourse(String value) {
    _course = value;
    _section = null;
    _unit = null;
    _exam = null;
    _rebuild();
  }

  void chooseSection(String value) {
    _section = value;
    _unit = null;
    _exam = null;
    _rebuild();
  }

  void chooseUnit(String value) {
    _unit = value;
    _exam = null;
    _rebuild();
  }

  void chooseTest(String value) {
    _exam = value;
    _rebuild();
  }

  /// The destination the four choices add up to, or null.
  Destination? get selected {
    for (final d in _destinations) {
      if (d['exam_id'] == _exam) return d;
    }
    return null;
  }

  /// `Uploads to … · code …`, or why there is nothing to upload to.
  String get detail {
    final d = selected;
    if (d == null) return 'No test matches this combination.';
    final cap = d['grade_cap'];
    return 'Uploads to ${d['course_title']} · ${d['unit_title']} · ${d['exam_title']} · '
        'code ${d['test_code']}${_truthy(cap) ? ' · grade cap $cap' : ''}';
  }

  /// The unfinalized run already on the site for this test, if any.
  Map<String, Object?>? get draft {
    final run = selected?['draft_run'];
    return run is Map ? run.cast<String, Object?>() : null;
  }

  /// "Update current draft results" text, or null when there is no draft.
  String? get draftDetail {
    final run = draft;
    if (run == null) return null;
    final students = _count(run['student_count']);
    final questions = _count(run['question_count']);
    final created = run['created_at'];
    final uploaded = (created is String && created.isNotEmpty)
        ? (DateTime.tryParse(created)?.toLocal().toString().split('.').first ?? 'an earlier upload')
        : 'an earlier upload';
    return '$students student${students == 1 ? '' : 's'} · $questions questions · '
        'uploaded $uploaded. The corrected scan will replace this draft; '
        'finalized results cannot be replaced.';
  }

  String get buttonLabel => draft != null ? 'Update draft' : 'Upload';

  // ---------------------------------------------------------------- internals

  void _rebuild() {
    courses = _unique(_destinations, 'course_id', 'course_title');
    _course = _keep(_course, courses);

    final inCourse = [for (final d in _destinations) if (d['course_id'] == _course) d];
    final seen = <String>{};
    sections = [
      for (final d in inCourse)
        for (final s in _sectionsOf(d))
          if (seen.add('${s['section_id']}')) ('${s['section_id']}', '${s['section_name']}'),
    ];
    _section = _keep(_section, sections);

    final inSection = [
      for (final d in inCourse)
        if (_sectionsOf(d).any((s) => '${s['section_id']}' == _section)) d,
    ];
    units = _unique(inSection, 'unit_id', 'unit_title');
    _unit = _keep(_unit, units);

    tests = [
      for (final d in inSection)
        if (d['unit_id'] == _unit) ('${d['exam_id']}', '${d['exam_title']} (${d['test_code']})'),
    ];
    _exam = _keep(_exam, tests);
  }

  static List<Map<String, Object?>> _sectionsOf(Destination d) =>
      ((d['sections'] as List?) ?? const []).cast<Map<String, Object?>>();

  static List<(String, String)> _unique(List<Destination> rows, String key, String label) {
    final seen = <String, String>{};
    for (final row in rows) {
      seen.putIfAbsent('${row[key]}', () => '${row[label]}');
    }
    return [for (final e in seen.entries) (e.key, e.value)];
  }

  /// Keep [current] if it is still offered, otherwise the first option.
  static String? _keep(String? current, List<(String, String)> options) {
    if (options.isEmpty) return null;
    if (current != null && options.any((o) => o.$1 == current)) return current;
    return options.first.$1;
  }

  static bool _truthy(Object? value) => value != null && value != 0 && value != '' && value != false;

  static int _count(Object? value) => value is num ? value.toInt() : 0;
}
