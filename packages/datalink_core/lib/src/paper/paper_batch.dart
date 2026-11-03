/// Reading a PDF batch of answer sheets and filing it as a session. A port of
/// `paper.py` and the driver half of `vendor/omr/analyze_exam.py`.
///
/// Once the sheets are read, the result is an ordinary session: Sessions,
/// Review, Answer key, Item analysis and Send to T-TESS cannot tell it from a
/// DataLink capture.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/analysis.dart';
import '../analysis/question_count.dart';
import '../analysis/result_schema.dart';
import '../analysis/scoring.dart';
import '../analysis/test_package.dart';
import '../protocol/py_json.dart';
import '../protocol/python_compat.dart';
import '../store/store.dart';
import 'gray_image.dart';
import 'omr/answer_sheet_75.dart';
import 'omr/key_decides_sheets.dart';
import 'omr/omr.dart';
import 'page_cache.dart';
import 'page_selection.dart';
import 'pdf/pdf_document.dart';
import 'pdf/pdf_scan.dart';

/// The most questions any supported form holds: the printable sheet. The
/// AccuScan form holds [accuScanQuestions].
const int maxQuestions = customQuestionCount;
const int accuScanQuestions = accuScanQuestionCount;

/// The versions the printable sheet can be bubbled with.
const String sheetVersions = customVersions;

/// A failure worth showing the teacher, in their words.
class PaperException implements Exception {
  const PaperException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The key sheet could not be read cleanly. Recoverable: [review] says which
/// page it was on and, for each question it could not settle, what it saw, so
/// the teacher can supply those answers and the batch can be read again.
class AnswerKeyException extends PaperException {
  const AnswerKeyException(super.message, this.review);

  /// `{key_page, unresolved: {question: seen}, pages}`.
  final Map<String, Object?> review;
}

/// The key sheet has answers through question [suggested] and nothing after,
/// while the batch was set to [current] questions. Almost certainly the count
/// was left at its old value. Recoverable: read again with [suggested], or say
/// to keep [current] and read anyway.
class QuestionCountException extends PaperException {
  const QuestionCountException(super.message, this.suggested, this.current, this.keyPage);

  final int suggested;
  final int current;
  final int keyPage;
}

/// The page count of a PDF, for the "key page" field.
int pdfPageCount(Uint8List bytes) {
  try {
    return PdfDocument.open(bytes).pageCount;
  } on PdfException catch (error) {
    throw PaperException('Could not inspect the PDF: ${error.message}');
  }
}

class PaperRequest {
  const PaperRequest({
    required this.pdf,
    this.keyPage,
    this.version,
    this.questionCount = accuScanQuestions,
    this.pages = 'all',
    this.skipPages = '',
    this.examName,
    this.keyOverrides = const {},
    this.scanStudentIds = true,
    this.checkQuestionCount = true,
    this.package,
    this.savedKey,
  });

  final File pdf;

  /// The page holding the key, or null to use the printable sheet whose
  /// ANSWER KEY bubble is filled.
  final int? keyPage;

  /// Score only printable sheets bubbled with this version (1-4), against the
  /// key bubbled with it. Needed when one PDF holds keys for several.
  final String? version;
  final int questionCount;
  final String pages;
  final String skipPages;
  final String? examName;

  /// Question -> the answer the teacher says the key sheet carries.
  final Map<int, String> keyOverrides;
  final bool scanStudentIds;

  /// Look at the key sheet first and stop with a [QuestionCountException] if it
  /// holds fewer answers than [questionCount]. Turned off once the teacher has
  /// said the count is right.
  final bool checkQuestionCount;

  /// Score every version of the test in one session. The key page, version
  /// and question count are then not used.
  final TestPackage? package;

  /// The existing session’s key. Pages without an ANSWER KEY mark are students.
  final List<String>? savedKey;
}

/// Progress for the page: a fraction from 0 to 1 and a line of words.
typedef PaperProgress = void Function(double fraction, String message);

// ------------------------------------------------------------------ workers

class _WorkerStart {
  const _WorkerStart(this.reply, this.pdf, this.templateWidth, this.templateHeight, this.template, this.cacheDirectory, this.scanIds);
  final SendPort reply;
  final Uint8List pdf;
  final int templateWidth;
  final int templateHeight;
  final Uint8List template;
  final String? cacheDirectory;
  final bool scanIds;
}

class _PageDone {
  const _PageDone(this.page, this.reading, this.error);
  final int page;
  final PageReading? reading;
  final String? error;
}

Future<void> _worker(_WorkerStart start) async {
  final inbox = ReceivePort();
  start.reply.send(inbox.sendPort);
  PdfDocument? document;
  SheetReader? reader;
  String? setupError;
  try {
    document = PdfDocument.open(start.pdf);
    reader = SheetReader(GrayImage(start.templateWidth, start.templateHeight, start.template));
  } on PdfException catch (error) {
    setupError = error.message;
  }
  await for (final message in inbox) {
    if (message is! int) {
      inbox.close();
      break;
    }
    if (setupError != null) {
      start.reply.send(_PageDone(message, null, setupError));
      continue;
    }
    try {
      final gray = renderScanPage(document!.pages[message - 1]);
      final reading = reader!.read(gray, scanStudentId: start.scanIds);
      if (start.cacheDirectory != null) {
        writePagePicture(Directory(start.cacheDirectory!), message, gray);
      }
      start.reply.send(_PageDone(message, reading, null));
    } on PdfException catch (error) {
      start.reply.send(_PageDone(message, null, 'Page $message: ${error.message}'));
    } on Object catch (error) {
      start.reply.send(_PageDone(message, null, 'Page $message could not be read ($error).'));
    }
  }
}

/// Renders and reads [pages] on up to [workers] isolates, each fed one page
/// at a time over its own port so a slow page never holds up the others.
Future<Map<int, PageReading>> _readPages({
  required Uint8List pdf,
  required GrayImage template,
  required List<int> pages,
  required String? cacheDirectory,
  required bool scanIds,
  required int workers,
  required void Function(int done, int total) onDone,
}) async {
  final results = <int, PageReading>{};
  final queue = List<int>.of(pages);
  final finished = Completer<void>();
  final isolates = <Isolate>[];
  final ports = <ReceivePort>[];
  String? failure;
  var completed = 0;

  void feed(SendPort inbox) {
    if (failure != null || queue.isEmpty) {
      inbox.send(null);
    } else {
      inbox.send(queue.removeAt(0));
    }
  }

  Future<void> startWorker() async {
    final reply = ReceivePort();
    ports.add(reply);
    SendPort? inbox;
    reply.listen((message) {
      if (message is SendPort) {
        inbox = message;
        feed(message);
      } else if (message is _PageDone) {
        completed++;
        if (message.error != null) {
          failure ??= message.error;
        } else {
          results[message.page] = message.reading!;
        }
        onDone(completed, pages.length);
        if (failure != null || completed >= pages.length) {
          if (!finished.isCompleted) finished.complete();
        } else {
          feed(inbox!);
        }
      }
    });
    isolates.add(await Isolate.spawn(
      _worker,
      _WorkerStart(reply.sendPort, pdf, template.width, template.height, template.pixels, cacheDirectory, scanIds),
    ));
  }

  final count = math.max(1, math.min(workers, pages.length));
  try {
    for (var i = 0; i < count; i++) {
      await startWorker();
    }
    await finished.future;
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    for (final port in ports) {
      port.close();
    }
  }
  if (failure != null) throw PaperException(failure!);
  return results;
}

/// Reads just the key sheet, a few seconds' work, and stops if it was marked
/// for fewer questions than the batch is set to. Cheaper than finding out after
/// the whole class has been read. Anything else wrong with the key page is left
/// for the full read to report in its usual words.
Future<void> _checkKeyAgainstCount({
  required PaperRequest request,
  required Uint8List bytes,
  required GrayImage template,
  required String cacheDirectory,
}) async {
  final Map<int, PageReading> readings;
  try {
    readings = await _readPages(
      pdf: bytes,
      template: template,
      pages: [request.keyPage!],
      cacheDirectory: cacheDirectory,
      scanIds: false,
      workers: 1,
      onDone: (_, _) {},
    );
  } on PaperException {
    return;
  }
  final reading = readings[request.keyPage];
  if (reading is! ProcessedPage) return;
  _checkKeySheetCount(request, reading.sheet, request.keyPage!);
}

/// Stops with a [QuestionCountException] when [key] shows the batch is set to
/// the wrong number of questions: answers through N and none after while set
/// to more, or, on the printable sheet, answers past the count.
void _checkKeySheetCount(PaperRequest request, SheetExtraction key, int keyPage) {
  // On the vocabulary and matching sheets the key decides which rows count,
  // so there is no count to get wrong.
  if (keyDecidesLayout(key.form) != null) return;
  final answers = Map<int, String>.of(key.answers);
  for (final entry in request.keyOverrides.entries) {
    answers[entry.key] = entry.value.toUpperCase();
  }
  final suggested = questionCountFromKey(
    [
      for (var q = 1; q <= request.questionCount; q++)
        // Any mark counts as an answer here, several marks included.
        (answers[q] == null || answers[q] == 'BLANK') ? '' : answers[q]!,
    ],
    request.questionCount,
  );
  if (suggested != null) {
    throw QuestionCountException(
      'The answer key has answers for questions 1 to $suggested and none after, '
      'but the batch is set to ${request.questionCount} questions.',
      suggested,
      request.questionCount,
      keyPage,
    );
  }
  if (key.form != customFormName) return;
  var last = 0;
  for (var q = 1; q <= customQuestionCount; q++) {
    final answer = answers[q];
    if (answer != null && answer != 'BLANK') last = q;
  }
  if (last > request.questionCount) {
    throw QuestionCountException(
      'The answer key has answers for questions 1 to $last, '
      'but the batch is set to ${request.questionCount} questions.',
      last,
      request.questionCount,
      keyPage,
    );
  }
}

/// The key page and the student pages scored against it. A port of
/// omr_final's `select_key_and_students`.
///
/// Key sheets are printable sheets with the ANSWER KEY bubble filled, plus
/// the page named in [keyPage]. When a version is known -- asked for, or
/// bubbled on the key -- only students bubbled with it are scored; a student
/// who left the version blank is scored, and flagged, when no other version's
/// key is in the batch.
({int keyPage, List<int> students, List<(int, String)> excluded, List<int> missingVersion}) selectKeyAndStudents(
  Map<int, SheetExtraction> results, {
  int? keyPage,
  String? version,
}) {
  final marked = [for (final page in results.keys.toList()..sort()) if (results[page]!.isKey) page];
  final excluded = <(int, String)>[];
  if (keyPage == null) {
    final candidates = [
      for (final page in marked)
        if (version == null || results[page]!.version == version) page,
    ];
    if (candidates.isEmpty) {
      throw PaperException(version == null
          ? 'No answer key sheet was found. Fill the ANSWER KEY bubble on the key sheet, '
              'or say which page holds the key.'
          : 'No answer key sheet bubbled with version $version was found.');
    }
    final versions = {for (final page in candidates) results[page]!.version ?? 'none'}.toList()..sort();
    if (version == null && versions.length > 1) {
      throw PaperException(
        'This PDF holds answer keys for versions ${versions.join(', ')}. '
        'Choose a version and read the batch once for each.',
      );
    }
    keyPage = candidates.first;
    excluded.addAll([for (final page in candidates.skip(1)) (page, 'another key sheet, not scored')]);
  } else if (!results.containsKey(keyPage)) {
    throw PaperException(
      'page $keyPage was not processed as a supported answer sheet. Check which page holds the answer key.',
    );
  }

  final effective = version ?? results[keyPage]!.version;
  final otherKeyVersions = {
    for (final page in marked)
      if (results[page]!.version case final v? when v != effective) v,
  };
  final students = <int>[];
  final missingVersion = <int>[];
  for (final page in results.keys.toList()..sort()) {
    if (page == keyPage || marked.contains(page)) continue;
    final sheet = results[page]!;
    // The vocabulary and matching sheets number their questions their own
    // way, so they are scored only against a key on the same form.
    final keyForm = results[keyPage]!.form;
    if (sheet.form != keyForm && (keyDecidesLayout(sheet.form) != null || keyDecidesLayout(keyForm) != null)) {
      excluded.add((page, 'a different answer sheet from the key'));
      continue;
    }
    if (effective == null || sheet.version == effective || sheet.form != customFormName) {
      students.add(page);
    } else if (sheet.version == null) {
      if (otherKeyVersions.isNotEmpty) {
        excluded.add((page, 'no version bubbled'));
      } else {
        students.add(page);
        missingVersion.add(page);
      }
    } else {
      excluded.add((page, 'version ${sheet.version}'));
    }
  }
  return (keyPage: keyPage, students: students, excluded: excluded, missingVersion: missingVersion);
}

// ------------------------------------------------------------------- batch

/// Reads the whole batch and returns the analysis report, the same JSON the
/// Python pipeline wrote as `analysis_result.json`. [cache] receives a small
/// picture of every page.
Future<Map<String, Object?>> readBatch({
  required PaperRequest request,
  required GrayImage orientTemplate,
  required PageCache cache,
  PaperProgress? onProgress,
  int workers = 4,
  DateTime Function()? now,
}) async {
  final pdf = request.pdf;
  if (!pdf.existsSync()) throw PaperException('There is no file at ${pdf.path}');
  if (request.package == null && (request.keyPage ?? 1) < 1) {
    throw const PaperException('Choose which page holds the answer key.');
  }
  if (request.package == null && (request.questionCount < 1 || request.questionCount > maxQuestions)) {
    throw const PaperException(
      'The answer sheets hold at most $maxQuestions questions, so the count must be from 1 to $maxQuestions.',
    );
  }
  if (request.version case final v? when !sheetVersions.contains(v) || v.length != 1) {
    throw PaperException('There is no version $v; the sheet has versions 1 to ${sheetVersions.length}.');
  }
  final bytes = pdf.readAsBytesSync();
  final int totalPages;
  try {
    totalPages = PdfDocument.open(bytes).pageCount;
  } on PdfException catch (error) {
    throw PaperException('Could not inspect the PDF: ${error.message}');
  }

  final Set<int> selected;
  try {
    selected = parsePageSpec(request.pages.isEmpty ? 'all' : request.pages, totalPages);
    selected.removeAll(parsePageSpec(request.skipPages, totalPages));
  } on FormatException catch (error) {
    throw PaperException('invalid page selection: ${error.message}');
  }
  if (selected.isEmpty) throw const PaperException('the page selection contains no pages to analyze');
  if (request.keyPage != null && !selected.contains(request.keyPage)) {
    throw PaperException('key page ${request.keyPage} is excluded by the page selection');
  }

  final cacheDirectory = cache.directoryFor(pdf);
  cacheDirectory.createSync(recursive: true);
  if (request.checkQuestionCount && request.keyPage != null) {
    await _checkKeyAgainstCount(
      request: request,
      bytes: bytes,
      template: orientTemplate,
      cacheDirectory: cacheDirectory.path,
    );
  }
  onProgress?.call(0, 'Reading the sheets…');
  final readings = await _readPages(
    pdf: bytes,
    template: orientTemplate,
    pages: selected.toList()..sort(),
    cacheDirectory: cacheDirectory.path,
    scanIds: request.scanStudentIds,
    workers: workers,
    onDone: (done, total) => onProgress?.call(done / total * 0.95, 'Reading the sheets…'),
  );

  final results = <int, SheetExtraction>{};
  final blank = <int>[];
  final unsupported = <(int, double)>[];
  final processed = <int>[];
  for (final page in readings.keys.toList()..sort()) {
    switch (readings[page]!) {
      case BlankPage():
        blank.add(page);
      case UnsupportedPage(:final confidence):
        unsupported.add((page, confidence));
      case ProcessedPage(:final sheet):
        results[page] = sheet;
        processed.add(page);
    }
  }

  final package = request.package;
  if (package != null) {
    return _packageReport(
      package: package,
      request: request,
      results: results,
      processed: processed,
      blank: blank,
      unsupported: unsupported,
      selected: selected,
      totalPages: totalPages,
      cacheDirectory: cacheDirectory.path,
      now: (now ?? DateTime.now)(),
      onProgress: onProgress,
    );
  }

  final savedKey = request.savedKey;
  if (savedKey != null && results.values.any((sheet) => keyDecidesLayout(sheet.form) != null)) {
    throw const PaperException('These sheets use a different form from the saved test. Choose the matching session.');
  }
  final savedSheet = savedKey == null ? null : SheetExtraction(
    studentId: null,
    answers: {for (var q = 1; q <= savedKey.length; q++) q: savedKey[q - 1]},
    rawDarkness: const {},
    optionBaselines: const [],
    answerConfidence: const {},
    calibration: const {},
    form: results.isEmpty ? accuScanFormName : results.values.first.form,
    version: request.version,
  );
  final keyedResults = {...results};
  if (savedSheet != null) keyedResults[0] = savedSheet;
  final selection = selectKeyAndStudents(
    keyedResults,
    keyPage: savedSheet == null ? request.keyPage : 0,
    version: request.version,
  );
  final keyPage = selection.keyPage;
  final keySheet = savedSheet ?? results[keyPage]!;
  final layout = keyDecidesLayout(keySheet.form);
  if (layout != null) {
    if (!keySheet.isKey) {
      throw const PaperException('Choose the answer map CSV, or include a teacher sheet with its ANSWER KEY bubble filled. A student sheet cannot be used as the answer key.');
    }
    return _keyDecidesReport(
      layout: layout,
      request: request,
      results: results,
      keyPage: keyPage,
      selection: selection,
      processed: processed,
      blank: blank,
      unsupported: unsupported,
      selected: selected,
      totalPages: totalPages,
      cacheDirectory: cacheDirectory.path,
      now: (now ?? DateTime.now)(),
      onProgress: onProgress,
    );
  }
  if (keySheet.form == accuScanFormName && request.questionCount > accuScanQuestions) {
    throw PaperException(
      'The key is on the AccuScan form, which holds $accuScanQuestions questions; '
      'set the count to $accuScanQuestions or fewer.',
    );
  }
  if (savedKey == null && request.checkQuestionCount && request.keyPage == null) {
    // The key was found by reading every page, so its count is checked here
    // rather than before the read.
    _checkKeySheetCount(request, keySheet, keyPage);
  }
  final keyVersion = request.version ?? keySheet.version;

  // A key row with several bubbles filled is a multiple-answer question: its
  // answer is those letters, and a student must fill exactly them.
  final answerKey = <int, String>{...keySheet.answers, ...keySheet.marks};
  for (final entry in request.keyOverrides.entries) {
    final letters = entry.value.toUpperCase().replaceAll(RegExp('[ ,]'), '').split('').toSet().toList()..sort();
    final answer = letters.join();
    if (entry.key < 1 ||
        entry.key > request.questionCount ||
        !(validAnswers.contains(answer) || isMultipleAnswerKey(answer))) {
      throw PaperException('could not apply answer-key overrides: invalid key override ${entry.key}: $answer');
    }
    answerKey[entry.key] = answer;
  }

  final validation = validateAnswerKey(answerKey, request.questionCount);
  if (!validation.valid) {
    final unresolved = <int, String>{
      for (final entry in validation.invalid.entries) entry.key: entry.value,
    };
    for (final question in validation.missing) {
      unresolved.putIfAbsent(question, () => '');
    }
    final questions = unresolved.keys.toList()..sort();
    throw AnswerKeyException(
      'The answer key could not be read on ${questions.map((q) => 'question $q').join(', ')}.',
      <String, Object?>{
        'key_page': keyPage,
        'unresolved': <String, Object?>{for (final q in questions) '$q': unresolved[q]},
        'pages': cacheDirectory.path,
      },
    );
  }

  final studentPages = selection.students;
  final students = <int, ParsedSheet>{
    for (final page in studentPages)
      page: ParsedSheet(
        studentId: results[page]!.studentId,
        studentName: null,
        answers: results[page]!.answers,
        scannerScore: null,
        answerConfidence: results[page]!.answerConfidence,
        calibration: results[page]!.calibration,
        marks: results[page]!.marks,
        version: results[page]!.version,
      ),
  };
  final scores = <int, Map<String, Object?>>{
    for (final page in studentPages)
      page: <String, Object?>{
        'student_id': results[page]!.studentId,
        ...scoreStudent(results[page]!.answers, answerKey, request.questionCount, results[page]!.marks),
      },
  };
  const thresholds = [25, 40, 50];
  final analysis = itemAnalysis(
    [for (final page in studentPages) results[page]!.answers],
    answerKey,
    questionCount: request.questionCount,
    flagThresholds: thresholds,
    allMarks: [for (final page in studentPages) results[page]!.marks],
  );
  final stats = classStatistics(scores, analysis, request.questionCount);

  final reviewItems = <Map<String, Object?>>[
    for (final page in selection.missingVersion) {'page': page, 'field': 'version', 'value': null},
  ];
  for (final page in studentPages) {
    final sheet = results[page]!;
    final id = sheet.studentId;
    if (request.scanStudentIds && id != null && (id.contains('_') || id.contains('?'))) {
      reviewItems.add({'page': page, 'field': 'student_id', 'value': id});
    }
    for (final entry in sheet.answerConfidence.entries) {
      // Several marks are the expected answer to a multiple-answer question.
      final expected = sheet.answers[entry.key] == 'MULTIPLE' && isMultipleAnswerKey(answerKey[entry.key]);
      if (entry.key <= request.questionCount && entry.value['needs_review'] == true && !expected) {
        reviewItems.add({
          'page': page,
          'field': 'answer',
          'question': entry.key,
          'value': sheet.answers[entry.key],
          'confidence': entry.value,
        });
      }
    }
  }

  final report = buildAnalysisResult(
    pdfPath: pdf.path,
    examName: request.examName,
    keyPage: keyPage,
    selectedPages: selected,
    processedPages: processed,
    skippedBlank: blank,
    skippedUnsupported: unsupported,
    answerKey: answerKey,
    students: students,
    scores: scores,
    analysis: analysis,
    stats: stats,
    reviewItems: reviewItems,
    appliedCorrections: const [],
    flagThresholds: thresholds,
    runId: newRunId(),
    createdAt: (now ?? DateTime.now)(),
    scanStudentIds: request.scanStudentIds,
    questionCount: request.questionCount,
    version: keyVersion,
  );
  final printed = [for (final page in processed) if (results[page]!.form == customFormName) page];
  report['_page_cache'] = cacheDirectory.path;
  report['_log'] = <String>[
    'Selected ${selected.length} of $totalPages pages for analysis.',
    'Processed as Template A: ${processed.length - printed.length} pages',
    'Processed as 75-question sheet: ${printed.length} pages',
    'Skipped as blank: ${blank.length} pages -> $blank',
    if (unsupported.isNotEmpty) 'Skipped as an unsupported layout: ${[for (final u in unsupported) u.$1]}',
    savedKey != null ? 'Answer key: saved session' : 'Answer key: page $keyPage${keySheet.isKey ? ' (found from its ANSWER KEY bubble)' : ''}'
        '${keyVersion == null ? '' : ', version $keyVersion'}',
    for (final (page, reason) in selection.excluded) 'Not scored: page $page ($reason)',
    if (selection.missingVersion.isNotEmpty)
      'No version bubbled (scored against version $keyVersion, flagged for review): ${selection.missingVersion}',
  ].join('\n');
  report['_not_scored'] = [
    for (final (page, reason) in selection.excluded) <String, Object?>{'page': page, 'reason': reason},
  ];
  onProgress?.call(0.98, 'Filing the results…');
  return report;
}

// ----------------------------------------------- turning it into a session

List<String> _responses(List<Object?> answers, int questionCount) {
  final byQuestion = <int, Map<String, Object?>>{
    for (final entry in answers.cast<Map<String, Object?>>()) (entry['question'] as int?) ?? 0: entry,
  };
  return [
    for (var q = 1; q <= questionCount; q++)
      switch (((byQuestion[q]?['response'] as String?) ?? '').toUpperCase()) {
        'BLANK' => '',
        // Stored as the letters, the way the DataLink reports a double mark,
        // so a multiple-answer key and its students can be scored later.
        'MULTIPLE' => (byQuestion[q]?['marks'] as String?) ?? '*',
        final other => other,
      },
  ];
}

/// Writes a finished batch into the library as an ordinary session and
/// returns its id.
int sessionFromReport(Store store, Map<String, Object?> report, {String name = '', String className = ''}) {
  final exam = (report['exam'] as Map<String, Object?>?) ?? const {};
  if (exam['form'] == 'package') return _packageSession(store, report, name: name, className: className);
  final questionCount = (exam['question_count'] as int?) ?? maxQuestions;
  final students = ((report['students'] as List?) ?? const []).cast<Map<String, Object?>>();
  if (students.isEmpty) throw const PaperException('No student sheets were read from that PDF.');

  final keyEntries = ((exam['answer_key'] as List?) ?? const []).cast<Map<String, Object?>>().toList()
    ..sort((a, b) => ((a['question'] as int?) ?? 0).compareTo((b['question'] as int?) ?? 0));
  final key = [for (final entry in keyEntries) ((entry['answer'] as String?) ?? '').toUpperCase()];
  if (key.length != questionCount) {
    throw const PaperException('The answer key the pipeline read does not match the question count.');
  }

  final roster = <String, String>{};
  if (className.isNotEmpty) {
    final entry = store.getClass(className);
    for (final student in ((entry?['students'] as List?) ?? const []).cast<Map<String, Object?>>()) {
      roster[((student['id'] as String?) ?? '').trim()] = (student['name'] as String?) ?? '';
    }
  }

  final createdAt = (report['created_at'] as String?) ?? '';
  final examName = exam['name'] as String?;
  final sessionId = store.createSession(
    name.isNotEmpty ? name : (examName != null && examName.isNotEmpty ? examName : 'Paper scan'),
    className,
    questionCount,
    source: 'paper',
    pageCache: report['_page_cache'] as String?,
  );
  store.addScan(sessionId, <String, Object?>{
    'number': (exam['key_page'] as int?) ?? 1,
    'role': 'key',
    'student_id': null,
    'student_name': null,
    'received_at': createdAt,
    'answered_count': key.where((value) => value.isNotEmpty).length,
    'responses': key,
    'demo': false,
    'version': exam['version'],
  });
  for (final student in students) {
    final read = student['student_id'] ?? student['student_id_read'];
    final studentId = read == null ? '' : '$read';
    final answers = ((student['answers'] as List?) ?? const []).cast<Map<String, Object?>>();
    final responses = _responses(answers, questionCount);
    final confidence = <String, Object?>{
      for (final entry in answers)
        if (entry['confidence'] case final Map<String, Object?> c when c.isNotEmpty) '${entry['question']}': c,
    };
    final named = student['student_name'] as String?;
    store.addScan(sessionId, <String, Object?>{
      'number': (student['page'] as int?) ?? 0,
      'role': 'student',
      'student_id': studentId.isEmpty ? null : studentId,
      'student_name': (named != null && named.isNotEmpty) ? named : roster[studentId.trim()],
      'received_at': createdAt,
      'answered_count': responses.where((value) => value.isNotEmpty).length,
      'responses': responses,
      'demo': false,
      'confidence': confidence,
    });
  }
  return sessionId;
}

/// The saved scoring inputs for a makeup PDF, including keys originally read
/// from paper for a package that did not supply its own answers.
({List<String>? key, TestPackage? package, String? version}) savedPaperKey(Store store, int sessionId) {
  final session = store.session(sessionId);
  if (session == null) throw const PaperException('That session no longer exists.');
  final scans = store.sessionScans(sessionId);
  final package = packageOf(session);
  if (package != null) {
    final keyed = packageKeys(package, [
      for (final scan in scans)
        if (scan['role'] == 'key') PackageSheet(
          page: scan['number']! as int,
          version: scan['version'] as String?,
          responses: {for (var q = 1; q <= (scan['responses']! as List).length; q++) q: (scan['responses']! as List)[q - 1]! as String},
        ),
    ]);
    if (keyed.errors.isNotEmpty) throw PaperException(keyed.errors.join('\n'));
    return (key: null, package: TestPackage.fromJson({...package.toJson(), 'answers': keyed.keys}), version: null);
  }
  final keys = scans.where((scan) => scan['role'] == 'key').toList();
  if (keys.length != 1) throw const PaperException('This session needs one saved answer key before sheets can be added.');
  final key = (keys.single['responses']! as List).cast<String>();
  final count = session['question_count']! as int;
  final validation = validateAnswerKey({for (var q = 1; q <= key.length; q++) q: key[q - 1]}, count);
  if (!validation.valid) throw const PaperException('Correct the saved answer key before adding sheets.');
  return (key: key, package: null, version: keys.single['version'] as String?);
}

/// Adds just the students from a new PDF. Existing keys, corrections and review
/// acknowledgements are kept. Page images are copied to a separate session
/// directory under the cache so page 1 of a makeup PDF never replaces page 1
/// of the original batch (or another session using that PDF).
void appendReportToSession(Store store, PageCache cache, int sessionId, Map<String, Object?> report) {
  final session = store.session(sessionId);
  if (session == null) throw const PaperException('That session no longer exists.');
  final students = ((report['students'] as List?) ?? const []).cast<Map<String, Object?>>();
  if (students.isEmpty) throw const PaperException('No student sheets were read from that PDF.');
  final existing = store.sessionScans(sessionId);
  var number = existing.fold<int>(0, (n, scan) => math.max(n, scan['number']! as int));
  cache.root.createSync(recursive: true);
  final directory = cache.root.createTempSync('session-$sessionId-');
  try {
    final oldCache = session['page_cache'] as String?;
    if (oldCache != null && Directory(oldCache).existsSync()) {
      for (final file in Directory(oldCache).listSync().whereType<File>()) {
        file.copySync('${directory.path}/${file.uri.pathSegments.last}');
      }
    }
    final scans = <Map<String, Object?>>[];
    for (final student in students) {
      number++;
      final answers = ((student['answers'] as List?) ?? const []).cast<Map<String, Object?>>();
      final responses = _responses(answers, session['question_count']! as int);
      final id = student['student_id'] ?? student['student_id_read'];
      scans.add({
        'student_id': id,
        'student_name': student['student_name'],
        'received_at': report['created_at'],
        'responses': responses,
        'answered_count': responses.where((r) => r.isNotEmpty).length,
        'version': student['version'],
        'confidence': <String, Object?>{
          for (final a in answers)
            if (a['confidence'] case final Map<String, Object?> c when c.isNotEmpty) '${a['question']}': c,
        },
      });
      // An unscored original page may share this new number. It must never
      // masquerade as a makeup image if that image is missing from the cache.
      for (final extension in ['jpg', 'png']) {
        final file = File('${directory.path}/page-${number.toString().padLeft(6, '0')}.$extension');
        if (file.existsSync()) file.deleteSync();
      }
      final source = report['_page_cache'] as String?;
      final page = student['page'] as int?;
      if (source != null && page != null) {
        for (final extension in ['jpg', 'png']) {
          final file = File('$source/page-${page.toString().padLeft(6, '0')}.$extension');
          if (file.existsSync()) file.copySync('${directory.path}/page-${number.toString().padLeft(6, '0')}.$extension');
        }
      }
    }
    store.appendScans(sessionId, scans, pageCache: directory.path);
  } on Object {
    directory.deleteSync(recursive: true);
    rethrow;
  }
}

/// A date for logs, shared with the rest of the package.
String paperStamp(DateTime when) => pyIsoUtc(when);

// --------------------------------------------------------- package batches

/// What a sheet showed, by question, for a package: a double mark as its
/// letters, so a multiple-answer key can be matched.
Map<int, String> _packageResponses(SheetExtraction sheet) => {
      for (final entry in sheet.answers.entries)
        entry.key: entry.value == 'MULTIPLE' ? (sheet.marks[entry.key] ?? 'MULTIPLE') : entry.value,
    };

/// Every version in one go: scores the batch against the package (which also
/// checks it, so a problem is reported before anything is filed) and keeps
/// what [sessionFromReport] needs to file it.
Map<String, Object?> _packageReport({
  required TestPackage package,
  required PaperRequest request,
  required Map<int, SheetExtraction> results,
  required List<int> processed,
  required List<int> blank,
  required List<(int, double)> unsupported,
  required Set<int> selected,
  required int totalPages,
  required String cacheDirectory,
  required DateTime now,
  PaperProgress? onProgress,
}) {
  PackageSheet sheetOf(int page) {
    final sheet = results[page]!;
    return PackageSheet(
      page: page,
      version: sheet.version,
      responses: _packageResponses(sheet),
      studentId: sheet.studentId,
      confidence: sheet.answerConfidence,
    );
  }

  final keyPages = [for (final page in processed) if (results[page]!.isKey) page];
  final studentPages = [for (final page in processed) if (!results[page]!.isKey &&
      (package.form == null
          ? (keyDecidesLayout(results[page]!.form) == null || results[page]!.form == matchFormName)
          : results[page]!.form == package.form)) page];
  final Map<String, Object?> report;
  try {
    report = buildPackageAnalysis(
      package: package,
      keySheets: [for (final page in keyPages) sheetOf(page)],
      sheets: [for (final page in studentPages) sheetOf(page)],
      examName: request.examName ?? request.pdf.uri.pathSegments.last.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
      sourceFile: request.pdf.uri.pathSegments.last,
      runId: newRunId(),
      createdAt: paperStamp(now),
    );
  } on TestPackageException catch (error) {
    throw PaperException(error.message);
  }
  final notScored = (report['not_scored']! as List).cast<Map<String, Object?>>();
  final mismatches = (report['key_mismatches']! as List).cast<Map<String, Object?>>();
  // Retain excluded sheets so saved reports still explain missing versions
  // and the teacher can correct their version without rescanning.
  report['_excluded_sheets'] = [
    for (final entry in notScored)
      if (results[entry['page']] case final SheetExtraction sheet)
        <String, Object?>{
          'number': entry['page'], 'role': 'student', 'version': sheet.version,
          'student_id': sheet.studentId,
          'responses': [for (var q = 1; q <= package.questionCount; q++)
            _stored(_packageResponses(sheet)[q] ?? 'BLANK')],
          'confidence': {for (final e in sheet.answerConfidence.entries) '${e.key}': e.value},
        },
  ];
  report['_package'] = package.toJson();
  report['_key_sheets'] = [
    for (final page in keyPages)
      <String, Object?>{
        'page': page,
        'version': results[page]!.version,
        'responses': [
          for (var q = 1; q <= package.questionCount; q++) _packageResponses(results[page]!)[q] ?? 'BLANK',
        ],
      },
  ];
  report['_page_cache'] = cacheDirectory;
  report['_log'] = <String>[
    'Selected ${selected.length} of $totalPages pages for analysis.',
    'Test package: ${package.items.length} items, versions ${package.versions.join(', ')}; '
        '${package.hasAnswers ? 'answers from the package' : 'answers from the key sheets'}',
    'Skipped as blank: ${blank.length} pages -> $blank',
    if (unsupported.isNotEmpty) 'Skipped as an unsupported layout: ${[for (final u in unsupported) u.$1]}',
    for (final page in keyPages) 'Key sheet: page $page, version ${results[page]!.version ?? 'not bubbled'}',
    for (final m in mismatches)
      'KEY CHECK: version ${m['version']} question ${m['question']} (${m['item']}): '
          'package says ${m['package']}, key sheet (page ${m['key_page']}) shows ${m['key_sheet']}',
    for (final n in notScored) 'Not scored: page ${n['page']} (${n['reason']})',
  ].join('\n');
  onProgress?.call(0.98, 'Filing the results…');
  return report;
}

String _stored(String response) => switch (response) {
      'BLANK' => '',
      'MULTIPLE' => '*',
      final other => other,
    };

int _packageSession(Store store, Map<String, Object?> report, {String name = '', String className = ''}) {
  final exam = report['exam']! as Map<String, Object?>;
  final package = TestPackage.fromJson((report['_package']! as Map).cast<String, Object?>());
  final students = (report['students']! as List).cast<Map<String, Object?>>();
  if (students.isEmpty) throw const PaperException('No student sheets were read from that PDF.');
  final roster = <String, String>{};
  if (className.isNotEmpty) {
    for (final student in ((store.getClass(className)?['students'] as List?) ?? const []).cast<Map<String, Object?>>()) {
      roster[((student['id'] as String?) ?? '').trim()] = (student['name'] as String?) ?? '';
    }
  }
  final createdAt = (report['created_at'] as String?) ?? '';
  final examName = exam['name'] as String?;
  final sessionId = store.createSession(
    name.isNotEmpty ? name : (examName != null && examName.isNotEmpty ? examName : 'Paper scan'),
    className,
    package.questionCount,
    source: 'paper',
    pageCache: report['_page_cache'] as String?,
    package: pyJsonEncode(package.toJson()),
  );
  for (final key in ((report['_key_sheets'] as List?) ?? const []).cast<Map<String, Object?>>()) {
    final responses = [for (final r in (key['responses']! as List)) _stored(r! as String)];
    store.addScan(sessionId, <String, Object?>{
      'number': key['page'],
      'role': 'key',
      'version': key['version'],
      'received_at': createdAt,
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
      'demo': false,
    });
  }
  for (final student in students) {
    final answers = (student['answers']! as List).cast<Map<String, Object?>>();
    final responses = [for (final a in answers) _stored(((a['marks'] ?? a['response']) as String?) ?? 'BLANK')];
    final id = (student['student_id'] as String?) ?? '';
    store.addScan(sessionId, <String, Object?>{
      'number': student['page'],
      'role': 'student',
      'version': student['version'],
      'student_id': id.isEmpty ? null : id,
      'student_name': roster[id.trim()],
      'received_at': createdAt,
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
      'demo': false,
      'confidence': <String, Object?>{
        for (final a in answers)
          if (a['confidence'] case final Map<String, Object?> c when c.isNotEmpty) '${a['question']}': c,
      },
    });
  }
  for (final scan in ((report['_excluded_sheets'] as List?) ?? const []).cast<Map<String, Object?>>()) {
    store.addScan(sessionId, {...scan, 'received_at': createdAt, 'demo': false});
  }
  return sessionId;
}

// ------------------------------------------- vocabulary and matching sheets

/// A vocabulary or matching sheet's key, read as a one-version test package:
/// the rows it marks are the items, its parts the sections. Scored, reviewed
/// and filed the same way as a teacher's package.
Map<String, Object?> _keyDecidesReport({
  required KeyDecidesLayout layout,
  required PaperRequest request,
  required Map<int, SheetExtraction> results,
  required int keyPage,
  required ({int keyPage, List<int> students, List<(int, String)> excluded, List<int> missingVersion}) selection,
  required List<int> processed,
  required List<int> blank,
  required List<(int, double)> unsupported,
  required Set<int> selected,
  required int totalPages,
  required String cacheDirectory,
  required DateTime now,
  PaperProgress? onProgress,
}) {
  final key = results[keyPage]!;
  final version = request.version ?? key.version ?? '1';
  final answers = <int, String>{};
  final unresolved = <int, String>{};
  for (var q = 1; q <= layout.questionCount; q++) {
    final read = key.answers[q] ?? 'BLANK';
    if (read == 'BLANK') continue;
    if (read == 'MULTIPLE') {
      final letters = key.marks[q];
      if (letters != null && layout.allowsSeveral(q)) {
        answers[q] = letters;
      } else {
        unresolved[q] = read;
      }
    } else {
      answers[q] = read;
    }
  }
  for (final entry in request.keyOverrides.entries) {
    final q = entry.key;
    final letters = (entry.value.toUpperCase().replaceAll(RegExp('[ ,-]'), '').split('').toSet().toList()..sort()).join();
    if (q < 1 || q > layout.questionCount) {
      throw PaperException('could not apply answer-key overrides: there is no question $q on this sheet');
    }
    unresolved.remove(q);
    if (letters.isEmpty) {
      answers.remove(q);
      continue;
    }
    if (!letters.split('').every(layout.lettersOf(q).contains) || (letters.length > 1 && !layout.allowsSeveral(q))) {
      throw PaperException('could not apply answer-key overrides: invalid key override $q: $letters');
    }
    answers[q] = letters;
  }
  if (unresolved.isNotEmpty) {
    final questions = unresolved.keys.toList()..sort();
    throw AnswerKeyException(
      'The answer key could not be read on ${questions.map((q) => 'question $q').join(', ')}.',
      <String, Object?>{
        'key_page': keyPage,
        'unresolved': <String, Object?>{for (final q in questions) '$q': unresolved[q]},
        'pages': cacheDirectory,
      },
    );
  }
  if (answers.isEmpty) throw const PaperException('The answer key sheet has no answers marked.');

  final questions = answers.keys.toList()..sort();
  String item(int q) => 'Q$q';
  final package = TestPackage(
    items: [for (final q in questions) item(q)],
    versions: [version],
    numbers: {version: {for (final q in questions) item(q): q}},
    answers: {version: {for (final q in questions) item(q): answers[q]!}},
    sections: {for (final q in questions) item(q): layout.sectionOf(q)},
    standards: {for (final q in questions) item(q): ''},
    form: layout.form,
    options: {
      for (final q in questions)
        if (layout.lettersOf(q) != 'ABCDE') item(q): layout.lettersOf(q),
    },
  );
  final Map<String, Object?> report;
  try {
    report = buildPackageAnalysis(
      package: package,
      keySheets: const [],
      sheets: [
        for (final page in selection.students)
          PackageSheet(
            page: page,
            version: version,
            responses: _packageResponses(results[page]!),
            studentId: results[page]!.studentId,
            confidence: results[page]!.answerConfidence,
          ),
      ],
      examName: request.examName ?? request.pdf.uri.pathSegments.last.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
      sourceFile: request.pdf.uri.pathSegments.last,
      runId: newRunId(),
      createdAt: paperStamp(now),
    );
  } on TestPackageException catch (error) {
    throw PaperException(error.message);
  }
  report['_package'] = package.toJson();
  report['_key_sheets'] = [
    <String, Object?>{
      'page': keyPage,
      'version': version,
      'responses': [for (var q = 1; q <= package.questionCount; q++) answers[q] ?? 'BLANK'],
    },
  ];
  report['not_scored'] = [
    for (final (page, reason) in selection.excluded) <String, Object?>{'page': page, 'reason': reason},
  ];
  report['_page_cache'] = cacheDirectory;
  report['_log'] = <String>[
    'Selected ${selected.length} of $totalPages pages for analysis.',
    'Answer key: page $keyPage (${layout.form}), version $version; scoring ${questions.length} question(s) the key marks',
    'Skipped as blank: ${blank.length} pages -> $blank',
    if (unsupported.isNotEmpty) 'Skipped as an unsupported layout: ${[for (final u in unsupported) u.$1]}',
    for (final (page, reason) in selection.excluded) 'Not scored: page $page ($reason)',
  ].join('\n');
  onProgress?.call(0.98, 'Filing the results…');
  return report;
}
