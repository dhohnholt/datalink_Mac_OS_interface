/// SQLite storage for classes, settings and scan history. A port of
/// `src/datalink_scanner/store.py`.
///
/// The schema, the column names, the WAL journal mode and the on-disk JSON
/// shapes are identical to the Python app's, so a `library.sqlite3` written by
/// one opens in the other. Anything that changes that is a migration and needs
/// a decision.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../protocol/constants.dart' show minAnswerCount;
import '../protocol/py_json.dart';
import '../protocol/python_compat.dart';

const String _schema = '''
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS classes (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS students (
    id         INTEGER PRIMARY KEY,
    class_id   INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    student_id TEXT NOT NULL,
    name       TEXT NOT NULL,
    position   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id             INTEGER PRIMARY KEY,
    name           TEXT NOT NULL DEFAULT '',
    class_name     TEXT NOT NULL DEFAULT '',
    question_count INTEGER NOT NULL,
    started_at     TEXT NOT NULL,
    ended_at       TEXT,
    log_path       TEXT,
    analysis_run_id      TEXT,
    analysis_fingerprint TEXT,
    source         TEXT NOT NULL DEFAULT 'datalink',
    page_cache     TEXT
);

-- Review items a teacher has looked at and is happy with. They are derived
-- from the marks on each read, so without somewhere to record the decision
-- the same warning came back every time the test was scored, and "Keep as
-- read" could never mean "I checked this".
CREATE TABLE IF NOT EXISTS review_dismissals (
    id         INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    item_key   TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(session_id, item_key)
);

CREATE TABLE IF NOT EXISTS scans (
    id             INTEGER PRIMARY KEY,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    number         INTEGER NOT NULL,
    role           TEXT NOT NULL,
    student_id     TEXT,
    student_name   TEXT,
    received_at    TEXT NOT NULL,
    answered_count INTEGER NOT NULL,
    responses      TEXT NOT NULL,
    demo           INTEGER NOT NULL DEFAULT 0,
    confidence     TEXT,
    pending_review INTEGER NOT NULL DEFAULT 0,
    -- What the scanner made of the sheet itself, marked against the key held
    -- in the device. NULL for anything it did not report, including every
    -- sheet read from paper.
    scanner_score  INTEGER
);

CREATE INDEX IF NOT EXISTS scans_by_session ON scans(session_id, number);
CREATE INDEX IF NOT EXISTS students_by_class ON students(class_id, position);
''';

/// A failure worth showing the teacher. The messages are user-facing and kept
/// identical to the Python `ValueError`s they replace.
class StoreError implements Exception {
  const StoreError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A student ID with the leading zeros a hand-typed roster can carry.
String bareId(Object? value) {
  var text = pyStrip(value == null || value == '' ? '' : value.toString());
  var start = 0;
  while (start < text.length && text[start] == '0') {
    start++;
  }
  text = text.substring(start);
  return text;
}

typedef StoreRow = Map<String, Object?>;

class Store {
  Store._(this._db, this.path, this._now);

  /// Open (creating if needed) the database at [path]; `:memory:` for tests.
  ///
  /// [now] supplies timestamps and exists so tests can be deterministic.
  factory Store.open(String path, {DateTime Function()? now}) {
    if (path != ':memory:') {
      Directory(File(path).parent.path).createSync(recursive: true);
    }
    final db = sqlite3.open(path);
    final store = Store._(db, path, now ?? DateTime.now);
    db
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('PRAGMA journal_mode = WAL')
      ..execute(_schema);
    store._migrate();
    return store;
  }

  final Database _db;
  final String path;
  final DateTime Function() _now;

  String _stamp() => pyIsoUtc(_now());

  /// Add columns to a database created by an earlier version.
  void _migrate() {
    final columns = {
      for (final row in _db.select('PRAGMA table_info(sessions)')) row['name']! as String,
    };
    void addSession(String column, String ddl) {
      if (!columns.contains(column)) _db.execute('ALTER TABLE sessions ADD COLUMN $ddl');
    }

    addSession('log_path', 'log_path TEXT');
    // The run id identifies one scoring run to the website. It is kept so a
    // retry reuses it, and regenerated only when the scans behind it change.
    addSession('analysis_run_id', 'analysis_run_id TEXT');
    addSession('analysis_fingerprint', 'analysis_fingerprint TEXT');
    // How the sheets were read. Everything created before this column existed
    // came off the scanner itself, which is the default.
    addSession('source', "source TEXT NOT NULL DEFAULT 'datalink'");
    // Where the rendered page images for a paper batch live.
    addSession('page_cache', 'page_cache TEXT');
    // A test given in several versions: the item map, standards and answers
    // as JSON (see analysis/test_package.dart). NULL for an ordinary test.
    addSession('package', 'package TEXT');

    final scanColumns = {
      for (final row in _db.select('PRAGMA table_info(scans)')) row['name']! as String,
    };
    void addScan(String column, String ddl) {
      if (!scanColumns.contains(column)) _db.execute('ALTER TABLE scans ADD COLUMN $ddl');
    }

    addScan('pending_review', 'pending_review INTEGER NOT NULL DEFAULT 0');
    addScan('scanner_score', 'scanner_score INTEGER');
    addScan('confidence', 'confidence TEXT');
    // The version bubbled on a printable sheet, for a package session.
    addScan('version', 'version TEXT');
  }

  /// Fold the write-ahead log back into the database before closing, so no
  /// `-wal`/`-shm` files are left behind and the main file holds the data.
  void close() {
    try {
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } on SqliteException {
      // Nothing useful to do at shutdown.
    }
    _db.close();
  }

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---------------------------------------------------------------- settings

  String getSetting(String key, [String fallback = '']) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    if (rows.isEmpty) return fallback;
    return (rows.first['value'] as String?) ?? fallback;
  }

  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  // ----------------------------------------------------------------- classes

  List<StoreRow> listClasses() {
    final rows = _db.select('SELECT id, name FROM classes ORDER BY name COLLATE NOCASE');
    return [
      for (final row in rows)
        <String, Object?>{
          'name': row['name'],
          'students': [
            for (final s in _db.select(
              'SELECT student_id, name FROM students WHERE class_id = ? ORDER BY position',
              [row['id']],
            ))
              <String, Object?>{'id': s['student_id'], 'name': s['name']},
          ],
        },
    ];
  }

  StoreRow? getClass(String name) {
    for (final item in listClasses()) {
      if (item['name'] == name) return item;
    }
    return null;
  }

  /// Create or rename-and-replace a class. Students are stored in the order
  /// given, which is the order the workspace walks through them.
  void saveClass(String name, List<Map<String, Object?>> students, [String? originalName]) {
    name = pyStrip(name);
    if (name.isEmpty) throw const StoreError('Enter a class name');

    final cleaned = <(String, String)>[];
    final seen = <String>{};
    for (final entry in students) {
      final studentId = pyStrip(_text(entry['id']));
      final studentName = pyStrip(_text(entry['name']));
      if (!pyIsDigit(studentId) || studentName.isEmpty) {
        throw StoreError(pyStrip('Fix roster line: $studentId $studentName'));
      }
      if (seen.contains(studentId)) {
        throw StoreError('Student ID $studentId appears more than once');
      }
      seen.add(studentId);
      cleaned.add((studentId, studentName));
    }

    _transaction(() {
      final previous = pyStrip(
        originalName != null && originalName.isNotEmpty ? originalName : name,
      );
      final existing = _db.select('SELECT id FROM classes WHERE name = ?', [previous]);
      final clash = _db.select('SELECT id FROM classes WHERE name = ? COLLATE NOCASE', [name]);
      final rowId = existing.isEmpty ? null : existing.first['id'] as int;
      if (clash.isNotEmpty && (rowId == null || clash.first['id'] != rowId)) {
        throw const StoreError('A class with that name already exists');
      }

      int classId;
      if (rowId == null) {
        _db.execute('INSERT INTO classes(name, created_at) VALUES(?, ?)', [name, _stamp()]);
        classId = _db.lastInsertRowId;
      } else {
        classId = rowId;
        _db.execute('UPDATE classes SET name = ? WHERE id = ?', [name, classId]);
        // Sessions keep the class name as text, so a rename has to reach them
        // too. Without this every session already recorded points at a class
        // that no longer answers to that name.
        if (previous != name) {
          _db.execute(
            'UPDATE sessions SET class_name = ? WHERE class_name = ?',
            [name, previous],
          );
        }
        _db.execute('DELETE FROM students WHERE class_id = ?', [classId]);
      }
      for (var index = 0; index < cleaned.length; index++) {
        _db.execute(
          'INSERT INTO students(class_id, student_id, name, position) VALUES(?, ?, ?, ?)',
          [classId, cleaned[index].$1, cleaned[index].$2, index],
        );
      }
    });
  }

  void deleteClass(String name) {
    _db.execute('DELETE FROM classes WHERE name = ?', [name]);
  }

  // ---------------------------------------------------------------- sessions

  int createSession(
    String name,
    String className,
    int questionCount, {
    String? logPath,
    String source = 'datalink',
    String? pageCache,
    String? package,
  }) {
    _db.execute(
      'INSERT INTO sessions(name, class_name, question_count, started_at, '
      'log_path, source, page_cache, package) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
      [
        name,
        className,
        questionCount,
        _stamp(),
        logPath,
        source.isEmpty ? 'datalink' : source,
        pageCache,
        package,
      ],
    );
    return _db.lastInsertRowId;
  }

  void updateSession(int sessionId, {String? name, String? className, bool finished = false}) {
    final assignments = <String>[];
    final values = <Object?>[];
    if (name != null) {
      assignments.add('name = ?');
      values.add(name);
    }
    if (className != null) {
      assignments.add('class_name = ?');
      values.add(className);
    }
    if (finished) {
      assignments.add('ended_at = ?');
      values.add(_stamp());
    }
    if (assignments.isEmpty) return;
    values.add(sessionId);
    _db.execute('UPDATE sessions SET ${assignments.join(', ')} WHERE id = ?', values);
  }

  /// What scoring [sessionId] out of [count] questions would leave out: how
  /// many sheets have a mark after question [count], and how many marks.
  ({int sheets, int marks}) answersBeyond(int sessionId, int count) {
    var sheets = 0;
    var marks = 0;
    for (final scan in sessionScans(sessionId)) {
      final extra = (scan['responses']! as List).skip(count).where((r) => '$r'.isNotEmpty).length;
      if (extra > 0) {
        sheets++;
        marks += extra;
      }
    }
    return (sheets: sheets, marks: marks);
  }

  /// Score a session out of fewer questions: drop every sheet's responses after
  /// question [count] and lower the session's count to match, together or not
  /// at all.
  ///
  /// Only ever downwards. The answers past a session's count were never kept,
  /// so a larger count could not bring them back; that takes scanning again.
  /// The analysis is computed from these rows on demand, and its fingerprint
  /// includes the count, so the next score is a new run, as a correction is.
  void useFewerQuestions(int sessionId, int count) {
    _transaction(() {
      final row = session(sessionId);
      if (row == null) throw const StoreError('No such session');
      final current = row['question_count']! as int;
      if (count < minAnswerCount || count >= current) {
        throw StoreError(
          'A test can only be changed to fewer questions than it has now ($current); '
          'asked for $count.',
        );
      }
      for (final scan in sessionScans(sessionId)) {
        final responses = (scan['responses']! as List).map((r) => '$r').toList();
        if (responses.length <= count) continue;
        final kept = responses.sublist(0, count);
        _db.execute(
          'UPDATE scans SET responses = ?, answered_count = ? WHERE session_id = ? AND number = ?',
          [pyJsonEncode(kept), kept.where((r) => r.isNotEmpty).length, sessionId, scan['number']],
        );
      }
      _db.execute('UPDATE sessions SET question_count = ? WHERE id = ?', [count, sessionId]);
    });
  }

  void rememberRunId(int sessionId, String runId, String fingerprint) {
    _db.execute(
      'UPDATE sessions SET analysis_run_id = ?, analysis_fingerprint = ? WHERE id = ?',
      [runId, fingerprint, sessionId],
    );
  }

  int addScan(int sessionId, Map<String, Object?> scan) {
    // Evaluated whether or not a received_at is supplied, as the Python
    // `scan.get("received_at", _now())` does; it only matters to a fake clock.
    final fallbackStamp = _stamp();
    final confidence = scan['confidence'];
    _db.execute(
      'INSERT INTO scans(session_id, number, role, student_id, student_name, '
      'received_at, answered_count, responses, demo, confidence, '
      'pending_review, scanner_score, version) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        sessionId,
        _int(scan['number'], 0),
        scan.containsKey('role') ? scan['role'].toString() : 'student',
        scan['student_id'],
        scan['student_name'],
        scan.containsKey('received_at') ? scan['received_at'].toString() : fallbackStamp,
        _int(scan['answered_count'], 0),
        pyJsonEncode(List<Object?>.from((scan['responses'] as List?) ?? const [])),
        _truthy(scan['demo']) ? 1 : 0,
        _truthy(confidence) ? pyJsonEncode(confidence) : null,
        _truthy(scan['pending_review']) ? 1 : 0,
        scan['scanner_score'],
        scan['version'],
      ],
    );
    return _db.lastInsertRowId;
  }

  /// Correct one stored sheet.
  ///
  /// The scanner is accurate, but a sheet can still be fed with a smudged ID,
  /// and an answer key can be bubbled wrong. Editing the stored row is enough:
  /// the analysis is computed from these rows on demand, so it follows.
  bool updateScan(
    int sessionId,
    int number, {
    String? studentId,
    String? studentName,
    List<String>? responses,
  }) {
    final assignments = <String>[];
    final values = <Object?>[];
    if (studentId != null) {
      assignments.add('student_id = ?');
      values.add(studentId.isEmpty ? null : studentId);
    }
    if (studentName != null) {
      assignments.add('student_name = ?');
      values.add(studentName.isEmpty ? null : studentName);
    }
    if (responses != null) {
      assignments.add('responses = ?');
      values.add(pyJsonEncode(responses));
      assignments.add('answered_count = ?');
      values.add(responses.where((value) => value.isNotEmpty).length);
    }
    if (assignments.isEmpty) return false;
    assignments.add('pending_review = 0');
    values.addAll([sessionId, number]);
    _db.execute(
      'UPDATE scans SET ${assignments.join(', ')} WHERE session_id = ? AND number = ?',
      values,
    );
    return _db.updatedRows > 0;
  }

  /// Delete one student sheet from a session. The answer key is deliberately
  /// protected because every score in the session depends on it.
  bool deleteStudentScan(int sessionId, int number) {
    _db.execute(
      "DELETE FROM scans WHERE session_id = ? AND number = ? AND role != 'key'",
      [sessionId, number],
    );
    return _db.updatedRows > 0;
  }

  /// Commit a validated correction batch and its review decisions together.
  (int applied, int settled) applyCorrections(
    int sessionId,
    List<Map<String, Object?>> corrections,
    List<String> dismiss,
  ) {
    return _transaction(() {
      var applied = 0;
      for (final correction in corrections) {
        final number = correction['number']! as int;
        final changed = updateScan(
          sessionId,
          number,
          studentId: correction['student_id'] as String?,
          studentName: correction['student_name'] as String?,
          responses: (correction['responses'] as List?)?.cast<String>(),
        );
        if (!changed) {
          throw StoreError('Sheet $number was not found or has no changes');
        }
        applied++;
      }
      final settled = dismissReviews(sessionId, dismiss);
      return (applied, settled);
    });
  }

  List<StoreRow> listSessions() {
    final rows = _db.select(
      'SELECT s.id, s.name, s.class_name, s.question_count, s.started_at, '
      '       s.ended_at, s.source, COUNT(c.id) AS scan_count '
      'FROM sessions s LEFT JOIN scans c ON c.session_id = s.id '
      'GROUP BY s.id ORDER BY s.started_at DESC',
    );
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  StoreRow? session(int sessionId) {
    final rows = _db.select(
      'SELECT id, name, class_name, question_count, started_at, ended_at, '
      '       log_path, analysis_run_id, analysis_fingerprint, source, page_cache, package '
      'FROM sessions WHERE id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    // Only a package session carries the key, so an ordinary one reads exactly
    // as it always has.
    final row = Map<String, Object?>.from(rows.first);
    if (row['package'] == null) row.remove('package');
    return row;
  }

  /// Fill in names the roster knows, for sheets that have an ID but none.
  ///
  /// A roster imported or corrected after a batch was filed still names its
  /// students: this looks again each time a session is opened or scored, which
  /// costs nothing and cannot go stale.
  int nameMissingStudents(int sessionId) {
    final found = session(sessionId);
    if (found == null || !_truthy(found['class_name'])) return 0;
    final entry = getClass(found['class_name']! as String);
    if (entry == null) return 0;
    // Matched the way the scan path matches: a roster typed by hand can carry
    // leading zeros that a bubbled ID does not.
    final byId = <String, String>{};
    for (final student in (entry['students']! as List<Object?>).cast<Map<String, Object?>>()) {
      final key = bareId(student['id']);
      if (key.isNotEmpty) byId[key] = (student['name'] as String?) ?? '';
    }
    if (byId.isEmpty) return 0;

    var filled = 0;
    final rows = _db.select(
      'SELECT number, student_id FROM scans '
      "WHERE session_id = ? AND role != 'key' "
      "AND student_id IS NOT NULL AND student_id != '' "
      "AND (student_name IS NULL OR student_name = '')",
      [sessionId],
    );
    for (final row in rows) {
      final name = byId[bareId(row['student_id'])];
      if (name == null || name.isEmpty) continue;
      _db.execute(
        'UPDATE scans SET student_name = ? WHERE session_id = ? AND number = ?',
        [name, sessionId, row['number']],
      );
      filled++;
    }
    return filled;
  }

  List<StoreRow> sessionScans(int sessionId) {
    final rows = _db.select(
      'SELECT number, role, student_id, student_name, received_at, '
      '       answered_count, responses, demo, confidence, pending_review, '
      '       scanner_score, version '
      'FROM scans WHERE session_id = ? ORDER BY number',
      [sessionId],
    );
    return [
      for (final row in rows)
        () {
          final scan = Map<String, Object?>.from(row);
          scan['responses'] = _decodeList(scan['responses']);
          scan['demo'] = scan['demo'] != 0;
          scan['confidence'] =
              _truthy(scan['confidence']) ? _decodeMap(scan['confidence']) : <String, Object?>{};
          if (scan['version'] == null) scan.remove('version');
          return scan;
        }(),
    ];
  }

  void deleteSession(int sessionId) {
    _db.execute('DELETE FROM sessions WHERE id = ?', [sessionId]);
  }

  // ------------------------------------------------- reviewed and dismissed

  /// Which review items this session's teacher has already settled.
  Set<String> dismissedReviews(int sessionId) => {
        for (final row in _db.select(
          'SELECT item_key FROM review_dismissals WHERE session_id = ?',
          [sessionId],
        ))
          row['item_key']! as String,
      };

  /// Settle review items. Doing it twice is not an error.
  int dismissReviews(int sessionId, List<String> itemKeys) {
    final wanted = [
      for (final key in itemKeys)
        if (pyStrip(key).isNotEmpty) key,
    ];
    if (wanted.isEmpty) return 0;
    final now = _stamp();
    int count() => _db.select(
          'SELECT COUNT(*) AS n FROM review_dismissals WHERE session_id = ?',
          [sessionId],
        ).first['n']! as int;
    final before = count();
    for (final key in wanted) {
      _db.execute(
        'INSERT OR IGNORE INTO review_dismissals(session_id, item_key, created_at) '
        'VALUES(?, ?, ?)',
        [sessionId, key, now],
      );
    }
    return count() - before;
  }

  /// Bring every settled item on this session back for another look.
  int restoreReviews(int sessionId) {
    _db.execute('DELETE FROM review_dismissals WHERE session_id = ?', [sessionId]);
    return _db.updatedRows;
  }

  /// Drop sessions that never received a sheet. Connecting to check the
  /// scanner should not litter the history.
  ///
  /// [sessionId] limits it to the one being ended, which is what a caller
  /// almost always means: a paper batch is written as a session first and
  /// filled a moment later, so a bare sweep triggered by an unrelated session
  /// ending could delete it out from under its own import.
  int pruneEmptySessions([int? sessionId]) {
    var query = 'DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session_id FROM scans)';
    final values = <Object?>[];
    if (sessionId != null) {
      query += ' AND id = ?';
      values.add(sessionId);
    }
    _db.execute(query, values);
    return _db.updatedRows;
  }

  // ----------------------------------------------------------------- storage

  /// What this app is keeping, and where.
  StoreRow storageReport() {
    final counts = _db.select(
      'SELECT (SELECT COUNT(*) FROM sessions) AS sessions, '
      '       (SELECT COUNT(*) FROM scans)    AS scans, '
      '       (SELECT COUNT(*) FROM classes)  AS classes, '
      '       (SELECT MIN(started_at) FROM sessions) AS oldest',
    ).first;
    final report = Map<String, Object?>.from(counts);
    final directory = path == ':memory:' ? null : Directory(File(path).parent.path);
    var database = 0;
    var logs = 0;
    var logCount = 0;
    if (directory != null && directory.existsSync()) {
      for (final entry in directory.listSync().whereType<File>()) {
        final name = entry.uri.pathSegments.last;
        if (name.startsWith('library.sqlite3')) {
          database += entry.lengthSync();
        } else if (name.endsWith('.jsonl')) {
          logs += entry.lengthSync();
          logCount++;
        }
      }
    }
    report['database_bytes'] = database;
    report['log_bytes'] = logs;
    report['log_files'] = logCount;
    report['total_bytes'] = database + logs;
    report['directory'] = directory?.path ?? '';
    return report;
  }

  /// Sessions started more than [days] ago, with their log files.
  List<StoreRow> sessionsOlderThan(int days) {
    if (days < 0) throw const StoreError('Days must not be negative');
    final cutoff = pyIsoUtc(_now().toUtc().subtract(Duration(days: days)));
    return [
      for (final row in _db.select(
        'SELECT id, name, started_at, log_path FROM sessions '
        'WHERE started_at < ? ORDER BY started_at',
        [cutoff],
      ))
        Map<String, Object?>.from(row),
    ];
  }

  int deleteSessions(List<int> sessionIds) {
    if (sessionIds.isEmpty) return 0;
    final placeholders = List.filled(sessionIds.length, '?').join(',');
    _db.execute('DELETE FROM sessions WHERE id IN ($placeholders)', sessionIds);
    return _db.updatedRows;
  }

  /// Hand freed pages back to the filesystem after a bulk delete.
  void vacuum() => _db.execute('VACUUM');

  // ----------------------------------------------------------------- helpers

  static bool _truthy(Object? value) =>
      value != null && value != 0 && value != '' && value != false;

  static int _int(Object? value, int fallback) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.truncate();
    return pyInt(value) ?? fallback;
  }

  static String _text(Object? value) => value == null ? '' : value.toString();

  static List<Object?> _decodeList(Object? text) => jsonDecode(text! as String) as List<Object?>;

  static Map<String, Object?> _decodeMap(Object? text) =>
      (jsonDecode(text! as String) as Map).cast<String, Object?>();
}

