import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/foundation.dart';

/// What a teacher has typed or chosen on the Review pane, and what pressing
/// Apply should send. This is the logic that lived in `app.js`
/// (`fillNameFromRoster`, `chooseStudent`, `applyReviewButton`) and is kept
/// here, free of widgets, so it can be tested.
///
/// Two rules carry most of it:
///
/// * The ID and name boxes arrive prefilled with what was read, so only a box
///   the teacher actually changed counts as a correction.
/// * Typing an ID brings its name with it, from the roster of the class this
///   test was scanned against. It never overwrites a name the teacher typed:
///   only a blank box, or one this filled in itself, is free to be replaced.
class ReviewSheetEdit extends ChangeNotifier {
  ReviewSheetEdit({
    required this.sheet,
    required this.originalId,
    required this.originalName,
    required this.roster,
    this.className = '',
  })  : _id = originalId,
        _name = originalName {
    // The dropdown starts on the student whose name is already saved...
    _chosen = roster.indexWhere((s) => s.name == originalName);
    _nameHidden = roster.isNotEmpty && _chosen >= 0;
    // ...and an ID the reader already got right brings its name in without
    // anyone having to retype the ID to trigger it.
    _fillFromRoster(announce: false);
  }

  final int sheet;

  /// The ID the reader saw, even when it was not sure enough to use it: that is
  /// the likeliest starting point for a correction, not an empty box.
  final String originalId;
  final String originalName;
  final List<RosterStudent> roster;

  /// The class this test was scanned against, for the placeholder.
  final String className;

  String _id;
  String _name;
  bool _nameFromRoster = false;
  bool _nameHidden = false;
  int _chosen = -1;
  String _placeholder = 'Student name';

  String get id => _id;
  String get name => _name;
  bool get hasRoster => roster.isNotEmpty;

  /// Index into [roster] of the chosen student, or -1.
  int get chosenIndex => _chosen;

  /// With a roster the name is a choice from the class; the text box is kept
  /// out of the way until the answer is someone the roster does not have.
  bool get nameBoxHidden => _nameHidden;
  String get namePlaceholder => _placeholder;

  /// Called on every keystroke in the ID box.
  void setId(String value, {bool leaving = false}) {
    _id = value;
    _fillFromRoster(announce: leaving);
    notifyListeners();
  }

  /// Called on every keystroke in the name box.
  void setName(String value) {
    _name = value;
    _nameFromRoster = false;
    notifyListeners();
  }

  /// Picking a student says this sheet is theirs, so it takes their roster ID
  /// with it. Nothing is saved until Apply. -1 means "someone not listed".
  void choose(int index) {
    _chosen = index;
    if (index < 0 || index >= roster.length) {
      _nameHidden = false;
      notifyListeners();
      return;
    }
    final student = roster[index];
    _nameHidden = true;
    _name = student.name;
    _nameFromRoster = true;
    if (!sameStudentId(_id, student.id)) _id = student.id;
    notifyListeners();
  }

  void _fillFromRoster({required bool announce}) {
    // Never overwrite a name the teacher typed.
    final ours = _nameFromRoster;
    if (_name.trim().isNotEmpty && !ours) return;

    final match = roster.indexWhere((s) => sameStudentId(s.id, _id));
    if (match >= 0) {
      _name = roster[match].name;
      _nameFromRoster = true;
      _placeholder = 'Student name';
      if (roster.isNotEmpty) {
        _chosen = match;
        _nameHidden = true;
      }
      return;
    }
    if (roster.isNotEmpty) {
      _chosen = -1;
      _nameHidden = false;
    }
    if (ours) {
      _name = '';
      _nameFromRoster = false;
    }
    _placeholder = announce && className.isNotEmpty && _id.trim().isNotEmpty
        ? 'Not on $className — type the name'
        : 'Student name';
  }

  /// The ID, if it differs from what was read; null when unchanged.
  String? get changedId => _id.trim() == originalId.trim() ? null : _id.trim();

  /// The name, if it differs from what was saved; null when unchanged.
  String? get changedName => _name.trim() == originalName.trim() ? null : _name.trim();

  /// Why this sheet's edits cannot be applied, or null.
  String? get problem {
    final id = changedId;
    if (id != null && id.isNotEmpty && !pyIsDigit(id)) {
      return 'Student ID for sheet $sheet must be digits only';
    }
    return null;
  }
}

/// A fix chosen for one answer on one sheet.
typedef AnswerFix = ({int sheet, int question, String value, String rowKey});

/// The result of reading the whole pane, ready to hand to
/// `Workspace.correct`, or the reason it cannot be.
class ReviewSubmission {
  const ReviewSubmission({required this.corrections, required this.dismiss, this.problem});

  final List<Map<String, Object?>> corrections;
  final List<String> dismiss;
  final String? problem;

  bool get isEmpty => corrections.isEmpty && dismiss.isEmpty;
}

/// Collect what to send. [answers] holds each sheet's current responses as the
/// report states them (`BLANK`/`MULTIPLE` words included).
ReviewSubmission collectReview({
  required List<ReviewSheetEdit> sheets,
  required Set<String> checked,
  required List<AnswerFix> fixes,
  required Map<int, List<String>> answers,
}) {
  final bySheet = <int, Map<String, Object?>>{};
  for (final edit in sheets) {
    final problem = edit.problem;
    if (problem != null) {
      return ReviewSubmission(corrections: const [], dismiss: const [], problem: problem);
    }
    final id = edit.changedId;
    final name = edit.changedName;
    if (id == null && name == null) continue;
    bySheet[edit.sheet] = {
      'number': edit.sheet,
      'student_id': ?id,
      'student_name': ?name,
    };
  }

  // A row the teacher ticked is settled, and so is one whose answer they
  // actually changed: having decided what it should say, they are not asking
  // to be warned about it again.
  final dismiss = <String>{...checked};
  for (final fix in fixes) {
    if (fix.value.isEmpty) continue;
    final entry = bySheet.putIfAbsent(fix.sheet, () => {'number': fix.sheet});
    final responses = (entry['responses'] as List<String>?) ?? List<String>.of(answers[fix.sheet] ?? const []);
    responses[fix.question - 1] = fix.value == 'BLANK' ? '' : fix.value;
    entry['responses'] = [for (final r in responses) r == 'BLANK' ? '' : r];
    dismiss.add(fix.rowKey);
  }
  return ReviewSubmission(corrections: bySheet.values.toList(), dismiss: dismiss.toList());
}
