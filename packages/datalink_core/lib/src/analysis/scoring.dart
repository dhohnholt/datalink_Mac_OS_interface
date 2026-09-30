/// Scoring and item analysis. A port of `vendor/analysis_core.py`, which is
/// itself a verbatim copy of omr_final's; the numbers must come out the same.
library;

import 'dart:math' as math;

import '../protocol/py_math.dart';

const Set<String> validAnswers = {'A', 'B', 'C', 'D', 'E'};
const List<String> unresolved = ['BLANK', 'MULTIPLE'];

/// What `validate_answer_key` reports.
class KeyValidation {
  const KeyValidation({
    required this.valid,
    required this.missing,
    required this.invalid,
  });

  final bool valid;
  final List<int> missing;

  /// Question -> what the key holds there (a non-answer).
  final Map<int, String> invalid;
}

KeyValidation validateAnswerKey(Map<int, String> answerKey, [int questionCount = 50]) {
  final missing = <int>[
    for (var q = 1; q <= questionCount; q++)
      if (!answerKey.containsKey(q)) q,
  ];
  final invalid = <int, String>{
    for (var q = 1; q <= questionCount; q++)
      if (answerKey.containsKey(q) && !validAnswers.contains(answerKey[q]))
        q: answerKey[q]!,
  };
  return KeyValidation(
    valid: missing.isEmpty && invalid.isEmpty,
    missing: missing,
    invalid: invalid,
  );
}

/// One student's score. Field order matches the Python dict.
Map<String, Object?> scoreStudent(
  Map<int, String> answers,
  Map<int, String> answerKey, [
  int questionCount = 50,
]) {
  final validation = validateAnswerKey(answerKey, questionCount);
  if (!validation.valid) {
    throw StateError('answer key is unresolved');
  }
  var correct = 0;
  var incorrect = 0;
  var blank = 0;
  var multiple = 0;
  final missed = <int>[];
  for (var q = 1; q <= questionCount; q++) {
    final given = answers[q] ?? 'BLANK';
    final key = answerKey[q];
    if (given == key) {
      correct++;
    } else if (given == 'BLANK') {
      blank++;
      missed.add(q);
    } else if (given == 'MULTIPLE') {
      multiple++;
      missed.add(q);
    } else {
      incorrect++;
      missed.add(q);
    }
  }
  return <String, Object?>{
    'correct': correct,
    'incorrect': incorrect,
    'blank': blank,
    'multiple': multiple,
    'percentage': pyRound(correct / questionCount * 100, 1),
    'missed_questions': missed,
  };
}

double? _pointBiserial(List<int> itemScores, List<int> totalScores) {
  final n = itemScores.length;
  if (n < 3 || itemScores.toSet().length < 2) return null;
  final p = itemScores.fold<int>(0, (a, b) => a + b) / n;
  final q = 1 - p;
  if (p == 0 || q == 0) return null;
  final corrected = <int>[
    for (var i = 0; i < n; i++) totalScores[i] - itemScores[i],
  ];
  if (corrected.toSet().length < 2) return null;
  final right = <int>[
    for (var i = 0; i < n; i++)
      if (itemScores[i] != 0) corrected[i],
  ];
  final wrong = <int>[
    for (var i = 0; i < n; i++)
      if (itemScores[i] == 0) corrected[i],
  ];
  final meanCorrect = pyMeanInts(right);
  final meanWrong = pyMeanInts(wrong);
  final sd = pyStdevInts(corrected);
  if (sd == 0) return null;
  return pyRound(((meanCorrect - meanWrong) / sd) * math.sqrt(p * q), 3);
}

/// Item analysis for every question, keyed by question number.
Map<int, Map<String, Object?>> itemAnalysis(
  List<Map<int, String>> allAnswers,
  Map<int, String> answerKey, {
  int questionCount = 50,
  List<int> flagThresholds = const [25, 40, 50],
}) {
  final validation = validateAnswerKey(answerKey, questionCount);
  if (!validation.valid) throw StateError('answer key is unresolved');

  final n = allAnswers.length;
  final totals = <int>[
    for (final answers in allAnswers)
      [
        for (var q = 1; q <= questionCount; q++)
          if (answers[q] == answerKey[q]) 1,
      ].length,
  ];
  final choices = <String>[...(validAnswers.toList()..sort()), ...unresolved];

  final result = <int, Map<String, Object?>>{};
  for (var q = 1; q <= questionCount; q++) {
    final counts = <String, int>{for (final choice in choices) choice: 0};
    for (final answers in allAnswers) {
      final given = answers[q] ?? 'BLANK';
      counts[given] = (counts[given] ?? 0) + 1;
    }
    final key = answerKey[q]!;
    final nCorrect = counts[key] ?? 0;
    final pctCorrect = n > 0 ? pyRound(nCorrect / n * 100, 1) : 0.0;

    String? mostCommonWrong;
    var best = 0;
    for (final entry in counts.entries) {
      if (validAnswers.contains(entry.key) && entry.key != key && entry.value > 0) {
        if (mostCommonWrong == null || entry.value > best) {
          mostCommonWrong = entry.key;
          best = entry.value;
        }
      }
    }

    final itemScores = <int>[
      for (final answers in allAnswers) answers[q] == key ? 1 : 0,
    ];
    final groupN = n > 0 ? math.max(1, pyRoundInt(n * 0.27)) : 0;

    // Stable, like Python's sort: equal totals keep their sheet order.
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final byTotal = totals[a].compareTo(totals[b]);
        return byTotal != 0 ? byTotal : a.compareTo(b);
      });
    double? discrimination;
    if (n >= 10) {
      final lower = order.take(groupN).map((i) => itemScores[i]);
      final upper = order.skip(n - groupN).map((i) => itemScores[i]);
      discrimination = pyRound(
        upper.fold<int>(0, (a, b) => a + b) / groupN -
            lower.fold<int>(0, (a, b) => a + b) / groupN,
        3,
      );
    }

    final missedPct = 100 - pctCorrect;
    result[q] = <String, Object?>{
      'correct_answer': key,
      'n_correct': nCorrect,
      'pct_correct': pctCorrect,
      'difficulty': pyRound(pctCorrect / 100, 3),
      'point_biserial': _pointBiserial(itemScores, totals),
      'upper_lower_discrimination': discrimination,
      'distribution': <String, Object?>{
        for (final entry in counts.entries)
          entry.key: <String, Object?>{
            'count': entry.value,
            'pct': n > 0 ? pyRound(entry.value / n * 100, 1) : 0.0,
          },
      },
      'most_common_wrong': mostCommonWrong,
      'flags': <String, Object?>{
        for (final threshold in flagThresholds) 'missed_$threshold': missedPct > threshold,
      },
    };
  }
  return result;
}

/// Class-wide figures. [scores] is keyed by sheet number, in filing order.
Map<String, Object?> classStatistics(
  Map<int, Map<String, Object?>> scores,
  Map<int, Map<String, Object?>> itemRows, [
  int questionCount = 50,
]) {
  final raw = <int>[for (final score in scores.values) score['correct']! as int];
  final result = <String, Object?>{
    'student_count': raw.length,
    'mean': raw.isNotEmpty ? pyRoundNum(pyMeanInts(raw), 2) : null,
    'median': raw.isNotEmpty ? pyRoundNum(pyMedianInts(raw), 2) : null,
    'standard_deviation': raw.length > 1 ? pyRound(pyStdevInts(raw), 2) : null,
    'minimum': raw.isNotEmpty ? raw.reduce(math.min) : null,
    'maximum': raw.isNotEmpty ? raw.reduce(math.max) : null,
    'kr20': null,
  };
  if (questionCount > 1 && raw.length > 1) {
    final variance = pyVarianceInts(raw);
    if (variance > 0) {
      final pqSum = pySumFloats(
        itemRows.values.map((row) {
          final difficulty = row['difficulty']! as double;
          return difficulty * (1 - difficulty);
        }),
      );
      result['kr20'] = pyRound(
        questionCount / (questionCount - 1) * (1 - pqSum / variance),
        3,
      );
    }
  }
  return result;
}
