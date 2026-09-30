/// The versioned JSON contract sent to website integrations. A port of
/// `vendor/result_schema.py`; key order is part of the contract's bytes.
library;

import '../protocol/py_math.dart';
import '../protocol/python_compat.dart';

const String schemaVersion = '1.0';

/// One sheet as the analysis step sees it.
class ParsedSheet {
  ParsedSheet({
    required this.studentId,
    required this.studentName,
    required this.answers,
    required this.scannerScore,
    required this.answerConfidence,
  });

  final String? studentId;
  final String? studentName;
  final Map<int, String> answers;
  final int? scannerScore;

  /// Question -> `{mark_strength, margin, needs_review}` or whatever the
  /// reader stored. Empty for a DataLink sheet.
  final Map<int, Object?> answerConfidence;

  /// Always empty here; the paper reader fills it in, this path does not.
  Map<String, Object?> get calibration => const <String, Object?>{};
}

String? normalizedStudentId(String? value) {
  if (value == null || value.isEmpty || value.contains('_') || value.contains('?')) {
    return null;
  }
  return value;
}

/// `os.path.basename`.
String pyBasename(String path) => path.substring(path.lastIndexOf('/') + 1);

/// `os.path.splitext(...)[0]`.
String pyStripExtension(String path) {
  final sep = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot > sep) {
    for (var i = sep + 1; i < dot; i++) {
      if (path[i] != '.') return path.substring(0, dot);
    }
  }
  return path;
}

Map<String, Object?> buildAnalysisResult({
  required String pdfPath,
  required int keyPage,
  required Set<int> selectedPages,
  required List<int> processedPages,
  required List<int> skippedBlank,
  required List<(int, double)> skippedUnsupported,
  required Map<int, String> answerKey,
  required Map<int, ParsedSheet> students,
  required Map<int, Map<String, Object?>> scores,
  required Map<int, Map<String, Object?>> analysis,
  required Map<String, Object?> stats,
  required List<Map<String, Object?>> reviewItems,
  required List<Map<String, Object?>> appliedCorrections,
  required List<int> flagThresholds,
  required String runId,
  required DateTime createdAt,
  String? examName,
  bool scanStudentIds = true,
  int questionCount = 50,
  String sourceType = 'pdf_scan',
}) {
  final corrected = <(int, String)>{
    for (final entry in appliedCorrections)
      (entry['page']! as int, entry['field']! as String),
  };

  final studentRows = <Map<String, Object?>>[];
  for (final page in (students.keys.toList()..sort())) {
    final extraction = students[page]!;
    final score = scores[page]!;
    final answers = <Map<String, Object?>>[];
    for (var question = 1; question <= questionCount; question++) {
      final response = extraction.answers[question] ?? 'BLANK';
      final confidence = extraction.answerConfidence[question] ?? <String, Object?>{};
      answers.add(<String, Object?>{
        'question': question,
        'response': response,
        'correct_answer': answerKey[question],
        'correct': response == answerKey[question],
        'confidence': confidence,
        'manually_corrected': corrected.contains((page, 'answer_$question')),
      });
    }
    studentRows.add(<String, Object?>{
      'page': page,
      'student_id': normalizedStudentId(extraction.studentId),
      'student_id_read': extraction.studentId,
      'student_name': extraction.studentName,
      'student_id_manually_corrected': corrected.contains((page, 'student_id')),
      'score': <String, Object?>{
        'correct': score['correct'],
        'incorrect': score['incorrect'],
        'blank': score['blank'],
        'multiple': score['multiple'],
        'total': questionCount,
        'percentage': score['percentage'],
        'missed_questions': score['missed_questions'],
      },
      'answers': answers,
      'calibration': extraction.calibration,
    });
  }

  final itemRows = <Map<String, Object?>>[];
  for (var question = 1; question <= questionCount; question++) {
    final item = analysis[question]!;
    final flags = item['flags']! as Map<String, Object?>;
    itemRows.add(<String, Object?>{
      'question': question,
      'correct_answer': item['correct_answer'],
      'n_correct': item['n_correct'],
      'percent_correct': item['pct_correct'],
      'difficulty': item['difficulty'],
      'point_biserial': item['point_biserial'],
      'upper_lower_discrimination': item['upper_lower_discrimination'],
      'distribution': item['distribution'],
      'most_common_wrong': item['most_common_wrong'],
      'flags': [
        for (final entry in flags.entries)
          if (entry.value == true) entry.key,
      ],
    });
  }

  final warnings = <Map<String, Object?>>[];
  if (skippedBlank.isNotEmpty) {
    warnings.add({'code': 'blank_pages_skipped', 'pages': skippedBlank});
  }
  if (skippedUnsupported.isNotEmpty) {
    warnings.add({
      'code': 'unsupported_pages_skipped',
      'pages': [for (final (page, _) in skippedUnsupported) page],
    });
  }
  if (reviewItems.isNotEmpty) {
    warnings.add({'code': 'review_required', 'count': reviewItems.length});
  }

  final mean = stats['mean'] as num?;
  final median = stats['median'] as num?;
  final name = (examName != null && examName.isNotEmpty)
      ? examName
      : pyStripExtension(pyBasename(pdfPath));

  return <String, Object?>{
    'schema_version': schemaVersion,
    'run_id': runId,
    'status': 'completed',
    'created_at': pyIsoUtc(createdAt),
    'exam': <String, Object?>{
      'name': name,
      'source_file': pyBasename(pdfPath),
      'source_type': sourceType,
      'student_id_scanning': scanStudentIds,
      'question_count': questionCount,
      'key_page': keyPage,
      'answer_key': [
        for (var q = 1; q <= questionCount; q++) {'question': q, 'answer': answerKey[q]},
      ],
      'selected_pages': selectedPages.toList()..sort(),
      'processed_pages': processedPages.toList()..sort(),
      'flag_thresholds': flagThresholds,
    },
    'summary': <String, Object?>{
      ...stats,
      'mean_percentage':
          mean != null ? pyRound(mean / questionCount * 100, 1) : null,
      'median_percentage':
          median != null ? pyRound(median / questionCount * 100, 1) : null,
    },
    'students': studentRows,
    'items': itemRows,
    'review_items': reviewItems,
    'warnings': warnings,
    'corrections': appliedCorrections,
  };
}
