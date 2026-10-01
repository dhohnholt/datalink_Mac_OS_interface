/// Owns the scanner connection, the sheets on screen and the session being
/// recorded. A port of `ScannerController` in `server.py`.
///
/// The Python version ran a reader thread and used pause/idle events so a
/// handshake re-send never overlapped a read. Here everything runs on one
/// isolate and port access goes through [_PortLock], which gives the same
/// guarantee: the reader and `resetScanner` never touch the port together.
library;

import 'dart:async';
import 'dart:io';

import '../analysis/csv_export.dart';
import '../protocol/constants.dart';
import '../protocol/errors.dart';
import '../protocol/form_record.dart';
import '../protocol/messages.dart';
import '../protocol/py_json.dart';
import '../protocol/scanner.dart';
import '../serial/serial.dart';
import '../store/store.dart';

/// One line of the activity list.
class ActivityEntry {
  const ActivityEntry(this.time, this.message, this.kind);

  final String time;
  final String message;

  /// `info`, `protocol`, `success`, `warning` or `error`.
  final String kind;
}

/// Everything the screen needs to draw the Scan tab. Immutable.
class ScannerSnapshot {
  const ScannerSnapshot({
    required this.state,
    required this.port,
    required this.error,
    required this.records,
    required this.pendingReview,
    required this.activity,
    required this.outputPath,
    required this.captureRoot,
    required this.sessionId,
    required this.sessionName,
    required this.questionCount,
    required this.ports,
  });

  /// `disconnected`, `connecting`, `connected` or `error`.
  final String state;
  final String? port;
  final String? error;
  final List<Map<String, Object?>> records;

  /// The first sheet waiting on a human, or null.
  final Map<String, Object?>? pendingReview;

  /// Newest first, at most 30.
  final List<ActivityEntry> activity;
  final String? outputPath;
  final String captureRoot;
  final int? sessionId;
  final String sessionName;
  final int questionCount;
  final List<String> ports;

  int get recordCount => records.length;
  bool get scanning => sessionId != null;
  bool get connected => state == 'connected';
  static const int minQuestionCount = minAnswerCount;
  static const int maxQuestionCount = maxAnswerCount;
}

/// What ending a session reports.
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.sheets,
    required this.pendingReview,
    required this.message,
  });

  final int sessionId;
  final int sheets;
  final int pendingReview;
  final String message;
}

class _PortLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) {
    final done = Completer<T>();
    final previous = _tail;
    _tail = done.future.then<void>((_) {}, onError: (Object _) {});
    previous.then((_) async {
      try {
        done.complete(await body());
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}

class ScannerController {
  ScannerController({
    required this.captureRoot,
    required this.store,
    required this.transport,
    required this.clock,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Directory captureRoot;
  final Store store;
  final SerialTransport transport;
  final Clock clock;
  final DateTime Function() _now;

  final StreamController<ScannerSnapshot> _changes = StreamController.broadcast();
  final _PortLock _lock = _PortLock();

  DataLinkScanner? _scanner;
  bool _stopReader = false;
  int? _sessionId;
  String _sessionName = '';
  File? _outputFile;
  String _state = 'disconnected';
  String? _port;
  String? _error;
  int _questionCount = defaultAnswerCount;
  List<String> _ports = const [];

  final List<Map<String, Object?>> _records = [];
  final List<Map<String, Object?>> _pendingReviews = [];
  final Map<int, DataLinkFormRecord> _pendingRecords = {};
  final List<ActivityEntry> _activity = [];

  /// A new snapshot each time anything the screen shows changes.
  Stream<ScannerSnapshot> get changes => _changes.stream;

  ScannerSnapshot snapshot() => ScannerSnapshot(
        state: _state,
        port: _port,
        error: _error,
        records: List.unmodifiable(_records.map(Map<String, Object?>.unmodifiable)),
        pendingReview: _pendingReviews.isEmpty
            ? null
            : Map<String, Object?>.unmodifiable(_pendingReviews.first),
        activity: List.unmodifiable(_activity.take(30)),
        outputPath: _outputFile?.path,
        captureRoot: captureRoot.path,
        sessionId: _sessionId,
        sessionName: _sessionName,
        questionCount: _questionCount,
        ports: _ports,
      );

  int _revision = 0;

  /// Counts every change. A reader that keeps a [snapshot] can tell whether it
  /// is still current without waiting for the next event on [changes]: events
  /// arrive later than the change that caused them, so a stored one can be
  /// older than state the reader has already seen.
  int get revision => _revision;

  void _changed() {
    _revision++;
    if (!_changes.isClosed) _changes.add(snapshot());
  }

  void _log(String message, [String kind = 'info']) {
    final t = _now().toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    _activity.insert(0, ActivityEntry('${two(t.hour)}:${two(t.minute)}:${two(t.second)}', message, kind));
    _changed();
  }

  /// Refresh the list of candidate ports shown in the picker.
  Future<List<String>> refreshPorts() async {
    _ports = await transport.listPorts();
    _changed();
    return _ports;
  }

  /// Open the port and run the handshake. This starts no session.
  ///
  /// Connecting and scanning used to be the same act, which left no way to
  /// finish one class's sheets and begin the next without unplugging. The
  /// hardware is now brought up once and a session is started and ended on top
  /// of it as often as the day needs.
  Future<void> connect(String? requestedPort, Object? questionCount) async {
    final count = validateQuestionCount(questionCount);
    if (_state == 'connecting' || _state == 'connected') {
      throw const DataLinkError('Scanner is already connected or connecting');
    }
    _state = 'connecting';
    _error = null;
    _log('Opening the scanner and running the captured handshake.');

    DataLinkScanner? scanner;
    try {
      final port = (requestedPort != null && requestedPort.isNotEmpty)
          ? requestedPort
          : discoverPort(await transport.listPorts());
      scanner = DataLinkScanner(
        port,
        transport: transport,
        clock: clock,
        questionCount: count,
        now: _now,
      );
      await scanner.open();
      final initialization = await scanner.initialize();
      final transition = await scanner.enterDataCollection();
      _scanner = scanner;
      _port = port;
      _questionCount = count;
      _state = 'connected';
      _stopReader = false;
      for (final (command, reply) in [...initialization, ...transition]) {
        _log('$command → $reply', 'protocol');
      }
      _log('Data Collection is active.', 'success');
      unawaited(_readLoop());
    } on Object catch (error) {
      await scanner?.close();
      _state = 'error';
      _error = _message(error);
      _scanner = null;
      _port = requestedPort;
      _log(_error!, 'error');
      rethrow;
    }
  }

  /// Open a session with a fresh scanner collection state.
  ///
  /// The explicit UI action resets a connected scanner first: a DataLink can
  /// retain a pending second-side prompt after an interrupted key, and the
  /// reset clears it before the next one-sided key is fed. The reader's
  /// automatic-session path leaves the port alone because a sheet has already
  /// arrived by then.
  Future<int> startSession({Object? questionCount, bool resetScanner = false}) async {
    if (resetScanner && _scanner != null) await this.resetScanner();
    return _startSessionNow(questionCount);
  }

  int _startSessionNow(Object? questionCount) {
    if (_sessionId != null) {
      throw const DataLinkError('A session is already running. End it before starting another.');
    }
    if (questionCount != null) _questionCount = validateQuestionCount(questionCount);
    final count = _questionCount;
    _scanner?.parser.questionCount = count;

    final name = store.getSetting('test_name');
    final className = store.getSetting('selected_class');
    final stamp = _fileStamp(_now());
    captureRoot.createSync(recursive: true);
    final output = File('${captureRoot.path}/browser_session_$stamp.jsonl');
    final sessionId = store.createSession(name, className, count, logPath: output.path);
    _sessionId = sessionId;
    _sessionName = name;
    _outputFile = output;
    _records.clear();
    _pendingReviews.clear();
    _pendingRecords.clear();
    final label = name.isNotEmpty ? '“$name”' : 'an unnamed session';
    _log('Started $label. Feed the answer key first.', 'success');
    return sessionId;
  }

  /// Close the session and leave the scanner up for the next one.
  SessionSummary endSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw const DataLinkError('No session is running');
    final saved = store.sessionScans(sessionId);
    final sheets = saved.length;
    final keys = saved.where((r) => r['role'] == 'key').length;
    final waiting = _pendingReviews.length;
    final name = _sessionName;
    _sessionId = null;
    _sessionName = '';
    _outputFile = null;
    _pendingReviews.clear();
    _pendingRecords.clear();

    store
      ..updateSession(sessionId, finished: true)
      ..pruneEmptySessions(sessionId);
    final students = sheets - keys < 0 ? 0 : sheets - keys;
    final label = name.isNotEmpty ? '“$name”' : 'The session';
    var summary = '$label ended with $students student sheet'
        '${students == 1 ? '' : 's'}'
        '${keys == 0 ? ' and no answer key.' : '.'}';
    if (waiting > 0) {
      summary += ' $waiting sheet${waiting == 1 ? '' : 's'}'
          ' ${waiting == 1 ? 'was' : 'were'} still waiting for review'
          '; all remain saved for review under Analysis.';
    }
    _log(summary, (waiting > 0 || keys == 0) ? 'warning' : 'success');
    return SessionSummary(
      sessionId: sessionId,
      sheets: students,
      pendingReview: waiting,
      message: summary,
    );
  }

  /// Score the running session out of fewer questions than it was started
  /// with: for a key marked for 30 questions in a session set up for 50.
  /// Returns what was left out, `(sheets, marks)`.
  ///
  /// Only downwards, because the answers past the old count were never kept.
  /// Refused while a sheet waits for review, since its marks are still being
  /// decided against the old count.
  ({int sheets, int marks}) changeQuestionCount(int count) {
    final sessionId = _sessionId;
    if (sessionId == null) throw const DataLinkError('No session is running');
    if (_pendingReviews.isNotEmpty) {
      throw const DataLinkError('Finish the sheet waiting for review first');
    }
    if (count < minAnswerCount || count >= _questionCount) {
      throw DataLinkError(
        'The question count can only be lowered, from $_questionCount to a number from '
        '$minAnswerCount to ${_questionCount - 1}',
      );
    }
    final loss = store.answersBeyond(sessionId, count);
    store.useFewerQuestions(sessionId, count);
    final before = _questionCount;
    _questionCount = count;
    _scanner?.parser.questionCount = count;
    for (final record in _records) {
      final kept = List<String>.from(record['responses']! as List).take(count).toList();
      record['responses'] = kept;
      record['answered_count'] = kept.where((r) => r.isNotEmpty).length;
    }
    _log('Scoring out of $count questions instead of $before.', 'success');
    _changed();
    return loss;
  }

  /// Re-send the handshake on the open port.
  ///
  /// This was written believing it was the software equivalent of the Reset
  /// button on the device. It is not, and measurement said so: with the
  /// handshake already in force a sheet was still held for its other side, and
  /// only a press of the physical button cleared it. What this does do is
  /// re-establish Data Collection when the conversation has got out of step.
  Future<void> resetScanner() async {
    final scanner = _scanner;
    if (scanner == null) throw const DataLinkError('Connect the scanner first');
    // Waits for any read in progress: two readers on one serial port lose
    // bytes between them.
    final List<Exchange> transcript;
    try {
      transcript = await _lock.run(scanner.resynchronize);
    } on Object catch (error) {
      _log('Could not reset the scanner: ${_message(error)}', 'error');
      rethrow;
    }
    for (final (command, reply) in transcript) {
      _log('$command → $reply', 'protocol');
    }
    _log(
      'Re-sent the handshake and Data Collection is active again. This does '
      'not change the mode the scanner is in: if it is holding a sheet and '
      'asking for its other side, press Reset on the device until its display '
      'reads Scan Mode Ready.',
      'success',
    );
  }

  Future<void> _readLoop() async {
    while (!_stopReader) {
      final scanner = _scanner;
      if (scanner == null) return;
      try {
        await _lock.run(() async {
          if (_stopReader || _scanner == null) return;
          final chunk = await scanner.readAvailable();
          final messages = [...chunk.messages];
          final fragment = scanner.parser.takeStaleFragment();
          if (fragment != null) messages.add(fragment);
          for (final message in messages) {
            // A line that is not a form record used to be filed as protocol
            // chatter, which the activity list hides unless protocol details
            // are showing. That is how a scanner asking for the other side of a
            // sheet went unread while nothing else would feed.
            final (kind, described) = describeMessage(message);
            _log(described, kind.name);
          }
          if (chunk.records.isNotEmpty && _sessionId == null) {
            // A sheet has already gone through the machine. Refusing it here
            // would lose it for good, so open a session around it and say so.
            _startSessionNow(null);
            _log('A sheet arrived with no session running, so one was started for it.', 'warning');
          }
          for (final record in chunk.records) {
            _acceptRecord(record);
          }
        });
      } on DataLinkError catch (error) {
        _log('Skipped an invalid scanner record: ${error.message}', 'error');
        // Yield even on this path. Without an await that takes time, a fault
        // that repeats on every read would spin here and starve the UI.
        await clock.sleep(0.025);
        continue;
      } on Object catch (error) {
        _state = 'error';
        _error = _message(error);
        _log('Scanner read failed: $_error', 'error');
        return;
      }
      await clock.sleep(0.025);
    }
  }

  void _acceptRecord(DataLinkFormRecord record) {
    final sessionId = _sessionId!;
    final output = _outputFile;
    final public = record.publicDict();
    public['number'] = _records.length + _pendingReviews.length + 1;
    public['role'] = public['number'] == 1 ? 'key' : 'student';
    final number = public['number']! as int;
    final role = public['role']! as String;

    final ambiguities = <Map<String, Object?>>[
      for (var index = 0; index < record.responses.length; index++)
        if (record.responses[index].length > 1)
          <String, Object?>{
            'question': index + 1,
            'value': record.responses[index],
            'options': record.responses[index].split(''),
          },
    ];

    if (role == 'student' || ambiguities.isNotEmpty) {
      public['student_id'] = public['scanner_id'];
      public['pending_review'] = true;
      // Save before presenting the sheet to the UI. The stored pending flag
      // keeps it reviewable after a restart.
      store.addScan(sessionId, public);
      if (output != null) appendJsonl(output, record, false, extra: public);
      _pendingReviews.add(<String, Object?>{
        'id': number,
        'number': number,
        'role': role,
        'received_at': public['received_at'],
        'ambiguities': ambiguities,
        'student_id_required': role == 'student',
        'scanner_id': public['scanner_id'],
      });
      _pendingRecords[number] = record;
      if (ambiguities.isNotEmpty) {
        final detail = ambiguities.map((item) => 'question ${item['question']}').join(', ');
        _log('Sheet $number needs review for $detail.', 'warning');
      } else if (public['scanner_id'] != null) {
        _log(
          'Scanner read student ID ${public['scanner_id']} from sheet ${number - 1}.',
          'success',
        );
      } else {
        _log('Student sheet ${number - 1} is waiting for its student ID.', 'warning');
      }
      return;
    }

    _records.add(public);
    if (output != null) {
      appendJsonl(output, record, false, extra: {'number': number, 'role': role});
    }
    _recordScan(public);
    final total = record.responses.length;
    _log(
      role == 'key'
          ? 'Captured answer key with ${public['answered_count']}/$total answered.'
          : 'Captured student sheet ${number - 1} with ${public['answered_count']}/$total answered.',
      'success',
    );
  }

  /// Finish a sheet the reader put up for review.
  void resolveReview(
    int reviewId,
    Map<String, String> resolutions,
    String studentId,
    String studentName,
  ) {
    final review = _pendingReviews.cast<Map<String, Object?>?>().firstWhere(
          (item) => item!['id'] == reviewId,
          orElse: () => null,
        );
    final record = _pendingRecords[reviewId];
    if (review == null || record == null) {
      throw const DataLinkError('That review is no longer pending');
    }

    final corrected = List<String>.of(record.responses);
    final id = studentId.trim();
    final name = studentName.trim();
    if (review['role'] == 'student' && id.isEmpty) {
      throw const DataLinkError('Enter the student ID');
    }
    if (id.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(id)) {
      throw const DataLinkError('Student ID must contain digits only');
    }
    for (final ambiguity in (review['ambiguities']! as List<Object?>).cast<Map<String, Object?>>()) {
      final question = ambiguity['question']! as int;
      final selected = resolutions['$question'];
      final allowed = <String>{
        ...(ambiguity['options']! as List<Object?>).cast<String>(),
        '',
        ambiguity['value']! as String,
      };
      if (selected == null || !allowed.contains(selected)) {
        throw DataLinkError('Choose a resolution for question $question');
      }
      corrected[question - 1] = selected;
    }

    final public = <String, Object?>{
      'number': review['number'],
      'role': review['role'],
      'received_at': record.receivedAt,
      'responses': corrected,
      'answered_count': corrected.where((value) => value.isNotEmpty).length,
      'student_id': id.isEmpty ? null : id,
      'student_name': name.isEmpty ? null : name,
      // Carried through the review, or the machine's own marking would be lost
      // on every sheet that needed one, which is every student sheet.
      'scanner_score': record.publicDict()['scanner_score'],
    };
    store.updateScan(
      _sessionId!,
      review['number']! as int,
      studentId: id,
      studentName: name,
      responses: corrected,
    );
    _records
      ..add(public)
      ..sort((a, b) => (a['number']! as int).compareTo(b['number']! as int));
    _pendingReviews.remove(review);
    _pendingRecords.remove(reviewId);
    final output = _outputFile;

    if (output != null) {
      appendJsonl(
        output,
        DataLinkFormRecord(receivedAt: record.receivedAt, fields: record.fields, responses: corrected),
        false,
        extra: {
          'number': public['number'],
          'role': public['role'],
          'student_id': public['student_id'],
          'student_name': public['student_name'],
        },
      );
    }
    final label = public['role'] == 'key'
        ? 'answer key'
        : 'student sheet ${(public['number']! as int) - 1}';
    _log('Saved reviewed $label.', 'success');
  }

  void _recordScan(Map<String, Object?> public) {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      store.addScan(sessionId, public);
    } on Object catch (error) {
      // A history write must never cost a sheet that is already in the JSONL
      // log and on screen.
      _log('Could not save sheet ${public['number']} to history: ${_message(error)}', 'error');
    }
  }

  Future<void> disconnect() async {
    if (_sessionId != null) {
      // Unplugging still ends the session, and says so the same way the End
      // session button does.
      try {
        endSession();
      } on DataLinkError {
        // Nothing to end.
      }
    }
    _stopReader = true;
    final scanner = _scanner;
    _scanner = null;
    _sessionId = null;
    _sessionName = '';
    _outputFile = null;
    _state = 'disconnected';
    _port = null;
    _error = null;
    if (scanner != null) {
      // Wait for a read in flight, so the port is not closed under it.
      await _lock.run(() async {});
      await scanner.close();
    }
    _log('Scanner disconnected.');
  }

  /// Delete sessions, their scans and their JSONL logs together.
  ({int sessions, int logs}) removeSessions(List<int> sessionIds) {
    final doomed = <File>[];
    for (final id in sessionIds) {
      final session = store.session(id);
      final path = session?['log_path'] as String?;
      if (path != null && path.isNotEmpty) doomed.add(File(path));
    }
    final removed = store.deleteSessions(sessionIds);
    var logs = 0;
    for (final file in doomed) {
      try {
        file.deleteSync();
        logs++;
      } on FileSystemException {
        // A log the user has already moved or deleted is not an error.
      }
    }
    if (removed > 0) store.vacuum();
    return (sessions: removed, logs: logs);
  }

  int? get currentSessionId => _sessionId;

  /// Empty the sheets on screen. Refused while a session runs: sheets are
  /// numbered from what is on screen, and sheet 1 is the answer key, so
  /// emptying the table mid-session sent the next sheet in as a second key on a
  /// number already used and the session could never be scored again.
  void clear() {
    if (_sessionId != null) {
      throw const DataLinkError(
        'A session is running, so the sheets on screen are the ones being '
        'recorded. End the session to start a fresh one.',
      );
    }
    _records.clear();
    _pendingReviews.clear();
    _pendingRecords.clear();
    _log('The on-screen session was cleared.');
  }

  String exportCsv([String className = '']) =>
      recordsToCsv(List.of(_records), className, _questionCount);

  /// Stop everything. Call when the app closes.
  Future<void> dispose() async {
    await disconnect();
    await _changes.close();
  }

  static String _message(Object error) => switch (error) {
        DataLinkError(:final message) => message,
        SerialException(:final message) => message,
        _ => error.toString(),
      };

  static String _fileStamp(DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = when.toLocal();
    final micros = (t.millisecond * 1000 + t.microsecond).toString().padLeft(6, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}_$micros';
  }
}

/// Append one privacy-minimal object per line to a session log.
void appendJsonl(
  File file,
  DataLinkFormRecord record,
  bool includeRawFields, {
  Map<String, Object?>? extra,
}) {
  file.parent.createSync(recursive: true);
  final payload = record.publicDict(includeRawFields: includeRawFields);
  if (extra != null) payload.addAll(extra);
  file.writeAsStringSync('${pyJsonEncode(payload, compact: true)}\n', mode: FileMode.append);
}
