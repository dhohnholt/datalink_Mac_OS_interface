/// Item analysis over a saved session, in the website's JSON contract. A port
/// of `src/datalink_scanner/analysis.py`: it turns stored scans into the
/// structures the scoring code expects, then calls it.
library;

import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../protocol/py_json.dart';
import '../protocol/py_math.dart';
import '../protocol/python_compat.dart';
import 'result_schema.dart';
import 'scoring.dart';
import 'test_package.dart';

const List<int> defaultFlagThresholds = [25, 40, 50];

/// A mark this faint is scored as an answer but is worth a second look.
/// Across 17 real batches a properly filled bubble sits at 0.29.
const double faintMarkThreshold = 0.10;

/// A mark is only suspicious when it is faint *for that sheet*: much lighter
/// than the same student's other answers.
const double faintRelativeShare = 0.6;

/// A sheet that is faint all the way through gets one note, not one per mark.
const double faintSheetShare = 0.25;

const String validAnswerLetters = 'ABCDE';

class AnalysisError implements Exception {
  const AnalysisError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A stored session row, as far as analysis needs it.
typedef SessionRow = Map<String, Object?>;

/// A stored scan row.
typedef ScanRow = Map<String, Object?>;

/// One stable name for a review item, so a decision about it can be kept.
/// Page, what is wrong, which question, and the reason: settling one reason
/// for an answer is not settling another.
String reviewKey(Map<String, Object?> item) => [
      item['page'],
      item['field'],
      _truthy(item['question']) ? item['question'] : 0,
      item['reason'] ?? '',
    ].map(_str).join(':');

String _str(Object? value) => value == null ? 'None' : value.toString();

bool _truthy(Object? value) =>
    value != null && value != 0 && value != '' && value != false;

String normalizeResponse(Object? value) {
  final text = pyStrip(value == null ? '' : value.toString()).toUpperCase();
  if (text.isEmpty) return 'BLANK';
  if (text.length == 1 && validAnswerLetters.contains(text)) return text;
  if (text == '*' || text.codeUnits.every((u) => validAnswerLetters.contains(String.fromCharCode(u)))) {
    return 'MULTIPLE';
  }
  throw AnalysisError('Unsupported response value ${pyRepr(text)}');
}

/// The letters behind each combined reading such as AC, sorted. A key
/// bubbled this way is a multiple-answer question; a student's are compared
/// with it. `*` carries no letters and has no entry.
Map<int, String> _marks(ScanRow scan, int questionCount) {
  final responses = List<Object?>.from((scan['responses'] as List?) ?? const []);
  final found = <int, String>{};
  for (var number = 1; number <= math.min(questionCount, responses.length); number++) {
    final value = responses[number - 1];
    final text = pyStrip(value == null ? '' : value.toString()).toUpperCase();
    if (text.length > 1 && text.split('').every(validAnswerLetters.contains)) {
      found[number] = (text.split('').toSet().toList()..sort()).join();
    }
  }
  return found;
}

Map<int, String> _answers(ScanRow scan, int questionCount) {
  final responses = List<Object?>.from((scan['responses'] as List?) ?? const []);
  return {
    for (var number = 1; number <= questionCount; number++)
      number: normalizeResponse(number <= responses.length ? responses[number - 1] : ''),
  };
}

/// Identify the inputs a score was computed from.
///
/// A retry of one upload must keep its run id; a re-score after a corrected
/// student ID or answer key is a new audit record and must not. Hashing what
/// actually went into the score tells the two apart.
String scanFingerprint(SessionRow session, List<ScanRow> scans) {
  final ordered = _stableSorted(scans, (scan) => _orZero(scan['number']));
  final material = pyJsonEncode(
    <String, Object?>{
      'questions': session['question_count'],
      'scans': [
        for (final scan in ordered)
          [
            scan['number'],
            scan['role'],
            scan['student_id'],
            scan['student_name'],
            List<Object?>.from((scan['responses'] as List?) ?? const []),
          ],
      ],
    },
    sortKeys: true,
  );
  return sha256.convert(_utf8(material)).toString();
}

List<int> _utf8(String text) {
  // The encoder escapes everything outside ASCII, so the text is ASCII.
  return text.codeUnits;
}

int _orZero(Object? value) => value is int ? value : 0;

List<T> _stableSorted<T>(List<T> items, num Function(T) key) {
  final indexed = List<int>.generate(items.length, (i) => i)
    ..sort((a, b) {
      final by = key(items[a]).compareTo(key(items[b]));
      return by != 0 ? by : a.compareTo(b);
    });
  return [for (final i in indexed) items[i]];
}

/// Score one session and return the upload payload.
///
/// [dismissed] names review items the teacher has already settled. They are
/// left out of the report entirely, so the count on screen and the warnings
/// sent to the website agree with what was decided.
/// A response as stored on a sheet, read for a package session: a letter,
/// `BLANK`, `MULTIPLE` when the letters are unknown, or the letters of a
/// double mark.
String _packageResponse(Object? value) {
  final text = pyStrip(value == null ? '' : value.toString()).toUpperCase();
  if (text.isEmpty) return 'BLANK';
  if (text == '*') return 'MULTIPLE';
  // Matching on the printable sheets runs to O.
  if (text.split('').every((c) => 'ABCDEFGHIJKLMNO'.contains(c))) {
    return (text.split('').toSet().toList()..sort()).join();
  }
  throw AnalysisError('Unsupported response value ${pyRepr(text)}');
}

PackageSheet _packageSheet(ScanRow scan) {
  final responses = List<Object?>.from((scan['responses'] as List?) ?? const []);
  final confidence = <int, Object?>{};
  final stored = scan['confidence'];
  if (stored is Map) {
    for (final entry in stored.entries) {
      confidence[int.parse(entry.key.toString())] = entry.value;
    }
  }
  final id = pyStrip((scan['student_id'] as String?) ?? '');
  final name = pyStrip((scan['student_name'] as String?) ?? '');
  return PackageSheet(
    page: _orZero(scan['number']),
    version: scan['version'] as String?,
    responses: {for (var q = 1; q <= responses.length; q++) q: _packageResponse(responses[q - 1])},
    studentId: id.isEmpty ? null : id,
    studentName: name.isEmpty ? null : name,
    confidence: confidence,
  );
}

Map<String, Object?> _packageAnalysis(
  TestPackage package,
  SessionRow session,
  List<ScanRow> scans,
  String runId,
  DateTime createdAt,
  String? examName,
  List<int> flagThresholds,
  Set<String> dismissed,
) {
  try {
    return buildPackageAnalysis(
      package: package,
      keySheets: [for (final scan in scans) if (scan['role'] == 'key') _packageSheet(scan)],
      sheets: [for (final scan in scans) if (scan['role'] != 'key') _packageSheet(scan)],
      examName: examName ?? ((session['name'] as String?)?.isNotEmpty == true ? session['name']! as String : 'Paper scan'),
      sourceFile: '${session['name'] ?? 'session'}.pdf',
      runId: runId,
      createdAt: pyIsoUtc(createdAt),
      flagThresholds: flagThresholds,
      dismissed: dismissed,
      reviewKeyOf: reviewKey,
    );
  } on TestPackageException catch (error) {
    throw AnalysisError(error.message);
  }
}

Map<String, Object?> buildSessionAnalysis(
  SessionRow session,
  List<ScanRow> scans, {
  required String runId,
  required DateTime createdAt,
  String? examName,
  List<int> flagThresholds = defaultFlagThresholds,
  Set<String> dismissed = const {},
}) {
  final questionCount = _orZero(session['question_count']);
  if (questionCount < 1) {
    throw const AnalysisError('This session has no question count recorded');
  }

  final package = packageOf(session);
  if (package != null) {
    return _packageAnalysis(package, session, scans, runId, createdAt, examName, flagThresholds, dismissed);
  }

  final keys = [for (final scan in scans) if (scan['role'] == 'key') scan];
  final students = [for (final scan in scans) if (scan['role'] != 'key') scan];
  if (keys.length != 1) {
    throw AnalysisError(
      'Scoring needs exactly one answer key in the session; this one has ${keys.length}',
    );
  }
  if (students.isEmpty) {
    throw const AnalysisError('This session has no student sheets to score');
  }

  final answerKey = {..._answers(keys.first, questionCount), ..._marks(keys.first, questionCount)};
  final validation = validateAnswerKey(answerKey, questionCount);
  if (!validation.valid) {
    final unresolvedQuestions = <int>{...validation.missing, ...validation.invalid.keys}.toList()
      ..sort();
    throw AnalysisError(
      'The answer key still has blank or multiple marks on question(s) '
      '${unresolvedQuestions.join(', ')}',
    );
  }

  // Keyed by scan number, the way the CSV importer keys by its Scan column.
  final parsed = <int, ParsedSheet>{};
  var fallback = 2;
  for (final scan in students) {
    var number = _truthy(scan['number']) ? _orZero(scan['number']) : fallback;
    fallback++;
    while (parsed.containsKey(number)) {
      number++;
    }
    final confidence = <int, Object?>{};
    final stored = scan['confidence'];
    if (stored is Map) {
      for (final entry in stored.entries) {
        confidence[int.parse(entry.key.toString())] = entry.value;
      }
    }
    final id = pyStrip((scan['student_id'] as String?) ?? '');
    final name = pyStrip((scan['student_name'] as String?) ?? '');
    parsed[number] = ParsedSheet(
      studentId: id.isEmpty ? null : id,
      studentName: name.isEmpty ? null : name,
      answers: _answers(scan, questionCount),
      marks: _marks(scan, questionCount),
      scannerScore: scan['scanner_score'] is int ? scan['scanner_score']! as int : null,
      answerConfidence: confidence,
    );
  }

  final scores = <int, Map<String, Object?>>{
    for (final entry in parsed.entries)
      entry.key: <String, Object?>{
        'student_id': entry.value.studentId,
        ...scoreStudent(entry.value.answers, answerKey, questionCount, entry.value.marks),
      },
  };
  final analysis = itemAnalysis(
    [for (final row in parsed.values) row.answers],
    answerKey,
    questionCount: questionCount,
    flagThresholds: flagThresholds,
    allMarks: [for (final row in parsed.values) row.marks],
  );
  final stats = classStatistics(scores, analysis, questionCount);

  var reviewItems = <Map<String, Object?>>[];
  for (final entry in parsed.entries) {
    final number = entry.key;
    final row = entry.value;
    final id = row.studentId;
    if (id == null || !pyIsDigit(id)) {
      reviewItems.add({'page': number, 'field': 'student_id', 'value': null});
    }
    for (final answer in row.answers.entries) {
      // Several marks are the expected answer to a multiple-answer
      // question, not something to check.
      if (answer.value == 'MULTIPLE' && answerKey[answer.key]!.length == 1) {
        reviewItems.add({
          'page': number,
          'field': 'answer',
          'question': answer.key,
          'value': answer.value,
          'reason': 'multiple',
        });
      }
    }
    reviewItems.addAll(faintMarks(number, row));
  }
  reviewItems.addAll(
    disagreements(
      parsed,
      scores,
      keys.first['scanner_score'],
      questionCount,
    ),
  );

  for (final scan in students) {
    if (_truthy(scan['pending_review'])) {
      reviewItems.add({
        'page': scan['number'],
        'field': 'sheet',
        'reason': 'pending_review',
      });
    }
  }

  if (dismissed.isNotEmpty) {
    reviewItems = [
      for (final item in reviewItems)
        if (!dismissed.contains(reviewKey(item))) item,
    ];
  }

  final keyNumber = _truthy(keys.first['number']) ? _orZero(keys.first['number']) : 1;
  final sessionName = session['name'];
  final sourceName = _truthy(session['log_path'])
      ? session['log_path']! as String
      : '${_truthy(sessionName) ? sessionName : 'session'}.jsonl';

  return buildAnalysisResult(
    pdfPath: sourceName,
    examName: (examName != null && examName.isNotEmpty)
        ? examName
        : (_truthy(sessionName) ? sessionName as String : null),
    keyPage: keyNumber,
    selectedPages: {keyNumber, ...parsed.keys},
    processedPages: [keyNumber, ...parsed.keys],
    skippedBlank: const [],
    skippedUnsupported: const [],
    answerKey: answerKey,
    students: parsed,
    scores: scores,
    analysis: analysis,
    stats: stats,
    reviewItems: reviewItems,
    appliedCorrections: const [],
    flagThresholds: flagThresholds,
    runId: runId,
    createdAt: createdAt,
    scanStudentIds: true,
    questionCount: questionCount,
    // Scans read off the scanner report the same value the CSV importer emits;
    // a batch read from a PDF says so instead.
    sourceType: session['source'] == 'paper' ? 'pdf_scan' : 'datalink_csv',
  );
}

/// Where the scanner's own marking and ours do not agree.
///
/// The DataLink marks every sheet against a key held inside it and sends the
/// result in the record. That is a second opinion from different hardware
/// reading the same bubbles. Two cases are ruled out first, or this produces
/// only noise: a device with no key (every sheet reads zero), and a device
/// holding a different key from the one just fed.
List<Map<String, Object?>> disagreements(
  Map<int, ParsedSheet> parsed,
  Map<int, Map<String, Object?>> scores,
  Object? keyScannerScore,
  int questionCount,
) {
  final marked = <int, int>{
    for (final entry in parsed.entries)
      if (entry.value.scannerScore != null) entry.key: entry.value.scannerScore!,
  };
  if (marked.isEmpty) return const [];
  if (!marked.values.any((value) => value != 0)) return const [];

  if (keyScannerScore is int && keyScannerScore != questionCount) {
    return [
      {
        'page': 0,
        'field': 'session',
        'reason': 'stale_device_key',
        'value': keyScannerScore,
        'question_count': questionCount,
      },
    ];
  }

  final items = <Map<String, Object?>>[];
  for (final number in (marked.keys.toList()..sort())) {
    final scannerScore = marked[number]!;
    final ours = scores[number]?['correct'] as int?;
    if (ours == null || scannerScore == ours) continue;
    items.add({
      'page': number,
      'field': 'sheet',
      'reason': 'score_disagreement',
      'value': scannerScore,
      'ours': ours,
    });
  }
  return items;
}

/// Marks on one sheet that are much lighter than the rest of that sheet.
List<Map<String, Object?>> faintMarks(int number, ParsedSheet row) {
  // Kept as stored (an int stays an int) because the value is written back out.
  final strengths = <int, num>{};
  for (final entry in row.answers.entries) {
    if (entry.value == 'BLANK' || entry.value == 'MULTIPLE') continue;
    final confidence = row.answerConfidence[entry.key];
    if (confidence is Map && confidence['mark_strength'] != null) {
      strengths[entry.key] = confidence['mark_strength']! as num;
    }
  }
  if (strengths.isEmpty) return const [];

  final ordered = strengths.values.map((v) => v.toDouble()).toList()..sort();
  final middle = ordered.length ~/ 2;
  final typical = ordered.length.isOdd
      ? ordered[middle]
      : (ordered[middle - 1] + ordered[middle]) / 2;

  final faint = [
    for (final entry in strengths.entries)
      if (entry.value < faintMarkThreshold) entry.key,
  ];
  final limit = strengths.length * faintSheetShare;
  if (faint.length >= (limit > 1 ? limit : 1)) {
    // The whole sheet reads faint. One note about the sheet is useful; one per
    // question is a wall of noise about a student's pencil.
    return [
      {
        'page': number,
        'field': 'sheet',
        'reason': 'faint_sheet',
        'value': faint.length,
        'mark_strength': pyRound(typical, 4),
      },
    ];
  }

  return [
    for (final question in (faint..sort()))
      if (strengths[question]! < typical * faintRelativeShare)
        {
          'page': number,
          'field': 'answer',
          'question': question,
          'value': row.answers[question],
          'reason': 'faint',
          'mark_strength': strengths[question],
        },
  ];
}

/// A random (version 4) UUID, for the id of one scoring run.
String newRunId([math.Random? random]) {
  final rng = random ?? math.Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// `analysis_filename`: the export name with `.json` for `.csv`.
String analysisFilename(SessionRow session, String Function(String) safeName) {
  final name = safeName((session['name'] as String?) ?? '');
  return name.endsWith('.csv')
      ? '${name.substring(0, name.length - 4)}.json'
      : '$name.json';
}
