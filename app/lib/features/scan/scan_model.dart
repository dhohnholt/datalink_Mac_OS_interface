import 'dart:async';

import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/foundation.dart';

import '../../app/services.dart';

/// Everything the Scan tab decides, apart from drawing it. The old page did
/// this inside `render()` and a dozen event handlers; here it is one object a
/// test can drive.
class ScanModel extends ChangeNotifier {
  ScanModel(
    this._services, {
    Duration? portPollInterval = const Duration(seconds: 2),
    this.debounce = const Duration(milliseconds: 400),
  }) {
    final settings = _services.workspace.settings();
    _testName = settings['test_name']! as String;
    final saved = int.tryParse('${settings['question_count']}');
    if (saved != null) _questionCount = saved.clamp(minAnswerCount, maxAnswerCount);
    _matching = StudentMatching.parse(settings['student_matching'] as String?);
    _subscription = _services.scanner.changes.listen((_) => _react());
    _services.classBook.addListener(notifyListeners);
    unawaited(_services.scanner.refreshPorts());
    if (portPollInterval != null) {
      _ports = Timer.periodic(portPollInterval, (_) {
        if (!snapshot.connected) unawaited(_services.scanner.refreshPorts());
      });
    }
  }

  final AppServices _services;
  final Duration debounce;

  ScannerSnapshot? _cached;
  int _cachedRevision = -1;
  StreamSubscription<ScannerSnapshot>? _subscription;
  Timer? _ports;
  Timer? _nameTimer;

  String _testName = '';
  int _questionCount = defaultAnswerCount;
  StudentMatching _matching = StudentMatching.id;
  String port = '';
  bool showProtocol = false;

  /// Where scanning each class has got to. Kept for the life of the app, as the
  /// old page kept it for the life of the window.
  final Map<String, int> _rosterIndex = {};

  int? _autoResolving;
  int? _handledReview;
  String? _rescanStudent;
  int? _rescanRecordCount;

  /// Show a short message to the teacher. Set by the screen.
  void Function(String message)? onMessage;

  /// Set when a sheet needs a human; cleared when it has been dealt with.
  ReviewPlan? pendingPlan;
  Map<String, Object?>? pendingReview;

  /// Set when the answer key has answers through question N and nothing after,
  /// while the session counts more: almost certainly the count was left at its
  /// old value. The shell asks; [useSuggestedCount] and [keepCount] answer.
  ({int suggested, int current})? countSuggestion;
  int? _countAnsweredFor;

  // ------------------------------------------------------------------ state

  /// The controller's state now. Read afresh whenever it has changed, never
  /// taken from an event: events arrive after the change that caused them, so
  /// an event can be older than state already seen.
  ScannerSnapshot get snapshot {
    final revision = _services.scanner.revision;
    if (_cached == null || revision != _cachedRevision) {
      _cached = _services.scanner.snapshot();
      _cachedRevision = revision;
    }
    return _cached!;
  }
  String get testName => _testName;
  int get questionCount => _questionCount;
  StudentMatching get matching => _matching;
  String get className => _services.classBook.selectedName;

  RosterWalk get walk => RosterWalk(
        _services.classBook.studentsOf(className),
        _rosterIndex[className] ?? 0,
      );

  bool get busy => snapshot.state == 'connecting';
  bool get scanning => snapshot.scanning;
  bool get connected => snapshot.state == 'connected';
  bool get hasKey => snapshot.records.any((r) => r['role'] == 'key');

  String get badgeLabel => switch (snapshot.state) {
        'disconnected' => 'Disconnected',
        'connecting' => 'Connecting…',
        'connected' => scanning ? 'Ready to scan' : 'Connected · no session',
        'error' => 'Needs attention',
        final other => other,
      };

  String get connectLabel => connected ? 'Start scanning session' : 'Connect and start session';
  bool get canStart => !busy && !scanning;
  bool get canEnd => scanning;
  bool get canReset => connected;
  bool get canDisconnect => snapshot.state != 'disconnected';
  bool get canClear => !scanning;
  bool get portLocked => busy || connected;
  bool get countLocked => busy || scanning;

  String get connectionDetail {
    final error = snapshot.error;
    if (error != null && error.isNotEmpty) return error;
    if (connected) {
      return scanning
          ? 'Session running on ${snapshot.port}. Feed one sheet at a time.'
          : 'Scanner ready on ${snapshot.port}. No session is running.';
    }
    return 'Connect the scanner by USB, then select its serial port.';
  }

  /// "Start a session" → "Scan the answer key first" → "Next: Ada".
  ({String step, String title, String detail}) get workflow {
    final next = walk.current;
    final roster = walk.students;
    if (!scanning) {
      return (
        step: '1',
        title: 'Start a session',
        detail: 'Name the test, pick the class, then press Start. '
            'Nothing is recorded until a session is running.',
      );
    }
    if (!hasKey) {
      return (
        step: '2',
        title: 'Scan the answer key first',
        detail: "Check the scanner's own display reads Scan Mode Ready — press Reset on the "
            'device to cycle to it — then feed the marked answer key before any student sheets.',
      );
    }
    if (_rescanStudent != null) {
      return (
        step: '↻',
        title: 'Rescan: $_rescanStudent',
        detail: 'The old scan was removed. Feed this student\'s replacement sheet now.',
      );
    }
    return (
      step: '✓',
      title: next != null
          ? 'Next: ${next.name}'
          : roster.isNotEmpty
              ? 'Roster complete'
              : 'Answer key captured',
      detail: next != null
          ? 'Roster #${next.id} · Feed ${next.name}\'s sheet now.'
          : roster.isNotEmpty
              ? 'Every student on the roster has been handled.'
              : 'The session is ready for student sheets. Feed them one at a time.',
    );
  }

  String get rosterSummary => walk.summary(className);
  bool get canSkip => scanning && hasKey && walk.current != null;
  bool get canStartAtFirst => walk.students.isNotEmpty && walk.index != 0;

  /// The newest sheet's "answered / total", or an em dash.
  String get latestAnswered {
    final records = snapshot.records;
    if (records.isEmpty) return '—';
    final latest = records.last;
    return '${latest['answered_count']} / ${(latest['responses']! as List).length}';
  }

  String get sessionLabel {
    if (!snapshot.scanning) return 'Not started';
    if (snapshot.sessionName.isNotEmpty) return snapshot.sessionName;
    final path = snapshot.outputPath;
    return path == null ? 'Running' : path.split('/').last;
  }

  /// Newest first, as the table shows them.
  List<Map<String, Object?>> get recordsNewestFirst => snapshot.records.reversed.toList();

  /// Protocol lines are hidden until asked for.
  List<ActivityEntry> get activity => [
        for (final entry in snapshot.activity)
          if (showProtocol || entry.kind != 'protocol') entry,
      ];

  String get exportFilename {
    final name = _testName.trim();
    final label = [className.trim(), name].where((p) => p.isNotEmpty).join(' - ');
    return safeExportFilename(label.isEmpty ? 'datalink-session' : label);
  }

  // ---------------------------------------------------------------- settings

  void setTestName(String value) {
    _testName = value;
    notifyListeners();
    _nameTimer?.cancel();
    // Saved a moment after typing stops, not on every keystroke.
    _nameTimer = Timer(debounce, _saveName);
  }

  void _saveName() {
    _nameTimer?.cancel();
    _nameTimer = null;
    _services.workspace.updateSettings(
      {'test_name': _testName.trim()},
      openSessionId: _services.scanner.currentSessionId,
    );
  }

  /// Clamp on the way out of the field rather than on every keystroke, so
  /// typing "100" does not fight the user after the first digit.
  void commitQuestionCount(String text) {
    final parsed = int.tryParse(text.trim());
    final clamped = parsed == null ? defaultAnswerCount : parsed.clamp(minAnswerCount, maxAnswerCount);
    if (parsed != clamped) {
      onMessage?.call('Questions per form must be between $minAnswerCount and $maxAnswerCount');
    }
    _questionCount = clamped;
    _services.workspace.updateSettings({'question_count': '$clamped'});
    notifyListeners();
  }

  void setMatching(StudentMatching value) {
    _matching = value;
    _services.workspace.updateSettings({'student_matching': value.name});
    onMessage?.call(switch (value) {
      StudentMatching.id => 'Sheets can be fed in any order',
      StudentMatching.roster => 'Sheets are taken in roster order',
      StudentMatching.manual => 'Every sheet will ask',
    });
    notifyListeners();
  }

  void selectClass(String name) {
    _services.classBook.select(name);
    onMessage?.call(name.isEmpty ? 'Roster turned off' : 'Scanning against $name');
    notifyListeners();
  }

  void toggleProtocol() {
    showProtocol = !showProtocol;
    notifyListeners();
  }

  // ----------------------------------------------------------------- actions

  /// One press for the common case: bring the scanner up if it is not up
  /// already, then open the session on top of it.
  Future<void> start() async {
    // A session takes the name saved at the moment it starts, so a name typed
    // a moment ago must be saved first, not left waiting on the debounce.
    if (_nameTimer?.isActive ?? false) _saveName();
    try {
      if (!connected) {
        await _services.scanner.connect(port.isEmpty ? null : port, _questionCount);
      }
      _rosterIndex[className] = 0;
      // The explicit action re-sends the handshake first: a DataLink can keep a
      // pending second-side prompt after an interrupted key, and this clears it.
      await _services.scanner.startSession(questionCount: _questionCount, resetScanner: true);
      onMessage?.call('Session started · feed the answer key first');
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
    } on SerialException catch (error) {
      onMessage?.call(error.message);
    } finally {
      _sync();
    }
  }

  SessionSummary? end() {
    try {
      final summary = _services.scanner.endSession();
      onMessage?.call(summary.message);
      return summary;
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
      return null;
    } finally {
      _sync();
    }
  }

  Future<void> resetScanner() async {
    try {
      await _services.scanner.resetScanner();
      onMessage?.call('Handshake re-sent · for a held sheet, press Reset on the device');
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
    } on SerialException catch (error) {
      onMessage?.call(error.message);
    } finally {
      _sync();
    }
  }

  Future<void> disconnect() async {
    await _services.scanner.disconnect();
    _sync();
  }

  void clearView() {
    try {
      _services.scanner.clear();
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
    } finally {
      _sync();
    }
  }

  bool removeStudentScan(Map<String, Object?> record) {
    try {
      _services.scanner.removeStudentScan(record['number']! as int);
      onMessage?.call('Bad scan removed');
      return true;
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
      return false;
    } finally {
      _sync();
    }
  }

  bool rescanStudent(Map<String, Object?> record) {
    final id = (record['student_id'] as String?) ?? '';
    final name = (record['student_name'] as String?) ?? '';
    if (!removeStudentScan(record)) return false;
    if (_matching == StudentMatching.roster) {
      final index = walk.indexForId(id);
      if (index >= 0) _rosterIndex[className] = index;
    }
    final student = name.trim().isNotEmpty ? name.trim() : (id.trim().isNotEmpty ? 'ID ${id.trim()}' : 'the student');
    _rescanStudent = student;
    _rescanRecordCount = snapshot.recordCount;
    onMessage?.call('Feed $student\'s sheet again');
    notifyListeners();
    return true;
  }

  void skipStudent() {
    final w = walk;
    final skipped = w.current;
    if (skipped == null) return;
    w.advance();
    _rosterIndex[className] = w.index;
    onMessage?.call('Skipped ${skipped.name}');
    notifyListeners();
  }

  void startAtFirst() {
    _rosterIndex[className] = 0;
    notifyListeners();
  }

  /// The CSV for the sheets on screen and the name to offer it under.
  ({String filename, String csv}) exportCsv() =>
      (filename: exportFilename, csv: _services.scanner.exportCsv(className));

  // ---------------------------------------------------------------- reviewing

  /// Read the controller's state now rather than waiting for its next event,
  /// so what the screen shows is never a step behind the action just taken.
  void _sync() => _react();

  void _react() {
    _checkCount();
    if (_rescanStudent != null && (_rescanRecordCount == null || snapshot.recordCount > _rescanRecordCount!)) {
      _rescanStudent = null;
      _rescanRecordCount = null;
    }
    if (!snapshot.scanning) {
      _rescanStudent = null;
      _rescanRecordCount = null;
    }
    final review = snapshot.pendingReview;
    if (review == null) {
      pendingPlan = null;
      pendingReview = null;
      _autoResolving = null;
      _handledReview = null;
    } else if (review['id'] != _handledReview) {
      _handledReview = review['id'] as int?;
      final plan = planReview(
        review: review,
        roster: walk,
        matching: _matching,
        className: className,
      );
      if (plan.autoSave) {
        _autoSave(review, plan);
      } else {
        pendingReview = review;
        pendingPlan = plan;
      }
    }
    notifyListeners();
  }

  /// Looks at the key once it is captured, which is the earliest the mistake
  /// can be seen: before any student sheet, when changing the count costs
  /// nothing. Asked once per session; "keep" is an answer too.
  void _checkCount() {
    final snap = snapshot;
    final session = snap.sessionId;
    if (session == null) {
      countSuggestion = null;
      _countAnsweredFor = null;
      return;
    }
    if (_countAnsweredFor == session || countSuggestion != null || snap.pendingReview != null) return;
    final keys = snap.records.where((record) => record['role'] == 'key');
    if (keys.isEmpty) return;
    final suggested = questionCountFromKey(
      [for (final r in keys.first['responses']! as List) '$r'],
      snap.questionCount,
    );
    if (suggested != null) countSuggestion = (suggested: suggested, current: snap.questionCount);
  }

  /// "Use 30 questions".
  void useSuggestedCount() {
    final suggestion = countSuggestion;
    if (suggestion == null) return;
    countSuggestion = null;
    _countAnsweredFor = snapshot.sessionId;
    try {
      _services.scanner.changeQuestionCount(suggestion.suggested);
      _questionCount = suggestion.suggested;
      _services.workspace.updateSettings({'question_count': '${suggestion.suggested}'});
      onMessage?.call('Scoring out of ${suggestion.suggested} questions');
    } on DataLinkError catch (error) {
      onMessage?.call(error.message);
    }
    _sync();
  }

  /// "Keep 50 questions": the count was meant, so do not ask again this session.
  void keepCount() {
    countSuggestion = null;
    _countAnsweredFor = snapshot.sessionId;
    notifyListeners();
  }

  void _autoSave(Map<String, Object?> review, ReviewPlan plan) {
    final id = review['id']! as int;
    if (_autoResolving == id) return;
    _autoResolving = id;
    final scannerId = review['scanner_id']! as String;
    try {
      _services.scanner.resolveReview(id, const {}, scannerId, plan.studentName);
      if (plan.matchIndex >= 0) {
        _rosterIndex[className] = plan.matchIndex + 1;
      }
      onMessage?.call(
        plan.studentName.isNotEmpty
            ? 'Captured ${plan.studentName} · $scannerId'
            : 'Captured ID $scannerId',
      );
    } on DataLinkError catch (error) {
      _autoResolving = null;
      onMessage?.call(error.message);
    }
  }

  /// Finish the sheet the dialog is showing. Returns an error to show, or null
  /// when it was saved and the dialog can close.
  String? resolve(Map<String, String> resolutions, String studentId, String studentName) {
    final review = pendingReview;
    final plan = pendingPlan;
    if (review == null || plan == null) return null;
    try {
      _services.scanner.resolveReview(review['id']! as int, resolutions, studentId, studentName);
    } on DataLinkError catch (error) {
      return error.message;
    }
    if (plan.needsStudentId && walk.students.isNotEmpty) {
      // Carry on after the student actually chosen, who need not be the one
      // the screen expected when sheets are fed out of order.
      final chosen = walk.indexForId(studentId);
      final from = chosen >= 0 ? chosen : plan.matchIndex;
      if (from >= 0) _rosterIndex[className] = from + 1;
    }
    _sync();
    return null;
  }

  @override
  void dispose() {
    _nameTimer?.cancel();
    _ports?.cancel();
    unawaited(_subscription?.cancel());
    _services.classBook.removeListener(notifyListeners);
    super.dispose();
  }
}
