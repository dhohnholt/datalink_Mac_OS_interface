/// What the Analysis screen derives from a report: item status, the focus
/// callout, and the list of things a human has to decide. Ported from
/// `app.js`, where the wording lived; the wording is user-facing and is kept
/// exactly.
library;

import 'analysis.dart' show reviewKey;

/// The same cut points the omr_final results page uses, so an item that reads
/// as Priority there reads as Priority here.
const double priorityBelow = 60;
const double secureAt = 70;

enum ItemStatus {
  priority('Priority'),
  developing('Developing'),
  secure('Secure');

  const ItemStatus(this.label);

  final String label;
}

ItemStatus itemStatus(num percentCorrect) {
  if (percentCorrect < priorityBelow) return ItemStatus.priority;
  if (percentCorrect < secureAt) return ItemStatus.developing;
  return ItemStatus.secure;
}

/// "Focus first on items 3, 7. Fewer than 60% of students answered each
/// correctly." or null when nothing is a priority.
String? priorityCallout(List<Map<String, Object?>> items) {
  final priority = [
    for (final item in items)
      if (itemStatus(item['percent_correct']! as num) == ItemStatus.priority) item['question'],
  ];
  if (priority.isEmpty) return null;
  final one = priority.length == 1;
  return 'Focus first on item${one ? '' : 's'} ${priority.join(', ')}. '
      'Fewer than ${priorityBelow.round()}% of students answered ${one ? 'it' : 'each'} correctly.';
}

/// How many items fall in each bucket.
({int priority, int developing, int secure, int flagged}) itemCounts(
  List<Map<String, Object?>> items,
) {
  var priority = 0, developing = 0, secure = 0, flagged = 0;
  for (final item in items) {
    switch (itemStatus(item['percent_correct']! as num)) {
      case ItemStatus.priority:
        priority++;
      case ItemStatus.developing:
        developing++;
      case ItemStatus.secure:
        secure++;
    }
    if ((item['flags']! as List).isNotEmpty) flagged++;
  }
  return (priority: priority, developing: developing, secure: secure, flagged: flagged);
}

enum ItemFilter { all, priority, developing, secure, flagged }

List<Map<String, Object?>> filterItems(List<Map<String, Object?>> items, ItemFilter filter) => [
      for (final item in items)
        if (switch (filter) {
          ItemFilter.all => true,
          ItemFilter.flagged => (item['flags']! as List).isNotEmpty,
          ItemFilter.priority => itemStatus(item['percent_correct']! as num) == ItemStatus.priority,
          ItemFilter.developing => itemStatus(item['percent_correct']! as num) == ItemStatus.developing,
          ItemFilter.secure => itemStatus(item['percent_correct']! as num) == ItemStatus.secure,
        })
          item,
    ];

enum ReviewKind { studentId, answer, note }

/// One thing a person has to decide, keyed to the sheet it came from.
class ReviewRow {
  const ReviewRow({
    required this.sheet,
    required this.student,
    required this.key,
    required this.kind,
    required this.problem,
    required this.read,
    this.question,
  });

  /// The sheet number, or 0 for a note about the whole test.
  final int sheet;
  final Map<String, Object?>? student;

  /// Stable name for remembering that it was checked (`analysis.reviewKey`).
  final String key;
  final ReviewKind kind;
  final int? question;
  final String problem;
  final String read;

  /// Whether this row is about the whole test rather than one sheet.
  bool get wholeTest => sheet == 0;
}

/// Turn a report's `review_items` into rows a teacher can act on.
List<ReviewRow> reviewProblems(Map<String, Object?> report) {
  final bySheet = <int, Map<String, Object?>>{
    for (final s in (report['students']! as List).cast<Map<String, Object?>>())
      s['page']! as int: s,
  };
  final rows = <ReviewRow>[];
  for (final item in (report['review_items']! as List).cast<Map<String, Object?>>()) {
    final page = item['page'] as int?;
    final student = page == null ? null : bySheet[page];
    final key = reviewKey(item);
    final field = item['field'];
    final reason = item['reason'];
    if (field == 'student_id') {
      rows.add(ReviewRow(
        sheet: page!,
        student: student,
        key: key,
        kind: ReviewKind.studentId,
        problem: 'No student ID was read',
        read: _orDash(student?['student_id_read']),
      ));
    } else if (field == 'answer') {
      final question = item['question']! as int;
      Map<String, Object?>? answer;
      for (final a in ((student?['answers'] as List?) ?? const []).cast<Map<String, Object?>>()) {
        if (a['question'] == question) answer = a;
      }
      // A faint mark and a double mark are different problems and want
      // different words: one is "which of these did they mean", the other is
      // "is this a mark at all".
      final faint = reason == 'faint';
      rows.add(ReviewRow(
        sheet: page!,
        student: student,
        key: key,
        kind: ReviewKind.answer,
        question: question,
        problem: faint
            ? "Question $question is much lighter than this student's other marks — "
                'check it is not a stray mark or an erasure'
            : 'Question $question has more than one mark',
        read: answer == null ? 'MULTIPLE' : answer['response']! as String,
      ));
    } else if (field == 'session') {
      // Not about one sheet: the scanner is marking against a different key
      // from the one just fed, so every comparison would be wrong.
      rows.add(ReviewRow(
        sheet: 0,
        student: null,
        key: key,
        kind: ReviewKind.note,
        problem: 'The scanner marked the answer key ${item['value']} out of '
            '${item['question_count']}, so the key held in the machine is not the '
            'one you fed. Re-key the scanner, or ignore its scores for this test.',
        read: 'key',
      ));
    } else if (field == 'note') {
      // A test package and a scanned key sheet disagree: the words say which
      // version, question and item, and what each one holds.
      rows.add(ReviewRow(
        sheet: 0,
        student: null,
        key: key,
        kind: ReviewKind.note,
        question: item['question'] as int?,
        problem: '${item['value']}',
        read: 'key',
      ));
    } else if (field == 'version') {
      rows.add(ReviewRow(
        sheet: page!,
        student: student,
        key: key,
        kind: ReviewKind.note,
        problem: 'No version was bubbled on this sheet. It was scored as the only version in the package.',
        read: 'version',
      ));
    } else if (field == 'sheet' && reason == 'score_disagreement') {
      // The machine read the same bubbles and got a different answer.
      rows.add(ReviewRow(
        sheet: page!,
        student: student,
        key: key,
        kind: ReviewKind.note,
        problem: 'The scanner marked this sheet ${item['value']}; we make it '
            '${item['ours']}. One of the two read a mark the other did not.',
        read: '${item['value']} vs ${item['ours']}',
      ));
    } else if (field == 'sheet') {
      // Nothing to correct: the whole sheet read faint, so the point is that
      // every answer on it is worth a glance, not that one is wrong.
      final pending = reason == 'pending_review';
      rows.add(ReviewRow(
        sheet: page!,
        student: student,
        key: key,
        kind: ReviewKind.note,
        problem: pending
            ? 'This sheet was saved before live review finished. Check its student ID and answers.'
            : 'Every mark on this sheet is light (${item['value']} of them). '
                'Worth checking the sheet against the screen.',
        read: pending ? 'Review pending' : 'faint',
      ));
    }
  }
  // Whole-test notes first, then by sheet and question.
  rows.sort((a, b) {
    final bySheetNumber = a.sheet.compareTo(b.sheet);
    return bySheetNumber != 0 ? bySheetNumber : (a.question ?? 0).compareTo(b.question ?? 0);
  });
  return rows;
}

String _orDash(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? '—' : text;
}
