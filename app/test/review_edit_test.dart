import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/features/analysis/review_edit.dart';
import 'package:flutter_test/flutter_test.dart';

const ada = (id: '900011', name: 'Ada');
const bo = (id: '900012', name: 'Bo');

ReviewSheetEdit edit({
  int sheet = 2,
  String id = '',
  String name = '',
  List<RosterStudent> roster = const [ada, bo],
}) =>
    ReviewSheetEdit(
      sheet: sheet,
      originalId: id,
      originalName: name,
      roster: roster,
      className: 'P4',
    );

void main() {
  group('names follow ids', () {
    test('an id the reader got right brings its name in at once', () {
      final e = edit(id: '900012');
      expect(e.name, 'Bo');
      expect(e.chosenIndex, 1);
      expect(e.nameBoxHidden, isTrue);
      expect(e.changedName, 'Bo', reason: 'the name was blank before, so this is a change');
      expect(e.changedId, isNull, reason: 'the id is what was read');
    });

    test('typing an id fills the name, ignoring leading zeros', () {
      final e = edit()..setId('0900011');
      expect(e.name, 'Ada');
      expect(e.chosenIndex, 0);
      expect(e.changedId, '0900011');
    });

    test('a name the teacher typed is never overwritten', () {
      final e = edit(name: 'Somebody Else')..setId('900011');
      expect(e.name, 'Somebody Else');
      expect(e.changedName, isNull);
    });

    test('a name typed after the fill is also kept', () {
      final e = edit()
        ..setId('900011')
        ..setName('Ada L.')
        ..setId('900012');
      expect(e.name, 'Ada L.');
    });

    test('a name filled from the roster is replaced when the id changes, and cleared when unlisted', () {
      final e = edit()..setId('900011');
      expect(e.name, 'Ada');
      e.setId('900012');
      expect(e.name, 'Bo');
      e.setId('900099');
      expect(e.name, '');
      expect(e.nameBoxHidden, isFalse, reason: 'the box comes back for someone unlisted');
      expect(e.chosenIndex, -1);
    });

    test('the placeholder says so only once the field is left', () {
      final e = edit()..setId('900099');
      expect(e.namePlaceholder, 'Student name', reason: 'half-typed ids are not yet missing ones');
      e.setId('900099', leaving: true);
      expect(e.namePlaceholder, 'Not on P4 — type the name');
    });

    test('without a roster there is nothing to fill and the box stays', () {
      final e = edit(roster: const [])..setId('900011');
      expect(e.name, '');
      expect(e.hasRoster, isFalse);
      expect(e.nameBoxHidden, isFalse);
    });
  });

  group('choosing a student', () {
    test('takes their name and their roster id', () {
      final e = edit(id: '123')..choose(1);
      expect(e.name, 'Bo');
      expect(e.id, '900012');
      expect(e.nameBoxHidden, isTrue);
      expect(e.changedId, '900012');
    });

    test('keeps an id that already matches, zeros and all', () {
      final e = edit(id: '0900012')..choose(1);
      expect(e.id, '0900012');
    });

    test('"not listed" brings the name box back', () {
      final e = edit(id: '900011')..choose(-1);
      expect(e.nameBoxHidden, isFalse);
    });
  });

  group('what counts as a correction', () {
    test('an untouched sheet is no correction', () {
      final e = edit(id: '900011', name: 'Ada');
      expect(e.changedId, isNull);
      expect(e.changedName, isNull);
    });

    test('whitespace alone is not a change', () {
      final e = edit(id: '900011', name: 'Ada')
        ..setId(' 900011 ')
        ..setName(' Ada ');
      expect(e.changedId, isNull);
      expect(e.changedName, isNull);
    });

    test('a non-numeric id is refused with the sheet named', () {
      final e = edit(id: '900011', name: 'Ada')..setId('90x11');
      expect(e.problem, 'Student ID for sheet 2 must be digits only');
    });

    test('clearing an id is allowed (it marks the sheet as having none)', () {
      final e = edit(id: '900011', name: 'Ada')..setId('');
      expect(e.problem, isNull);
      expect(e.changedId, '');
    });
  });

  group('collectReview', () {
    final answers = {
      2: ['A', 'B', 'MULTIPLE', 'BLANK'],
    };

    test('only changed boxes become corrections', () {
      final changed = edit(sheet: 2, id: '900011', name: 'Ada')..setId('900012');
      final unchanged = edit(sheet: 3, id: '900011', name: 'Ada');
      final result = collectReview(
        sheets: [changed, unchanged],
        checked: {},
        fixes: const [],
        answers: answers,
      );
      // The saved name "Ada" is not replaced by the new id's roster name: only
      // a blank box, or one the roster filled itself, is free to change.
      expect(result.corrections, [
        {'number': 2, 'student_id': '900012'},
      ]);
      expect(result.dismiss, isEmpty);
    });

    test('ticked rows are settled on their own', () {
      final result = collectReview(
        sheets: [edit(id: '900011', name: 'Ada')],
        checked: {'2:answer:3:multiple'},
        fixes: const [],
        answers: answers,
      );
      expect(result.corrections, isEmpty);
      expect(result.dismiss, ['2:answer:3:multiple']);
      expect(result.isEmpty, isFalse);
    });

    test('an answer fix rewrites the sheet\'s row and settles itself', () {
      final result = collectReview(
        sheets: [edit(id: '900011', name: 'Ada')],
        checked: {},
        fixes: const [(sheet: 2, question: 3, value: 'C', rowKey: '2:answer:3:multiple')],
        answers: answers,
      );
      expect(result.corrections, [
        {
          'number': 2,
          'responses': ['A', 'B', 'C', ''],
        },
      ]);
      expect(result.dismiss, ['2:answer:3:multiple']);
    });

    test('two fixes on one sheet share one correction, and BLANK becomes empty', () {
      final result = collectReview(
        sheets: const [],
        checked: {},
        fixes: const [
          (sheet: 2, question: 1, value: 'BLANK', rowKey: 'k1'),
          (sheet: 2, question: 3, value: 'E', rowKey: 'k2'),
        ],
        answers: answers,
      );
      expect(result.corrections.single['responses'], ['', 'B', 'E', '']);
      expect(result.dismiss, unorderedEquals(['k1', 'k2']));
    });

    test('"keep as read" (an empty fix) does nothing', () {
      final result = collectReview(
        sheets: const [],
        checked: {},
        fixes: const [(sheet: 2, question: 1, value: '', rowKey: 'k1')],
        answers: answers,
      );
      expect(result.isEmpty, isTrue);
    });

    test('an id fix and an answer fix on the same sheet are one correction', () {
      final id = edit(sheet: 2, id: '', name: '')..setId('900012');
      final result = collectReview(
        sheets: [id],
        checked: {},
        fixes: const [(sheet: 2, question: 2, value: 'D', rowKey: 'k')],
        answers: answers,
      );
      expect(result.corrections, hasLength(1));
      expect(result.corrections.single['student_id'], '900012');
      expect(result.corrections.single['responses'], ['A', 'D', 'MULTIPLE', '']);
    });

    test('a bad id stops everything with its reason', () {
      final bad = edit(sheet: 4, id: '1', name: 'x')..setId('abc');
      final result = collectReview(
        sheets: [bad],
        checked: {'k'},
        fixes: const [],
        answers: answers,
      );
      expect(result.problem, 'Student ID for sheet 4 must be digits only');
      expect(result.corrections, isEmpty);
    });
  });
}
