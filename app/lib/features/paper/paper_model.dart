import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/foundation.dart';

import '../classes/class_book.dart';

/// Reads a batch: the PDF, what to read, and a way to report progress.
typedef BatchReader = Future<Map<String, Object?>> Function(PaperRequest request, PaperProgress progress);

/// How many pages a PDF has, or throws [PaperException].
typedef PageCounter = int Function(File pdf);

int countPdfPages(File pdf) => pdfPageCount(pdf.readAsBytesSync());

enum PaperPhase { idle, reading, done, failed }

/// The Paper tab: choose a scanned PDF, say where the key is, read it, and
/// file the result as a session. One batch at a time.
class PaperModel extends ChangeNotifier {
  PaperModel({
    required this._store,
    required this.classBook,
    required this._cache,
    required this._reader,
    this._pageCounter = countPdfPages,
  }) {
    refreshStorage();
  }

  final Store _store;
  final ClassBook classBook;
  final PageCache _cache;
  final BatchReader _reader;
  final PageCounter _pageCounter;

  File? _file;
  int _pageCount = 0;
  String name = '';
  String className = '';
  int keyPage = 1;
  int questions = maxQuestions;

  PaperPhase _phase = PaperPhase.idle;
  double _progress = 0;
  String _message = '';
  String? _error;
  Map<String, Object?>? _keyReview;
  ({int suggested, int current, int keyPage})? _countSuggestion;
  bool _keepCount = false;
  int? _sessionId;
  Map<String, Object?> _storage = const {};
  bool _warnedOverLimit = false;
  bool _disposed = false;

  File? get file => _file;
  int get pageCount => _pageCount;
  PaperPhase get phase => _phase;
  bool get busy => _phase == PaperPhase.reading;
  double get progress => _progress;
  String get message => _message;
  String? get error => _error;

  /// Set when the key sheet could not be read: `{key_page, unresolved, pages}`.
  Map<String, Object?>? get keyReview => _keyReview;

  /// Set when the key sheet has answers through question N and none after,
  /// while the batch is set to more: the screen offers to read it as N.
  ({int suggested, int current, int keyPage})? get countSuggestion => _countSuggestion;
  int? get sessionId => _sessionId;
  Map<String, Object?> get storage => _storage;

  String get fileLine => _file == null
      ? ''
      : '${_file!.uri.pathSegments.last} · $_pageCount page${_pageCount == 1 ? '' : 's'}';

  /// The setup form shows once a file is chosen, and not while a batch is
  /// being read or has just been filed.
  bool get showSetup => _file != null && !busy && _phase != PaperPhase.done;

  bool get canRun =>
      _file != null &&
      !busy &&
      keyPage >= 1 &&
      keyPage <= _pageCount &&
      questions >= 1 &&
      questions <= maxQuestions;

  int get cacheBytes => (_storage['cache_bytes'] as int?) ?? 0;
  int get cacheBatches => (_storage['batches'] as int?) ?? 0;

  void refreshStorage() {
    _storage = _cache.report();
    _notify();
  }

  /// Chooses [path] as the batch. Returns false, with [error] set, if it
  /// cannot be read as a PDF.
  bool setPdf(String path) {
    final file = File(path);
    _error = null;
    _sessionId = null;
    _countSuggestion = null;
    _keepCount = false;
    if (_phase == PaperPhase.done || _phase == PaperPhase.failed) _phase = PaperPhase.idle;
    try {
      _pageCount = _pageCounter(file);
    } on PaperException catch (e) {
      _file = null;
      _pageCount = 0;
      _error = e.message;
      _notify();
      return false;
    } on FileSystemException catch (e) {
      _file = null;
      _pageCount = 0;
      _error = 'Could not open the PDF: ${e.message}';
      _notify();
      return false;
    }
    _file = file;
    final base = file.uri.pathSegments.last;
    if (name.isEmpty) name = base.toLowerCase().endsWith('.pdf') ? base.substring(0, base.length - 4) : base;
    if (keyPage > _pageCount) keyPage = 1;
    if (className.isEmpty) className = classBook.selectedName;
    _notify();
    return true;
  }

  void setName(String value) => name = value;
  void setClass(String value) {
    className = value;
    _notify();
  }

  void setKeyPage(int value) {
    keyPage = value;
    _keepCount = false;
    _notify();
  }

  void setQuestions(int value) {
    questions = value;
    _keepCount = false;
    _notify();
  }

  /// Reads the batch. [keyOverrides] are answers the teacher gave for key
  /// questions the reader could not settle.
  Future<void> run({Map<int, String> keyOverrides = const {}}) async {
    final file = _file;
    if (file == null || busy) return;
    _phase = PaperPhase.reading;
    _progress = 0;
    _message = 'Reading the sheets…';
    _error = null;
    _keyReview = null;
    _countSuggestion = null;
    _sessionId = null;
    _notify();
    try {
      final report = await _reader(
        PaperRequest(
          pdf: file,
          keyPage: keyPage,
          questionCount: questions,
          examName: name.trim().isEmpty ? null : name.trim(),
          keyOverrides: keyOverrides,
          checkQuestionCount: !_keepCount,
        ),
        (fraction, message) {
          _progress = fraction.clamp(0.0, 1.0);
          _message = message;
          _notify();
        },
      );
      final id = sessionFromReport(_store, report, name: name.trim(), className: className);
      final students = ((report['students'] as List?) ?? const []).length;
      _sessionId = id;
      _progress = 1;
      _message = 'Read $students sheet${students == 1 ? '' : 's'}';
      _phase = PaperPhase.done;
    } on AnswerKeyException catch (e) {
      _phase = PaperPhase.failed;
      _message = e.message;
      _keyReview = e.review;
    } on QuestionCountException catch (e) {
      _phase = PaperPhase.failed;
      _message = e.message;
      _countSuggestion = (suggested: e.suggested, current: e.current, keyPage: e.keyPage);
    } on PaperException catch (e) {
      _phase = PaperPhase.failed;
      _error = e.message;
      _message = e.message;
    } on Object catch (e) {
      _phase = PaperPhase.failed;
      _error = 'The sheets could not be read. $e';
      _message = _error!;
    }
    refreshStorage();
  }

  /// "Read as 30 questions": take the count the key sheet showed. The caller
  /// reads the batch again.
  void useSuggestedCount() {
    final suggestion = _countSuggestion;
    if (suggestion == null) return;
    questions = suggestion.suggested;
    _countSuggestion = null;
    _keepCount = false;
    _notify();
  }

  /// "Keep 50 questions": the count was meant. The caller reads the batch
  /// again, and the key goes through the usual check for what is missing.
  void keepQuestionCount() {
    _countSuggestion = null;
    _keepCount = true;
    _notify();
  }

  /// "Start over" on the key panel: drop the review and show the form again.
  void startOver() {
    _keyReview = null;
    _countSuggestion = null;
    _keepCount = false;
    _error = null;
    _phase = PaperPhase.idle;
    _notify();
  }

  /// "Read another batch".
  void readAnother() {
    _sessionId = null;
    _countSuggestion = null;
    _keepCount = false;
    _phase = PaperPhase.idle;
    _notify();
  }

  /// True once per batch, when the cache has grown past its limit, so the
  /// screen can offer to empty it. Asking every time would be trained away.
  bool takePurgeOffer() {
    if (_storage['over_limit'] != true) {
      _warnedOverLimit = false;
      return false;
    }
    if (_warnedOverLimit) return false;
    _warnedOverLimit = true;
    return true;
  }

  /// Deletes the page pictures and returns the bytes freed.
  int purge() {
    final result = _cache.purge();
    refreshStorage();
    return (result['freed_bytes'] as int?) ?? 0;
  }

  /// A page of the batch being fixed, for "Look at the key sheet".
  Uint8List? pagePicture(int page) {
    final directory = _keyReview?['pages'] as String?;
    return directory == null ? null : readPagePicture(directory, page);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
