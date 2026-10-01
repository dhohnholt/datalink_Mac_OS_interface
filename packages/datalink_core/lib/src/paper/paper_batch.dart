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
import '../analysis/result_schema.dart';
import '../analysis/scoring.dart';
import '../protocol/python_compat.dart';
import '../store/store.dart';
import 'gray_image.dart';
import 'omr/omr.dart';
import 'page_cache.dart';
import 'page_selection.dart';
import 'pdf/pdf_document.dart';
import 'pdf/pdf_scan.dart';

const int maxQuestions = 50;

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
    required this.keyPage,
    this.questionCount = maxQuestions,
    this.pages = 'all',
    this.skipPages = '',
    this.examName,
    this.keyOverrides = const {},
    this.scanStudentIds = true,
  });

  final File pdf;
  final int keyPage;
  final int questionCount;
  final String pages;
  final String skipPages;
  final String? examName;

  /// Question -> the answer the teacher says the key sheet carries.
  final Map<int, String> keyOverrides;
  final bool scanStudentIds;
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
  if (request.keyPage < 1) throw const PaperException('Choose which page holds the answer key.');
  if (request.questionCount < 1 || request.questionCount > maxQuestions) {
    throw const PaperException(
      'The paper form holds $maxQuestions questions, so the count must be from 1 to $maxQuestions.',
    );
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
  if (!selected.contains(request.keyPage)) {
    throw PaperException('key page ${request.keyPage} is excluded by the page selection');
  }

  final cacheDirectory = cache.directoryFor(pdf);
  cacheDirectory.createSync(recursive: true);
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

  final keySheet = results[request.keyPage];
  if (keySheet == null) {
    throw PaperException(
      'page ${request.keyPage} was not processed as a valid Template A sheet. '
      'Check which page holds the answer key.',
    );
  }

  final answerKey = Map<int, String>.of(keySheet.answers);
  for (final entry in request.keyOverrides.entries) {
    final answer = entry.value.toUpperCase();
    if (entry.key < 1 || entry.key > request.questionCount || !validAnswers.contains(answer)) {
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
        'key_page': request.keyPage,
        'unresolved': <String, Object?>{for (final q in questions) '$q': unresolved[q]},
        'pages': cacheDirectory.path,
      },
    );
  }

  final studentPages = processed.where((page) => page != request.keyPage).toList();
  final students = <int, ParsedSheet>{
    for (final page in studentPages)
      page: ParsedSheet(
        studentId: results[page]!.studentId,
        studentName: null,
        answers: results[page]!.answers,
        scannerScore: null,
        answerConfidence: results[page]!.answerConfidence,
        calibration: results[page]!.calibration,
      ),
  };
  final scores = <int, Map<String, Object?>>{
    for (final page in studentPages)
      page: <String, Object?>{
        'student_id': results[page]!.studentId,
        ...scoreStudent(results[page]!.answers, answerKey, request.questionCount),
      },
  };
  const thresholds = [25, 40, 50];
  final analysis = itemAnalysis(
    [for (final page in studentPages) results[page]!.answers],
    answerKey,
    questionCount: request.questionCount,
    flagThresholds: thresholds,
  );
  final stats = classStatistics(scores, analysis, request.questionCount);

  final reviewItems = <Map<String, Object?>>[];
  for (final page in processed) {
    if (page == request.keyPage) continue;
    final sheet = results[page]!;
    final id = sheet.studentId;
    if (request.scanStudentIds && id != null && (id.contains('_') || id.contains('?'))) {
      reviewItems.add({'page': page, 'field': 'student_id', 'value': id});
    }
    for (final entry in sheet.answerConfidence.entries) {
      if (entry.key <= request.questionCount && entry.value['needs_review'] == true) {
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
    keyPage: request.keyPage,
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
  );
  report['_page_cache'] = cacheDirectory.path;
  report['_log'] = <String>[
    'Selected ${selected.length} of $totalPages pages for analysis.',
    'Processed as Template A: ${processed.length} pages',
    'Skipped as blank: ${blank.length} pages -> $blank',
    if (unsupported.isNotEmpty) 'Skipped as NOT Template A (unsupported layout): ${[for (final u in unsupported) u.$1]}',
  ].join('\n');
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
        'MULTIPLE' => '*',
        final other => other,
      },
  ];
}

/// Writes a finished batch into the library as an ordinary session and
/// returns its id.
int sessionFromReport(Store store, Map<String, Object?> report, {String name = '', String className = ''}) {
  final exam = (report['exam'] as Map<String, Object?>?) ?? const {};
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

/// A date for logs, shared with the rest of the package.
String paperStamp(DateTime when) => pyIsoUtc(when);
