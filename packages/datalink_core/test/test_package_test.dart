import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

/// Replays tools/goldens/make_package_goldens.py, which scored seeded batches
/// with omr_final's version_package.py, through the Dart port.
///
///   .venv/bin/python tools/goldens/make_package_goldens.py
void main() {
  test('matching A-O answers preserve skipped rows across versions', () {
    final package = TestPackage.parse(
      'Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer\n'
      'mc,Media,,40,A,40,B\n'
      'v1,Vocabulary,,51,G,60,O\n'
      'v2,Vocabulary,,60,N,51,M\n',
    );
    expect(package.numbers['1'], {'mc': 40, 'v1': 51, 'v2': 60});
    expect(package.numbers['2'], {'mc': 40, 'v1': 60, 'v2': 51});
    expect(package.answers['1']!['v1'], 'G');
    expect(package.answers['2']!['v1'], 'O');
    expect(() => TestPackage.parse(
      'Stable item ID,Version 1,Version 1 answer\nx,40,G\n',
    ), throwsA(isA<TestPackageException>()));
    expect(() => TestPackage.parse(
      'Stable item ID,Version 1,Version 1 answer\nx,51,P\n',
    ), throwsA(isA<TestPackageException>()));
  });

  final cases = (jsonDecode(File('test/goldens/package.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  PackageSheet sheetOf(Map<String, Object?> s) => PackageSheet(
        page: s['page']! as int,
        version: s['version'] as String?,
        studentId: s['student_id'] as String?,
        responses: {
          for (final e in (s['responses']! as Map).entries) int.parse('${e.key}'): '${e.value}',
        },
      );

  test('scores, items, standards and reliability match the Python version', () {
    for (final (index, c) in cases.indexed) {
      final package = TestPackage.parse(c['csv']! as String);
      final sheets = (c['sheets']! as List).cast<Map<String, Object?>>();
      final report = buildPackageAnalysis(
        package: package,
        keySheets: [for (final s in sheets) if (s['is_key'] == true) sheetOf(s)],
        sheets: [for (final s in sheets) if (s['is_key'] != true) sheetOf(s)],
        examName: 'T',
        sourceFile: 't.pdf',
        runId: 'r',
        createdAt: '2026-10-31T00:00:00+00:00',
      );
      final reason = 'case $index';
      expect(
        {for (final s in (report['students']! as List).cast<Map<String, Object?>>()) '${s['page']}': (s['score']! as Map)['correct']},
        c['scores'],
        reason: reason,
      );
      final items = {
        for (final i in (report['items']! as List).cast<Map<String, Object?>>())
          i['item']: {
            'pct': i['percent_correct'],
            'by_version': i['pct_correct_by_version'],
            'pb': i['point_biserial'],
            'disc': i['upper_lower_discrimination'],
          },
      };
      final expected = (c['items']! as Map).cast<String, Object?>();
      for (final entry in expected.entries) {
        final want = (entry.value! as Map).cast<String, Object?>();
        final got = items[entry.key]!;
        expect(got['pct'], want['pct'], reason: '$reason ${entry.key} pct');
        expect(got['by_version'], want['by_version'], reason: '$reason ${entry.key} by version');
        expect(got['disc'], want['disc'], reason: '$reason ${entry.key} discrimination');
        if (want['pb'] == null) {
          expect(got['pb'], isNull, reason: '$reason ${entry.key} point biserial');
        } else {
          expect(got['pb'] as double, closeTo((want['pb']! as num).toDouble(), 0.0011), reason: '$reason ${entry.key} pb');
        }
      }
      expect(report['standards'], c['standards'], reason: '$reason standards');
      expect(report['sections'], c['sections'], reason: '$reason sections');
      final kr20 = (report['summary']! as Map)['kr20'];
      if (c['kr20'] == null) {
        expect(kr20, isNull, reason: '$reason kr20');
      } else {
        expect(kr20 as double, closeTo((c['kr20']! as num).toDouble(), 0.0011), reason: '$reason kr20');
      }
      expect((report['key_mismatches']! as List).length, c['mismatches'], reason: '$reason mismatches');
    }
  });

  group('reading a package', () {
    const header = 'Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer\n';

    test('versions, answers, multiple-answer keys and groups', () {
      final package = TestPackage.parse('${header}a,P,S.1,1,A,2,C\nb,P,S.1,2,B,3,A\nc,Q,S.2,3,"C, A",1,BD\n');
      expect(package.versions, ['1', '2']);
      expect(package.numbers['2']!['c'], 1);
      expect(package.answers['1']!['c'], 'AC');
      expect(package.standards['c'], 'S.2');
      expect(package.questionCount, 3);
      expect(TestPackage.fromJson(jsonDecode(jsonEncode(package.toJson())) as Map<String, Object?>).answers,
          package.answers);
    });

    test('a map without answers is accepted', () {
      final package = TestPackage.parse('Version 1,Version 2,Stable item ID\n1,2,a\n2,1,b\n');
      expect(package.hasAnswers, isFalse);
    });

    test('problems are named by line', () {
      expect(
        () => TestPackage.parse('${header}a,P,S,1,A,1,A\na,P,S,2,B,2,B\nb,P,S,1,A,9,A\nc,P,S,4,F,4,A\n'),
        throwsA(isA<TestPackageException>().having(
          (e) => e.message,
          'message',
          allOf(contains('line 3: item a appears twice'), contains('line 4: Version 1 question 1 is already item a'),
              contains("line 5: Version 1 answer must be letters A-E, not 'F'")),
        )),
      );
    });

    test('the prompt asks for exactly what the reader takes', () {
      final example = [
        for (final line in testPackagePrompt.split('\n'))
          if (line.startsWith('presidency-') || line.startsWith('cba-')) line,
      ];
      expect(TestPackage.parse('$header${example.join('\n')}\n').items, hasLength(3));
    });
  });
}
