import 'package:datalink_scanner/features/analysis/upload_choices.dart';
import 'package:flutter_test/flutter_test.dart';

Destination dest(
  String exam, {
  String course = 'c1',
  String unit = 'u1',
  List<String> sections = const ['s1'],
  String? gradeCap,
  Map<String, Object?>? draft,
}) =>
    {
      'exam_id': exam,
      'exam_title': 'Exam $exam',
      'test_code': 'T-$exam',
      'unit_id': unit,
      'unit_title': 'Unit $unit',
      'course_id': course,
      'course_title': 'Course $course',
      'sections': [for (final s in sections) {'section_id': s, 'section_name': 'Section $s'}],
      'grade_cap': ?gradeCap,
      'draft_run': ?draft,
    };

void main() {
  test('starts on the first of everything', () {
    final c = UploadChoices([dest('a'), dest('b', unit: 'u2')]);
    expect((c.course, c.section, c.unit, c.exam), ('c1', 's1', 'u1', 'a'));
    expect(c.courses, [('c1', 'Course c1')]);
    expect(c.units.map((u) => u.$1), ['u1', 'u2']);
    expect(c.tests, [('a', 'Exam a (T-a)')]);
  });

  test('each choice narrows the next', () {
    final c = UploadChoices([
      dest('a', course: 'c1', unit: 'u1', sections: ['s1']),
      dest('b', course: 'c2', unit: 'u9', sections: ['s2', 's3']),
      dest('c', course: 'c2', unit: 'u8', sections: ['s3']),
    ]);
    c.chooseCourse('c2');
    expect(c.sections.map((s) => s.$1), ['s2', 's3']);
    expect(c.section, 's2');
    expect(c.units.map((u) => u.$1), ['u9'], reason: 'only what is in section s2');
    c.chooseSection('s3');
    expect(c.units.map((u) => u.$1), ['u9', 'u8']);
    c.chooseUnit('u8');
    expect(c.tests, [('c', 'Exam c (T-c)')]);
    expect(c.selected!['exam_id'], 'c');
  });

  test('choosing higher up clears what was chosen below', () {
    final c = UploadChoices([
      dest('a', unit: 'u1'),
      dest('b', unit: 'u2'),
      dest('x', course: 'c2', unit: 'u7', sections: ['s9']),
    ]);
    c.chooseUnit('u2');
    c.chooseTest('b');
    expect(c.exam, 'b');
    c.chooseCourse('c2');
    expect((c.section, c.unit, c.exam), ('s9', 'u7', 'x'));
  });

  test('a refreshed list keeps choices that are still on offer', () {
    final c = UploadChoices([dest('a'), dest('b', unit: 'u2')])
      ..chooseUnit('u2')
      ..chooseTest('b');
    c.update([dest('a'), dest('b', unit: 'u2'), dest('z', unit: 'u2')]);
    expect((c.unit, c.exam), ('u2', 'b'));
    c.update([dest('a')]);
    expect((c.unit, c.exam), ('u1', 'a'), reason: 'what was chosen is gone, so the first');
  });

  test('an empty list means nothing to choose and nothing selected', () {
    final c = UploadChoices(const []);
    expect(c.courses, isEmpty);
    expect(c.selected, isNull);
    expect(c.detail, 'No test matches this combination.');
    expect(c.buttonLabel, 'Upload');
  });

  test('says where it will upload, with the grade cap when there is one', () {
    final c = UploadChoices([dest('a', gradeCap: '70')]);
    expect(c.detail, 'Uploads to Course c1 · Unit u1 · Exam a · code T-a · grade cap 70');
    expect(UploadChoices([dest('a')]).detail, 'Uploads to Course c1 · Unit u1 · Exam a · code T-a');
  });

  test('a draft run switches the action to updating it', () {
    final c = UploadChoices([
      dest('a', draft: {
        'run_id': 'old',
        'created_at': '2026-09-16T18:00:00+00:00',
        'student_count': 1,
        'question_count': 30,
      }),
    ]);
    expect(c.buttonLabel, 'Update draft');
    expect(c.draft!['run_id'], 'old');
    expect(c.draftDetail, startsWith('1 student · 30 questions · uploaded 2026-09-'));
    expect(c.draftDetail, endsWith('The corrected scan will replace this draft; finalized results cannot be replaced.'));
  });

  test('a draft with no details still reads sensibly', () {
    final c = UploadChoices([dest('a', draft: {'run_id': 'old'})]);
    expect(
      c.draftDetail,
      '0 students · 0 questions · uploaded an earlier upload. The corrected scan will replace this draft; '
      'finalized results cannot be replaced.',
    );
  });

  test('a test with the same title in two units is offered once per unit', () {
    final c = UploadChoices([dest('a'), dest('b', unit: 'u2')]);
    expect(c.tests, hasLength(1));
    c.chooseUnit('u2');
    expect(c.tests, [('b', 'Exam b (T-b)')]);
  });
}
