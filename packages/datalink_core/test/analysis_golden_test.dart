// Replays tools/goldens/make_analysis_goldens.py against the Dart port.
//
// Whole reports are compared as the exact text `json.dumps` produced, so a
// different key order, or 73 where Python wrote 73.0, fails here.
//
//   .venv/bin/python tools/goldens/make_analysis_goldens.py
import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/src/analysis/analysis.dart';
import 'package:datalink_core/src/analysis/csv_export.dart';
import 'package:datalink_core/src/protocol/py_json.dart';
import 'package:datalink_core/src/protocol/py_math.dart';
import 'package:test/test.dart';

late final Map<String, Object?> golden;

List<Object?> list(Object? value) => value! as List<Object?>;
Map<String, Object?> map(Object? value) => (value! as Map).cast<String, Object?>();

final DateTime createdAt = DateTime.utc(2026, 9, 30, 12, 34, 56, 789, 12);

void main() {
  setUpAll(() {
    final bytes = GZipCodec().decode(File('test/goldens/analysis.json.gz').readAsBytesSync());
    golden = map(jsonDecode(utf8.decode(bytes)));
  });

  group('Python numerics', () {
    test('round(x, n) rounds the exact binary value, ties to even', () {
      for (final raw in list(map(golden['math'])['round'])) {
        final e = map(raw);
        final got = pyRound((e['x']! as num).toDouble(), e['digits']! as int);
        final want = (e['result']! as num).toDouble();
        expect(got, want, reason: 'round(${e['x']}, ${e['digits']})');
        expect(got.isNegative, want.isNegative, reason: 'sign of round(${e['x']}, ${e['digits']})');
      }
    });

    test('round(x) with no digits is half to even', () {
      for (final raw in list(map(golden['math'])['round_int'])) {
        final e = map(raw);
        expect(pyRoundInt((e['x']! as num).toDouble()), e['result'], reason: '${e['x']}');
      }
    });

    test('sum() of floats is compensated as in CPython 3.12+', () {
      for (final raw in list(map(golden['math'])['sum'])) {
        final e = map(raw);
        final values = [for (final v in list(e['values'])) (v! as num).toDouble()];
        expect(pySumFloats(values), (e['result']! as num).toDouble(), reason: '$values');
      }
    });

    test('statistics mean, median, variance and stdev, including int vs float', () {
      void check(String label, num got, Map<String, Object?> want, Object data) {
        expect(got, want['v'], reason: '$label of $data');
        expect(got is int ? 'int' : 'float', want['type'], reason: 'type of $label of $data');
      }

      for (final raw in list(map(golden['math'])['stats'])) {
        final e = map(raw);
        final data = [for (final v in list(e['data'])) v! as int];
        check('mean', pyMeanInts(data), map(e['mean']), data);
        check('median', pyMedianInts(data), map(e['median']), data);
        if (data.length > 1) {
          check('variance', pyVarianceInts(data), map(e['variance']), data);
          expect(pyStdevInts(data), map(e['stdev'])['v'], reason: 'stdev of $data');
        }
      }
    });
  });

  group('buildSessionAnalysis', () {
    void runAll(String label, List<Object?> cases) {
      var index = 0;
      for (final raw in cases) {
        final c = map(raw);
        final session = map(c['session']);
        final scans = [for (final s in list(c['scans'])) map(s)];
        final where = '$label #${index++}';

        expect(scanFingerprint(session, scans), c['fingerprint'], reason: '$where fingerprint');

        for (final runRaw in list(c['runs'])) {
          final run = map(runRaw);
          final dismissed = {for (final k in list(run['dismissed'])) k! as String};
          final name = run['exam_name'] as String?;
          if (run.containsKey('json')) {
            final report = buildSessionAnalysis(
              session,
              scans,
              runId: golden['run_id']! as String,
              createdAt: createdAt,
              examName: name,
              dismissed: dismissed,
            );
            expect(pyJsonEncode(report), run['json'], reason: where);
          } else {
            expect(
              () => buildSessionAnalysis(
                session,
                scans,
                runId: golden['run_id']! as String,
                createdAt: createdAt,
                examName: name,
                dismissed: dismissed,
              ),
              throwsA(isA<AnalysisError>().having((e) => e.message, 'message', run['error'])),
              reason: where,
            );
          }
        }
      }
    }

    test('the hand-written scenarios from tests/test_analysis.py', () {
      runAll('fixed', list(golden['fixed']));
    });

    test('160 seeded synthetic sessions, byte for byte', () {
      runAll('random', list(golden['random']));
    });

    test('newRunId makes a version 4 UUID', () {
      final id = newRunId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(newRunId(), isNot(id));
    });
  });

  group('exports', () {
    test('safeExportFilename agrees with Python', () {
      for (final raw in list(golden['filenames'])) {
        final e = map(raw);
        expect(safeExportFilename(e['name']! as String), e['result'], reason: '${e['name']}');
      }
    });

    test('recordsToCsv agrees with Python, byte for byte', () {
      for (final raw in list(golden['csv'])) {
        final e = map(raw);
        final records = [for (final r in list(e['records'])) map(r)];
        expect(
          recordsToCsv(records, e['class_name']! as String, e['fallback']! as int),
          e['result'],
        );
      }
    });
  });
}
