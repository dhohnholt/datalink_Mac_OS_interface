// These rules lived in app.js and had no tests there. Each case below is read
// straight off that code; the wording asserted is what a teacher sees.
import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

RosterWalk walk(List<(String, String)> people, [int index = 0]) =>
    RosterWalk([for (final (id, name) in people) (id: id, name: name)], index);

Map<String, Object?> review({
  String role = 'student',
  int number = 2,
  String? scannerId,
  bool idRequired = true,
  List<Map<String, Object?>> ambiguities = const [],
}) =>
    {
      'id': number,
      'number': number,
      'role': role,
      'scanner_id': scannerId,
      'student_id_required': idRequired,
      'ambiguities': ambiguities,
    };

const ambiguity = {'question': 3, 'value': 'AC', 'options': ['A', 'C']};

void main() {
  group('sameStudentId', () {
    test('ignores leading zeros on either side', () {
      expect(sameStudentId('0900011', '900011'), isTrue);
      expect(sameStudentId('900011', '00900011'), isTrue);
      expect(sameStudentId(' 900011 ', '900011'), isTrue);
    });

    test('but not different students', () {
      expect(sameStudentId('900011', '900012'), isFalse);
      expect(sameStudentId('9000110', '900011'), isFalse);
    });

    test('an empty or missing id never matches anything, even another empty one', () {
      expect(sameStudentId('', ''), isFalse);
      expect(sameStudentId(null, null), isFalse);
      expect(sameStudentId('900011', null), isFalse);
    });

    test('zero is an id of zero, not nothing', () {
      expect(sameStudentId('0', '0'), isTrue);
      expect(sameStudentId('000', '0'), isTrue);
    });
  });

  group('parseRoster', () {
    test('reads id, name lines and ignores blank ones and Windows line ends', () {
      final students = parseRoster('900011, Ada Lovelace\r\n\r\n  900012 ,Bo  \n');
      expect(students, [(id: '900011', name: 'Ada Lovelace'), (id: '900012', name: 'Bo')]);
    });

    test('a comma in the name stays in the name', () {
      expect(parseRoster('900011, Lovelace, Ada').single.name, 'Lovelace, Ada');
    });

    test('names the first bad line', () {
      for (final bad in ['abc, Ada', '900011', '900011,', ', Ada']) {
        expect(
          () => parseRoster('900012, Ok\n$bad\n900013, Also'),
          throwsA(
            isA<DataLinkError>().having(
              (e) => e.message,
              'message',
              'Fix roster line: ${bad.trim()}',
            ),
          ),
          reason: bad,
        );
      }
    });

    test('an empty roster is allowed', () {
      expect(parseRoster(''), isEmpty);
      expect(parseRoster('\n  \n'), isEmpty);
    });
  });

  group('RosterWalk', () {
    test('steps through the class, and stops at the end', () {
      final w = walk([('1', 'Ada'), ('2', 'Bo')]);
      expect(w.current!.name, 'Ada');
      w.advance();
      expect(w.current!.name, 'Bo');
      w.advance();
      expect(w.current, isNull);
      w.advance();
      expect(w.index, 2, reason: 'never past the end');
      w.reset();
      expect(w.current!.name, 'Ada');
    });

    test('says where it has got to', () {
      expect(
        walk([('1', 'Ada'), ('2', 'Bo'), ('3', 'Cy')], 1).summary('P4'),
        'P4 · 3 students · 1 handled · 2 remaining',
      );
      expect(walk(const []).summary('P4'), 'No saved roster. Student IDs will be entered manually.');
      expect(
        walk([('1', 'Ada')], 1).summary('P4'),
        'P4 · 1 students · 1 handled · 0 remaining',
      );
    });

    test('finds a student by id ignoring zeros', () {
      final w = walk([('900011', 'Ada'), ('900012', 'Bo')]);
      expect(w.indexForId('0900012'), 1);
      expect(w.indexForId('1'), -1);
    });
  });

  group('planReview', () {
    final roster = walk([('900011', 'Ada'), ('900012', 'Bo')]);

    test('saves by itself when the scanner read an id that is on the roster', () {
      final plan = planReview(
        review: review(scannerId: '0900012'),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.autoSave, isTrue);
      expect(plan.matchIndex, 1);
      expect(plan.studentName, 'Bo');
      expect(plan.idPrefill, '0900012', reason: 'filed under the id as bubbled');
    });

    test('saves by itself with no roster at all, unnamed', () {
      final plan = planReview(
        review: review(scannerId: '900099'),
        roster: walk(const []),
        matching: StudentMatching.id,
        className: '',
      );
      expect(plan.autoSave, isTrue);
      expect(plan.studentName, '');
      expect(plan.matchIndex, -1);
    });

    test('asks when the id is not on the roster', () {
      final plan = planReview(
        review: review(scannerId: '900099'),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.title, 'Enter the student ID');
      expect(
        plan.intro,
        'ID 900099 is not in P4. Check the sheet or save it as an unlisted student.',
      );
      expect(plan.idPrefill, '900099');
    });

    test('asks when the scanner read no id, and offers the next student in order', () {
      final plan = planReview(
        review: review(),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.title, 'Confirm Ada');
      expect(
        plan.intro,
        'The student sheet 1 was captured. Enter the ID bubbled on the sheet '
        'before scanning the next student.',
      );
      expect(plan.idPrefill, '900011');
      expect(plan.namePrefill, 'Ada');
    });

    test('never auto-saves a sheet with a doubtful mark, even with a good id', () {
      final plan = planReview(
        review: review(scannerId: '900011', ambiguities: [ambiguity]),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.title, 'Confirm Ada');
      expect(
        plan.intro,
        'The scanner found more than one mark on the student sheet 1. '
        'Please resolve each item before continuing.',
      );
    });

    test('a doubtful mark with nobody to confirm says "Check the scan"', () {
      final plan = planReview(
        review: review(scannerId: '900099', ambiguities: [ambiguity]),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.title, 'Check the scan');
    });

    test('roster mode ignores the bubbled id and goes in order', () {
      final plan = planReview(
        review: review(scannerId: '900012'),
        roster: walk([('900011', 'Ada'), ('900012', 'Bo')], 1),
        matching: StudentMatching.roster,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.title, 'Confirm Bo');
      expect(plan.idPrefill, '900012');
    });

    test('manual mode always asks and offers nobody', () {
      final plan = planReview(
        review: review(scannerId: '900011'),
        roster: roster,
        matching: StudentMatching.manual,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.title, 'Enter the student ID');
      expect(plan.idPrefill, '');
      expect(plan.namePrefill, '');
    });

    test('an answer key with a doubtful mark needs no student id', () {
      final plan = planReview(
        review: review(role: 'key', number: 1, idRequired: false, ambiguities: [ambiguity]),
        roster: roster,
        matching: StudentMatching.id,
        className: 'P4',
      );
      expect(plan.autoSave, isFalse);
      expect(plan.needsStudentId, isFalse);
      expect(plan.title, 'Check the scan');
      expect(plan.intro, startsWith('The scanner found more than one mark on the answer key.'));
    });

    test('parses the setting, defaulting to by-id', () {
      expect(StudentMatching.parse(null), StudentMatching.id);
      expect(StudentMatching.parse(''), StudentMatching.id);
      expect(StudentMatching.parse('roster'), StudentMatching.roster);
      expect(StudentMatching.parse('manual'), StudentMatching.manual);
    });
  });
}
