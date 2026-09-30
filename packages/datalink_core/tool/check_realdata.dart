// Hash what the Dart store and analysis make of a real database, for
// comparison with tools/realdata/check_realdata.py on a copy of the same file.
//
//   dart run tool/check_realdata.dart <copy-of-library.sqlite3>
//
// Prints `<kind> <id> <sha256>` lines and nothing else: no student data.
// Run it on a COPY; opening a database migrates it.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:datalink_core/src/analysis/analysis.dart';
import 'package:datalink_core/src/protocol/py_json.dart';
import 'package:datalink_core/src/store/store.dart';

String digest(Object? value) => sha256.convert(pyJsonEncode(value).codeUnits).toString();

void main(List<String> args) {
  final store = Store.open(args.single);
  final createdAt = DateTime.utc(2026, 9, 30, 12, 34, 56, 789, 12);
  const runId = '00000000-0000-4000-8000-000000000000';

  stdout.writeln('classes - ${digest(store.listClasses())}');
  final sessions = store.listSessions();
  stdout.writeln('sessions - ${digest(sessions)}');
  final ids = [for (final s in sessions) s['id']! as int]..sort();
  for (final id in ids) {
    final session = store.session(id)!;
    final scans = store.sessionScans(id);
    final dismissed = store.dismissedReviews(id);
    stdout
      ..writeln('session $id ${digest(session)}')
      ..writeln('scans $id ${digest(scans)}')
      ..writeln('dismissed $id ${digest(dismissed.toList()..sort())}')
      ..writeln('fingerprint $id ${scanFingerprint(session, scans)}');
    try {
      final report = buildSessionAnalysis(
        session,
        scans,
        runId: runId,
        createdAt: createdAt,
        dismissed: dismissed,
      );
      stdout.writeln('analysis $id ${digest(report)}');
    } on AnalysisError catch (error) {
      stdout.writeln('analysis $id error ${digest(error.message)}');
    }
  }
  store.close();
}
