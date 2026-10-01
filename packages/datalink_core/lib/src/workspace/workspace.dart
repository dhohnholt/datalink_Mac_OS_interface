/// The session-level operations the Python app kept inside its HTTP handlers:
/// scoring with run-id reuse, validated corrections, review settling, exports.
/// The screens call these directly; the return shapes match the JSON the old
/// endpoints returned, so the behaviour documented in the port plan carries over.
library;

import 'dart:io';
import 'dart:typed_data';

import '../analysis/analysis.dart';
import '../analysis/csv_export.dart';
import '../paper/page_cache.dart';
import '../protocol/errors.dart';
import '../protocol/py_json.dart';
import '../protocol/python_compat.dart';
import '../store/store.dart';

/// A session (or other thing) that is not there. Screens show [message].
class NotFoundError implements Exception {
  const NotFoundError([this.message = 'No such session']);

  final String message;

  @override
  String toString() => message;
}

class Workspace {
  Workspace({
    required this.store,
    DateTime Function()? now,
    String Function()? newId,
  })  : _now = now ?? DateTime.now,
        _newId = newId ?? newRunId;

  final Store store;
  final DateTime Function() _now;
  final String Function() _newId;

  Map<String, Object?> _require(int sessionId) =>
      store.session(sessionId) ?? (throw const NotFoundError());

  /// The stored picture of one sheet of a paper session, for reading a name
  /// off the paper while correcting it. Null when it is not in the cache (any
  /// more).
  Uint8List? sessionPage(int sessionId, int page) {
    final cache = store.session(sessionId)?['page_cache'];
    if (cache is! String || cache.isEmpty) return null;
    return readPagePicture(cache, page);
  }

  bool _hasPages(Object? cache) =>
      cache is String && cache.isNotEmpty && Directory(cache).existsSync();

  /// Score a session, reusing the run id while its inputs are unchanged.
  ///
  /// A retry has to land on the same audit record; a re-score after a
  /// corrected ID or answer key has to be a new one.
  ({Map<String, Object?> session, Map<String, Object?> report}) scoredSession(int sessionId) {
    var session = _require(sessionId);
    // A roster imported or corrected after a batch was filed still names its
    // students. This runs before the fingerprint is taken, so the name is part
    // of what is hashed: a session uploaded before it had names and re-uploaded
    // after gets a new run id, which is correct, because the payload did change.
    store.nameMissingStudents(sessionId);
    session = _require(sessionId);
    final scans = store.sessionScans(sessionId);
    final fingerprint = scanFingerprint(session, scans);
    String? runId = session['analysis_run_id'] as String?;
    if (runId == null || runId.isEmpty || session['analysis_fingerprint'] != fingerprint) {
      runId = null;
    }
    final report = buildSessionAnalysis(
      session,
      scans,
      runId: runId ?? _newId(),
      createdAt: _now(),
      dismissed: store.dismissedReviews(sessionId),
    );
    if (runId != report['run_id']) {
      store.rememberRunId(sessionId, report['run_id']! as String, fingerprint);
    }
    return (session: session, report: report);
  }

  /// A saved session with its sheets, for the detail view.
  Map<String, Object?> sessionDetail(int sessionId) {
    final session = _require(sessionId);
    store.nameMissingStudents(sessionId);
    final scans = store.sessionScans(sessionId);
    final detail = Map<String, Object?>.from(session)..['scans'] = scans;
    // The screen only needs to know whether a sheet can be looked at, not
    // where on disk it lives.
    final cache = detail.remove('page_cache');
    detail['has_pages'] = _hasPages(cache);
    try {
      buildSessionAnalysis(
        session,
        scans,
        runId: _newId(),
        createdAt: _now(),
        dismissed: store.dismissedReviews(sessionId),
      );
      detail['analysis_available'] = true;
      detail['analysis_error'] = null;
    } on AnalysisError catch (error) {
      detail['analysis_available'] = false;
      detail['analysis_error'] = error.message;
    }
    return detail;
  }

  /// The report for the Analysis screen. Throws [AnalysisError] when the
  /// session cannot be scored.
  Map<String, Object?> analysisReport(int sessionId) {
    final scored = scoredSession(sessionId);
    final report = Map<String, Object?>.from(scored.report);
    // Only on the inline report the Review tab reads. The downloadable one and
    // the upload keep the schema the website expects.
    report['has_pages'] = _hasPages(scored.session['page_cache']);
    // Which roster this test was scanned against, so a corrected ID can pull
    // the right name: the session's class, not whichever one is selected now.
    report['class_name'] = (scored.session['class_name'] as String?) ?? '';
    report['dismissed_count'] = store.dismissedReviews(sessionId).length;
    return report;
  }

  /// The downloadable item analysis: pretty-printed JSON and a filename.
  ({String filename, String json}) analysisDownload(int sessionId) {
    final scored = scoredSession(sessionId);
    return (
      filename: analysisFilename(scored.session, safeExportFilename),
      json: pyJsonEncode(scored.report, indent: 2),
    );
  }

  /// A saved session as CSV, with the filename to offer.
  ({String filename, String csv}) sessionCsv(int sessionId) {
    final session = _require(sessionId);
    store.nameMissingStudents(sessionId);
    return (
      filename: safeExportFilename((session['name'] as String?) ?? ''),
      csv: recordsToCsv(
        store.sessionScans(sessionId),
        (session['class_name'] as String?) ?? '',
        session['question_count']! as int,
      ),
    );
  }

  /// Settle review items. Doing it twice is not an error.
  int dismissReviews(int sessionId, List<String> items) {
    _require(sessionId);
    return store.dismissReviews(sessionId, items);
  }

  /// Bring every settled item back for another look.
  int restoreReviews(int sessionId) {
    _require(sessionId);
    return store.restoreReviews(sessionId);
  }

  /// Apply a batch of corrections and review decisions, then rescore.
  ///
  /// Each correction is `{number, student_id?, student_name?, responses?}`.
  /// Responses may use `BLANK` and `MULTIPLE` for `""` and `*`.
  Map<String, Object?> correct(
    int sessionId,
    List<Map<String, Object?>> corrections, {
    List<String> dismiss = const [],
  }) {
    final session = _require(sessionId);
    if (corrections.isEmpty && dismiss.isEmpty) {
      throw const DataLinkError('No corrections were supplied');
    }
    final validated = <Map<String, Object?>>[];
    for (final correction in corrections) {
      final number = _toInt(correction['number']) ?? 0;
      List<String>? responses;
      final given = correction['responses'];
      if (given != null) {
        responses = [
          for (final value in (given as List<Object?>))
            switch (pyStrip(value.toString()).toUpperCase()) {
              'BLANK' => '',
              'MULTIPLE' => '*',
              final other => other,
            },
        ];
        final expected = session['question_count']! as int;
        if (responses.length != expected) {
          throw DataLinkError('Sheet $number needs exactly $expected responses');
        }
        for (final value in responses) {
          if (value.isNotEmpty &&
              value != '*' &&
              !value.split('').every((letter) => validAnswerLetters.contains(letter))) {
            throw DataLinkError('${pyRepr(value)} is not a valid response');
          }
        }
      }
      String? studentId;
      if (correction['student_id'] != null) {
        studentId = pyStrip(correction['student_id'].toString());
        if (studentId.isNotEmpty && !pyIsDigit(studentId)) {
          throw const DataLinkError('Student ID must contain digits only');
        }
      }
      final name = correction['student_name'];
      validated.add({
        'number': number,
        'student_id': studentId,
        'student_name': name == null ? null : pyStrip(name.toString()),
        'responses': responses,
      });
    }

    final (applied, settled) = store.applyCorrections(sessionId, validated, dismiss);
    // A corrected ID may be one the roster can name.
    store.nameMissingStudents(sessionId);
    final scans = store.sessionScans(sessionId);
    final payload = <String, Object?>{'applied': applied, 'dismissed': settled};
    try {
      payload['analysis'] = buildSessionAnalysis(
        session,
        scans,
        runId: _newId(),
        createdAt: _now(),
        dismissed: store.dismissedReviews(sessionId),
      );
    } on AnalysisError catch (error) {
      payload['analysis'] = null;
      payload['analysis_error'] = error.message;
    }
    return payload;
  }

  // ---------------------------------------------------------------- settings

  static const List<String> _textSettings = [
    'test_name',
    'selected_class',
    'question_count',
    'student_matching',
  ];

  /// The settings the Scan screen needs, with the same defaults as before.
  Map<String, Object?> settings() => {
        'test_name': store.getSetting('test_name'),
        'selected_class': store.getSetting('selected_class'),
        'question_count': store.getSetting('question_count'),
        'student_matching': store.getSetting('student_matching', 'id'),
      };

  /// Save any of the plain settings present in [values]. Renaming the test or
  /// class keeps an open history row in step, via [openSessionId].
  void updateSettings(Map<String, Object?> values, {int? openSessionId}) {
    for (final key in _textSettings) {
      if (values.containsKey(key)) store.setSetting(key, values[key].toString());
    }
    if (openSessionId != null) {
      store.updateSession(
        openSessionId,
        name: values.containsKey('test_name') ? values['test_name'].toString() : null,
        className:
            values.containsKey('selected_class') ? values['selected_class'].toString() : null,
      );
    }
  }

  // ---------------------------------------------------------------- sessions

  void renameSession(int sessionId, String name) =>
      store.updateSession(sessionId, name: name);

  /// Sessions older than [days], for the "delete old sessions" preview.
  List<Map<String, Object?>> sessionsOlderThan(int days) => store.sessionsOlderThan(days);

  static int? _toInt(Object? value) {
    if (value is int) return value;
    return pyInt(value);
  }
}
