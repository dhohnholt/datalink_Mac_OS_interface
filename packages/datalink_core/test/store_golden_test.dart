// Replays tools/goldens/make_store_goldens.py against the Dart store.
//
// Each scenario is a list of operations that the Python Store ran on a
// deterministic clock. The Dart store must return the same thing from every
// one, raise the same errors, and leave the same rows and the same schema.
//
//   .venv/bin/python tools/goldens/make_store_goldens.py
import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/src/store/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

late final Map<String, Object?> golden;

List<Object?> list(Object? value) => value! as List<Object?>;
Map<String, Object?> map(Object? value) => (value! as Map).cast<String, Object?>();

const tables = [
  'settings',
  'classes',
  'students',
  'sessions',
  'review_dismissals',
  'scans',
];

class Clock {
  Clock(this.base);

  final DateTime base;
  int ticks = 0;
  Duration offset = Duration.zero;

  DateTime now() => base.add(Duration(seconds: ticks++)).add(offset);
}

/// Mirror of `apply()` in the generator.
Object? apply(Store store, Clock clock, Map<String, Object?> op) {
  final a = map(op['args'] ?? <String, Object?>{});
  List<Map<String, Object?>> maps(Object? v) => [for (final e in list(v)) map(e)];

  switch (op['op']! as String) {
    case 'set_setting':
      store.setSetting(a['key']! as String, a['value']! as String);
      return null;
    case 'get_setting':
      return store.getSetting(a['key']! as String, (a['default'] as String?) ?? '');
    case 'save_class':
      store.saveClass(a['name']! as String, maps(a['students']), a['original_name'] as String?);
      return null;
    case 'delete_class':
      store.deleteClass(a['name']! as String);
      return null;
    case 'list_classes':
      return store.listClasses();
    case 'get_class':
      return store.getClass(a['name']! as String);
    case 'create_session':
      return store.createSession(
        a['name']! as String,
        a['class_name']! as String,
        a['question_count']! as int,
        logPath: a['log_path'] as String?,
        source: (a['source'] as String?) ?? 'datalink',
        pageCache: a['page_cache'] as String?,
      );
    case 'update_session':
      store.updateSession(
        a['id']! as int,
        name: a['name'] as String?,
        className: a['class_name'] as String?,
        finished: (a['finished'] as bool?) ?? false,
      );
      return null;
    case 'remember_run_id':
      store.rememberRunId(a['id']! as int, a['run_id']! as String, a['fingerprint']! as String);
      return null;
    case 'add_scan':
      return store.addScan(a['session_id']! as int, map(a['scan']));
    case 'update_scan':
      return store.updateScan(
        a['session_id']! as int,
        a['number']! as int,
        studentId: a['student_id'] as String?,
        studentName: a['student_name'] as String?,
        responses: (a['responses'] as List?)?.cast<String>(),
      );
    case 'apply_corrections':
      final (applied, settled) = store.applyCorrections(
        a['session_id']! as int,
        maps(a['corrections']),
        list(a['dismiss']).cast<String>(),
      );
      return [applied, settled];
    case 'list_sessions':
      return store.listSessions();
    case 'session':
      return store.session(a['id']! as int);
    case 'name_missing_students':
      return store.nameMissingStudents(a['id']! as int);
    case 'session_scans':
      return store.sessionScans(a['id']! as int);
    case 'delete_session':
      store.deleteSession(a['id']! as int);
      return null;
    case 'dismissed_reviews':
      return store.dismissedReviews(a['id']! as int).toList()..sort();
    case 'dismiss_reviews':
      return store.dismissReviews(a['id']! as int, list(a['keys']).cast<String>());
    case 'restore_reviews':
      return store.restoreReviews(a['id']! as int);
    case 'prune_empty_sessions':
      return store.pruneEmptySessions(a['session_id'] as int?);
    case 'sessions_older_than':
      return store.sessionsOlderThan(a['days']! as int);
    case 'delete_sessions':
      return store.deleteSessions(list(a['ids']).cast<int>());
    case 'vacuum':
      store.vacuum();
      return null;
    case 'advance':
      clock.offset += Duration(days: a['days']! as int);
      return null;
  }
  throw StateError('unknown op ${op['op']}');
}

Map<String, Object?> dump(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final out = <String, Object?>{'tables': <String, Object?>{}, 'schema': <String, Object?>{}};
    for (final table in tables) {
      final order = table == 'settings' ? 'key' : 'id';
      (out['tables']! as Map<String, Object?>)[table] = [
        for (final row in db.select('SELECT * FROM $table ORDER BY $order'))
          Map<String, Object?>.from(row),
      ];
      (out['schema']! as Map<String, Object?>)[table] = [
        for (final r in db.select('PRAGMA table_info($table)'))
          [r['name'], r['type'], r['notnull'], r['dflt_value'], r['pk']],
      ];
    }
    out['indexes'] = [
      for (final r in db.select(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      ))
        r['name'],
    ];
    return out;
  } finally {
    db.close();
  }
}

void main() {
  setUpAll(() {
    final bytes = GZipCodec().decode(File('test/goldens/store.json.gz').readAsBytesSync());
    golden = map(jsonDecode(utf8.decode(bytes)));
  });

  test('every scenario matches the Python store, results and final rows', () {
    final base = DateTime.parse(golden['base']! as String).toUtc();
    for (final raw in list(golden['scenarios'])) {
      final scenario = map(raw);
      final name = scenario['name']! as String;
      final directory = Directory.systemTemp.createTempSync('datalink-store');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/library.sqlite3';

      final clock = Clock(base);
      final store = Store.open(path, now: clock.now);
      final ops = list(scenario['ops']);
      final expected = list(scenario['results']);
      for (var i = 0; i < ops.length; i++) {
        final op = map(ops[i]);
        final want = map(expected[i]);
        final where = '$name, op $i (${op['op']} ${jsonEncode(op['args'])})';
        Object? got;
        Map<String, Object?> outcome;
        try {
          got = apply(store, clock, op);
          outcome = {'ok': got};
        } on StoreError catch (error) {
          outcome = {'error': error.message};
        } on SqliteException {
          outcome = {'db_error': true};
        }
        expect(jsonEncode(outcome), jsonEncode(want), reason: where);
      }
      store.close();

      final actual = dump(path);
      final wantDump = map(scenario['dump']);
      expect(actual['schema'], wantDump['schema'], reason: '$name: schema');
      expect(actual['indexes'], wantDump['indexes'], reason: '$name: indexes');
      for (final table in tables) {
        expect(
          jsonEncode((actual['tables']! as Map)[table]),
          jsonEncode(map(wantDump['tables'])[table]),
          reason: '$name: rows of $table',
        );
      }
    }
  });

  test('close leaves no write-ahead log behind', () {
    final directory = Directory.systemTemp.createTempSync('datalink-wal');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = Store.open('${directory.path}/library.sqlite3')
      ..createSession('x', '', 3)
      ..close();
    expect(store, isNotNull);
    final names = directory.listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, contains('library.sqlite3'));
    expect(names.where((n) => n.endsWith('-wal') || n.endsWith('-shm')), isEmpty);
  });

  test('storageReport counts what the store keeps', () {
    final directory = Directory.systemTemp.createTempSync('datalink-report');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/a.jsonl').writeAsStringSync('12345');
    File('${directory.path}/b.jsonl').writeAsStringSync('123');
    final store = Store.open('${directory.path}/library.sqlite3');
    addTearDown(store.close);
    final id = store.createSession('x', 'P', 3);
    store.addScan(id, {'number': 1, 'role': 'key', 'responses': ['A']});
    final report = store.storageReport();
    expect(report['sessions'], 1);
    expect(report['scans'], 1);
    expect(report['classes'], 0);
    expect(report['log_files'], 2);
    expect(report['log_bytes'], 8);
    expect(report['database_bytes'] as int, greaterThan(0));
    expect(report['total_bytes'], (report['database_bytes'] as int) + 8);
    expect(report['directory'], directory.path);
  });

  test('a database from an earlier version gains the newer columns', () {
    final directory = Directory.systemTemp.createTempSync('datalink-old');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final old = sqlite3.open(path)
      ..execute('CREATE TABLE sessions (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT "", '
          'class_name TEXT NOT NULL DEFAULT "", question_count INTEGER NOT NULL, '
          'started_at TEXT NOT NULL, ended_at TEXT)')
      ..execute("INSERT INTO sessions(name, question_count, started_at) VALUES('old', 5, 'x')")
      ..execute('CREATE TABLE scans (id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, '
          'number INTEGER NOT NULL, role TEXT NOT NULL, student_id TEXT, student_name TEXT, '
          'received_at TEXT NOT NULL, answered_count INTEGER NOT NULL, responses TEXT NOT NULL, '
          'demo INTEGER NOT NULL DEFAULT 0)')
      ..close();
    expect(old, isNotNull);

    final store = Store.open(path);
    addTearDown(store.close);
    final session = store.session(1)!;
    expect(session['name'], 'old');
    expect(session['source'], 'datalink');
    expect(session.containsKey('log_path'), isTrue);
    expect(session.containsKey('page_cache'), isTrue);
    expect(store.sessionScans(1), isEmpty);
  });
}
