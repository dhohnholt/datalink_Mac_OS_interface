// The Analysis screen's derived text, read off app.js. Reports come from the
// real analysis code so the review items have their real shapes.
import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

Map<String, Object?> scan(int number, String role, List<String> responses,
        {String? id, int? score, Map<String, Object?>? confidence, bool pending = false}) =>
    {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': null,
      'responses': responses,
      'scanner_score': score,
      'confidence': confidence ?? <String, Object?>{},
      'pending_review': pending ? 1 : 0,
    };

Map<String, Object?> report(List<Map<String, Object?>> scans, {int questions = 3}) =>
    buildSessionAnalysis(
      {'question_count': questions, 'name': 'T', 'source': 'datalink'},
      scans,
      runId: 'r',
      createdAt: DateTime.utc(2026),
    );

Map<String, Object?> item(int question, num pct, {List<String> flags = const []}) =>
    {'question': question, 'percent_correct': pct, 'flags': flags};

void main() {
  group('item status', () {
    test('cuts at 60 and 70', () {
      expect(itemStatus(0), ItemStatus.priority);
      expect(itemStatus(59.9), ItemStatus.priority);
      expect(itemStatus(60), ItemStatus.developing);
      expect(itemStatus(69.9), ItemStatus.developing);
      expect(itemStatus(70), ItemStatus.secure);
      expect(itemStatus(100), ItemStatus.secure);
      expect(ItemStatus.priority.label, 'Priority');
    });

    test('the focus callout is singular or plural', () {
      expect(priorityCallout([item(1, 90)]), isNull);
      expect(
        priorityCallout([item(1, 90), item(4, 30)]),
        'Focus first on item 4. Fewer than 60% of students answered it correctly.',
      );
      expect(
        priorityCallout([item(2, 10), item(3, 90), item(7, 55)]),
        'Focus first on items 2, 7. Fewer than 60% of students answered each correctly.',
      );
    });

    test('counts every bucket, and flagged separately', () {
      final items = [
        item(1, 10, flags: ['missed_25']),
        item(2, 65),
        item(3, 95),
        item(4, 50),
        item(5, 75, flags: ['missed_25']),
      ];
      final counts = itemCounts(items);
      expect((counts.priority, counts.developing, counts.secure, counts.flagged), (2, 1, 2, 2));
    });

    test('filters by bucket or flag', () {
      final items = [item(1, 10, flags: ['x']), item(2, 65), item(3, 95)];
      List<Object?> questions(ItemFilter f) => [for (final i in filterItems(items, f)) i['question']];
      expect(questions(ItemFilter.all), [1, 2, 3]);
      expect(questions(ItemFilter.priority), [1]);
      expect(questions(ItemFilter.developing), [2]);
      expect(questions(ItemFilter.secure), [3]);
      expect(questions(ItemFilter.flagged), [1]);
    });
  });

  group('reviewProblems wording', () {
    test('a missing id and a double mark, in sheet and question order', () {
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C']),
        scan(3, 'student', ['A', 'AB', 'AC'], id: '900011'),
        scan(2, 'student', ['A', 'B', 'C']),
      ]));
      expect([for (final r in rows) (r.sheet, r.question, r.kind)], [
        (2, null, ReviewKind.studentId),
        (3, 2, ReviewKind.answer),
        (3, 3, ReviewKind.answer),
      ]);
      expect(rows[0].problem, 'No student ID was read');
      expect(rows[0].read, '—');
      expect(rows[1].problem, 'Question 2 has more than one mark');
      expect(rows[1].read, 'MULTIPLE');
      expect(rows[1].key, '3:answer:2:multiple');
      expect(rows[0].key, '2:student_id:0:');
    });

    test('an unsure id is shown as read', () {
      final r = report([
        scan(1, 'key', ['A', 'B', 'C']),
        scan(2, 'student', ['A', 'B', 'C'], id: '90?011'),
      ]);
      expect(reviewProblems(r).single.read, '90?011');
    });

    test('a faint mark is worded differently from a double mark', () {
      const strong = {'mark_strength': 0.3, 'margin': 0.1, 'needs_review': false};
      const weak = {'mark_strength': 0.06, 'margin': 0.1, 'needs_review': false};
      // Five marks, one faint: a lone stray mark, not a light sheet.
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C', 'D', 'E']),
        scan(2, 'student', ['A', 'B', 'C', 'D', 'E'], id: '900011',
            confidence: {'1': strong, '2': strong, '3': strong, '4': strong, '5': weak}),
      ], questions: 5));
      expect(rows.single.kind, ReviewKind.answer);
      expect(
        rows.single.problem,
        "Question 5 is much lighter than this student's other marks — "
        'check it is not a stray mark or an erasure',
      );
      expect(rows.single.read, 'E');
    });

    test('a sheet that is light all through gets one note', () {
      const weak = {'mark_strength': 0.05, 'margin': 0.1, 'needs_review': false};
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C']),
        scan(2, 'student', ['A', 'B', 'C'], id: '900011',
            confidence: {'1': weak, '2': weak, '3': weak}),
      ]));
      expect(rows.single.kind, ReviewKind.note);
      expect(
        rows.single.problem,
        'Every mark on this sheet is light (3 of them). Worth checking the sheet against the screen.',
      );
      expect(rows.single.read, 'faint');
    });

    test('the scanner disagreeing with us names both scores', () {
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C'], score: 3),
        scan(2, 'student', ['A', 'B', 'C'], id: '900011', score: 2),
      ]));
      expect(rows.single.problem,
          'The scanner marked this sheet 2; we make it 3. One of the two read a mark the other did not.');
      expect(rows.single.read, '2 vs 3');
      expect(rows.single.kind, ReviewKind.note);
    });

    test('a stale key in the device is one note about the whole test, listed first', () {
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C'], score: 2),
        scan(2, 'student', ['A', 'B', 'C']),
        scan(3, 'student', ['A', 'B', 'C'], id: '900011', score: 3),
      ]));
      expect(rows.first.wholeTest, isTrue);
      expect(
        rows.first.problem,
        'The scanner marked the answer key 2 out of 3, so the key held in the machine is not the '
        'one you fed. Re-key the scanner, or ignore its scores for this test.',
      );
      expect(rows.first.student, isNull);
    });

    test('a sheet saved before live review finished says so', () {
      final rows = reviewProblems(report([
        scan(1, 'key', ['A', 'B', 'C']),
        scan(2, 'student', ['A', 'B', 'C'], id: '900011', pending: true),
      ]));
      expect(rows.single.problem,
          'This sheet was saved before live review finished. Check its student ID and answers.');
      expect(rows.single.read, 'Review pending');
    });

    test('nothing to review gives no rows', () {
      expect(
        reviewProblems(report([
          scan(1, 'key', ['A', 'B', 'C']),
          scan(2, 'student', ['A', 'B', 'C'], id: '900011'),
        ])),
        isEmpty,
      );
    });
  });
}
