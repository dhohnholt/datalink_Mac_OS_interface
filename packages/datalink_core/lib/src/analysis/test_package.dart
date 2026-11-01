/// Several versions of one test scored in one session, from a "test package"
/// CSV. A port of omr_final's `version_package.py`; `test/test_package_test.dart`
/// replays fixtures made by it.
///
///     Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer
///     original-3,Presidency,USG.7B,1,E,14,C
///
/// One row per item. "Version N" is the item's question number on version N;
/// "Version N answer" its answer there (several letters for a multiple-answer
/// item). Without answer columns, each version's key comes from its key sheet.
/// Students are scored on their own version; items are analysed across
/// versions, and results are grouped by standard and by section.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../protocol/py_math.dart';
import 'scoring.dart';

const int packageMaxQuestion = 75;

/// What to tell the assistant that writes the versions, so its file always
/// comes out in this shape. The same words as omr_final's `AGENT_PROMPT`.
const String testPackagePrompt = '''
Create the files for a multiple-version test that will be scored by the DataLink exam analyzer.

From the test versions I give you, write ONE CSV file named test-package.csv. Use exactly these column
headers, in this order, with one "Version N" and "Version N answer" pair for every version
(Version 1, Version 2, Version 3, Version 4 as needed):

Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer

Rules:
1. One row per test item. The same item appears in one row no matter where it sits on each version.
2. Stable item ID: a short, unique, permanent name for the item (letters, numbers and hyphens, e.g.
   presidency-veto-power). Reuse the same ID if the item appears on a later test.
3. Section: the part of the test the item belongs to (e.g. Presidency, CBA review, Vocabulary).
4. Standard: the standard the item assesses (e.g. USG.7B). Leave blank if none.
5. Version N: the item's question number as printed on version N (1 to 75). Each number is used once
   per version.
6. Version N answer: the correct letter on version N, A to E, after any shuffling of answer choices on
   that version. For an item with more than one correct answer, write every correct letter together
   with no spaces or commas, in alphabetical order (e.g. AC). Students must fill exactly those bubbles.
7. Every item must have a number and an answer for every version.
8. Plain CSV, UTF-8, no blank rows, no notes above or below the table. Quote any field that contains a
   comma.

Example:
Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer
presidency-veto-power,Presidency,USG.7B,1,E,14,C
presidency-cabinet,Presidency,USG.7B,2,E,3,D
cba-judicial-review,CBA review,USG.7C,26,C,25,A

Before you finish, check every row against each version's answer key and confirm that each version
uses each question number only once.
''';

/// A package that cannot be used, with every problem in the teacher's words.
class TestPackageException implements Exception {
  const TestPackageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TestPackage {
  TestPackage({
    required this.items,
    required this.versions,
    required this.numbers,
    required this.answers,
    required this.sections,
    required this.standards,
    this.form,
    this.options = const {},
  });

  /// Item IDs, in file order.
  final List<String> items;

  /// e.g. `['1', '2']`.
  final List<String> versions;

  /// version -> item -> question number on that version.
  final Map<String, Map<String, int>> numbers;

  /// version -> item -> answer; empty when the file has no answer columns.
  final Map<String, Map<String, String>> answers;
  final Map<String, String> sections;
  final Map<String, String> standards;

  /// The printable sheet a package was made from, when the app built it from
  /// a vocabulary or matching sheet's key; null for a teacher's package.
  final String? form;

  /// item -> its answer letters when they run past E (matching, A-J or A-O).
  final Map<String, String> options;

  bool get hasAnswers => answers.isNotEmpty;

  /// The highest question number any version uses: the session's length.
  int get questionCount => [for (final v in versions) ...numbers[v]!.values].reduce(math.max);

  Map<String, Object?> toJson() => <String, Object?>{
        'items': items,
        'versions': versions,
        'numbers': numbers,
        'answers': answers,
        'sections': sections,
        'standards': standards,
        if (form != null) 'form': form,
        if (options.isNotEmpty) 'options': options,
      };

  factory TestPackage.fromJson(Map<String, Object?> json) {
    Map<String, Map<String, T>> nested<T>(Object? value) => {
          for (final entry in ((value as Map?) ?? const {}).entries)
            '${entry.key}': {
              for (final inner in (entry.value as Map).entries) '${inner.key}': inner.value as T,
            },
        };
    return TestPackage(
      items: [for (final i in json['items']! as List) '$i'],
      versions: [for (final v in json['versions']! as List) '$v'],
      numbers: nested<int>(json['numbers']),
      answers: nested<String>(json['answers']),
      sections: {for (final e in (json['sections']! as Map).entries) '${e.key}': '${e.value}'},
      standards: {for (final e in (json['standards']! as Map).entries) '${e.key}': '${e.value}'},
      form: json['form'] as String?,
      options: {for (final e in ((json['options'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    );
  }

  static TestPackage parse(String text) => _parse(text);
}

/// One CSV record per line, honouring quotes, as Python's csv module does for
/// the files an assistant writes.
List<List<String>> _csvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String? _normalizedAnswer(String text) {
  final letters = (text.trim().toUpperCase().replaceAll(RegExp('[ ,]'), '').split('').toSet().toList()..sort()).join();
  if (letters.isEmpty || !(validAnswers.contains(letters) || isMultipleAnswerKey(letters))) return null;
  return letters;
}

TestPackage _parse(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final rows = [
    for (final row in _csvRows(text))
      if (row.any((cell) => cell.trim().isNotEmpty)) row,
  ];
  if (rows.isEmpty) throw const TestPackageException('The test package is empty.');
  final lower = [for (final cell in rows.first) cell.trim().toLowerCase()];
  int? column(List<String> names) {
    for (final name in names) {
      final index = lower.indexOf(name);
      if (index >= 0) return index;
    }
    return null;
  }

  final idCol = column(['stable item id', 'item id', 'item']);
  if (idCol == null) throw const TestPackageException('The test package needs a "Stable item ID" column.');
  final sectionCol = column(['section']);
  final standardCol = column(['standard', 'teks']);
  final numberCols = <String, int>{};
  final answerCols = <String, int>{};
  for (var i = 0; i < lower.length; i++) {
    final number = RegExp(r'^(?:version|v)\s*([1-4])$').firstMatch(lower[i]);
    if (number != null) numberCols[number.group(1)!] = i;
    final answer = RegExp(r'^(?:version|v)\s*([1-4])\s*(?:answer|key)$').firstMatch(lower[i]);
    if (answer != null) answerCols[answer.group(1)!] = i;
  }
  final versions = numberCols.keys.toList()..sort();
  if (versions.isEmpty) {
    throw const TestPackageException('The test package needs a column per version, such as "Version 1".');
  }
  final hasAnswers = answerCols.isNotEmpty;
  if (hasAnswers && !(answerCols.keys.toList()..sort()).every(versions.contains) ||
      hasAnswers && answerCols.length != versions.length) {
    throw TestPackageException(
      'Every version needs an answer column: found answers for version(s) '
      '${(answerCols.keys.toList()..sort()).join(', ')} and numbers for ${versions.join(', ')}.',
    );
  }

  final problems = <String>[];
  final items = <String>[];
  final sections = <String, String>{};
  final standards = <String, String>{};
  final numbers = {for (final v in versions) v: <String, int>{}};
  final answers = hasAnswers ? {for (final v in versions) v: <String, String>{}} : <String, Map<String, String>>{};
  final used = {for (final v in versions) v: <int, String>{}};
  for (var r = 1; r < rows.length; r++) {
    final line = r + 1;
    final row = rows[r];
    String cell(int? i) => i != null && i < row.length ? row[i].trim() : '';
    final item = cell(idCol);
    if (item.isEmpty) {
      problems.add('line $line: no Stable item ID');
      continue;
    }
    if (sections.containsKey(item)) {
      problems.add('line $line: item $item appears twice');
      continue;
    }
    items.add(item);
    sections[item] = cell(sectionCol);
    standards[item] = cell(standardCol);
    for (final v in versions) {
      final text = cell(numberCols[v]);
      final q = int.tryParse(text);
      if (q == null || q < 1 || q > packageMaxQuestion || '$q' != text) {
        problems.add("line $line: Version $v must be a question number from 1 to $packageMaxQuestion, not '$text'");
        continue;
      }
      if (used[v]!.containsKey(q)) {
        problems.add('line $line: Version $v question $q is already item ${used[v]![q]}');
        continue;
      }
      used[v]![q] = item;
      numbers[v]![item] = q;
      if (hasAnswers) {
        final answer = _normalizedAnswer(cell(answerCols[v]));
        if (answer == null) {
          problems.add("line $line: Version $v answer must be letters A-E, not '${cell(answerCols[v])}'");
        } else {
          answers[v]![item] = answer;
        }
      }
    }
  }
  if (items.isEmpty) problems.add('the test package has no items');
  if (problems.isNotEmpty) {
    throw TestPackageException('The test package has problems:\n  ${problems.join('\n  ')}');
  }
  return TestPackage(
    items: items,
    versions: versions,
    numbers: numbers,
    answers: answers,
    sections: sections,
    standards: standards,
  );
}

// ------------------------------------------------------------------ scoring

/// One sheet as the package analysis sees it.
class PackageSheet {
  const PackageSheet({
    required this.page,
    required this.version,
    required this.responses,
    this.studentId,
    this.studentName,
    this.confidence = const {},
  });

  final int page;
  final String? version;

  /// Question -> what was read: a letter, `BLANK`, `MULTIPLE`, or the letters
  /// of a double mark (`AC`).
  final Map<int, String> responses;
  final String? studentId;
  final String? studentName;
  final Map<int, Object?> confidence;
}

double? _pointBiserial(List<int> itemScores, List<int> totals) {
  final n = itemScores.length;
  if (n < 3 || itemScores.toSet().length < 2) return null;
  final rest = [for (var i = 0; i < n; i++) totals[i] - itemScores[i]];
  if (rest.toSet().length < 2) return null;
  final p = itemScores.reduce((a, b) => a + b) / n;
  final right = [for (var i = 0; i < n; i++) if (itemScores[i] != 0) rest[i]];
  final wrong = [for (var i = 0; i < n; i++) if (itemScores[i] == 0) rest[i]];
  final sd = pyStdevInts(rest);
  if (sd == 0) return null;
  return pyRound(((pyMeanInts(right) - pyMeanInts(wrong)) / sd) * math.sqrt(p * (1 - p)), 3);
}

/// What the stack holds, checked against the package: the key each version
/// is scored on, and any disagreement between the package and a key sheet.
({Map<String, Map<String, String>> keys, List<Map<String, Object?>> mismatches, List<String> errors})
    packageKeys(TestPackage package, List<PackageSheet> keySheets) {
  final byVersion = <String, PackageSheet>{};
  for (final sheet in keySheets) {
    final v = sheet.version;
    if (v != null && package.versions.contains(v)) byVersion.putIfAbsent(v, () => sheet);
  }
  final keys = <String, Map<String, String>>{};
  final mismatches = <Map<String, Object?>>[];
  final errors = <String>[];
  for (final v in package.versions) {
    final sheet = byVersion[v];
    final read = <String, String>{
      if (sheet != null)
        for (final item in package.items) item: sheet.responses[package.numbers[v]![item]] ?? 'BLANK',
    };
    if (package.hasAnswers) {
      keys[v] = Map.of(package.answers[v]!);
      for (final entry in read.entries) {
        if (entry.value != keys[v]![entry.key]) {
          mismatches.add({
            'version': v,
            'question': package.numbers[v]![entry.key],
            'item': entry.key,
            'package': keys[v]![entry.key],
            'key_sheet': entry.value,
            'key_page': sheet!.page,
          });
        }
      }
    } else if (sheet == null) {
      errors.add('No answer key sheet bubbled with version $v was found, and the package has no answers.');
    } else {
      final bad = [
        for (final entry in read.entries)
          if (!(validAnswers.contains(entry.value) || isMultipleAnswerKey(entry.value)))
            package.numbers[v]![entry.key]!,
      ]..sort();
      if (bad.isNotEmpty) {
        errors.add('The version $v key sheet (page ${sheet.page}) could not be read on question(s) ${bad.join(', ')}.');
      }
      keys[v] = read;
    }
  }
  return (keys: keys, mismatches: mismatches, errors: errors);
}

/// The report for a package session: the same shape the Analysis screen reads
/// for any test, with each student scored on their own version, items keyed by
/// their version 1 number, and `standards` / `sections` added.
Map<String, Object?> buildPackageAnalysis({
  required TestPackage package,
  required List<PackageSheet> keySheets,
  required List<PackageSheet> sheets,
  required String examName,
  required String sourceFile,
  required String runId,
  required String createdAt,
  List<int> flagThresholds = const [25, 40, 50],
  Set<String> dismissed = const {},
  String Function(Map<String, Object?> item)? reviewKeyOf,
}) {
  final keyed = packageKeys(package, keySheets);
  if (keyed.errors.isNotEmpty) throw TestPackageException(keyed.errors.join('\n'));
  final keys = keyed.keys;

  final reviewItems = <Map<String, Object?>>[];
  final students = <PackageSheet>[];
  final excluded = <Map<String, Object?>>[];
  for (final sheet in sheets) {
    if (sheet.version != null && package.versions.contains(sheet.version)) {
      students.add(sheet);
    } else if (sheet.version == null && package.versions.length == 1) {
      // A teacher's package names its versions, so a sheet without one is
      // worth a look; a sheet read against its own key has nothing to choose.
      students.add(PackageSheet(
        page: sheet.page,
        version: package.versions.first,
        responses: sheet.responses,
        studentId: sheet.studentId,
        studentName: sheet.studentName,
        confidence: sheet.confidence,
      ));
      if (package.form == null) {
        reviewItems.add({'page': sheet.page, 'field': 'version', 'value': null, 'reason': 'version'});
      }
    } else {
      excluded.add({'page': sheet.page, 'reason': sheet.version == null ? 'no version bubbled' : 'version ${sheet.version}'});
    }
  }
  if (students.isEmpty) {
    throw const TestPackageException('No student sheets bubbled with a version in the package were found.');
  }
  students.sort((a, b) => a.page.compareTo(b.page));

  bool right(PackageSheet s, String item) {
    final q = package.numbers[s.version]![item]!;
    final given = s.responses[q] ?? 'BLANK';
    // A double mark is stored as its letters, so a multiple-answer key is
    // matched exactly by the same comparison.
    return given == keys[s.version]![item]!;
  }

  final correct = {for (final s in students) s.page: {for (final item in package.items) item: right(s, item) ? 1 : 0}};
  final totals = [for (final s in students) correct[s.page]!.values.reduce((a, b) => a + b)];
  final total = package.items.length;

  for (final s in students) {
    final id = s.studentId;
    if (id == null || id.isEmpty || id.contains('_') || id.contains('?') || !RegExp(r'^\d+$').hasMatch(id)) {
      reviewItems.add({'page': s.page, 'field': 'student_id', 'value': null});
    }
    for (final item in package.items) {
      final q = package.numbers[s.version]![item]!;
      final given = s.responses[q] ?? 'BLANK';
      final key = keys[s.version]![item]!;
      final several = given.length > 1 && given != 'BLANK' && given != 'MULTIPLE' || given == 'MULTIPLE';
      final confidence = s.confidence[q];
      final unsure = confidence is Map && confidence['needs_review'] == true;
      if ((several && key.length == 1) || (unsure && !(several && key.length > 1))) {
        reviewItems.add({
          'page': s.page,
          'field': 'answer',
          'question': q,
          'value': several ? 'MULTIPLE' : given,
          'reason': several ? 'multiple' : 'faint',
        });
      }
    }
  }
  for (final m in keyed.mismatches) {
    reviewItems.add({
      'page': 0,
      'field': 'note',
      'question': m['question'],
      'reason': 'key_mismatch',
      'value': 'Version ${m['version']} question ${m['question']} (${m['item']}): the package says '
          '${m['package']}, the key sheet on page ${m['key_page']} shows ${m['key_sheet']}.',
    });
  }
  final kept = [
    for (final item in reviewItems)
      if (reviewKeyOf == null || !dismissed.contains(reviewKeyOf(item))) item,
  ];

  // Items, across versions, keyed by their version 1 number.
  final n = students.length;
  final groupN = n > 0 ? math.max(1, pyRoundInt(n * 0.27)) : 0;
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final byTotal = totals[a].compareTo(totals[b]);
      return byTotal != 0 ? byTotal : a.compareTo(b);
    });
  final first = package.versions.first;
  final items = <Map<String, Object?>>[];
  for (final item in package.items) {
    final scores = [for (final s in students) correct[s.page]![item]!];
    final nCorrect = scores.reduce((a, b) => a + b);
    final pct = pyRound(nCorrect / n * 100, 1);
    final byVersion = <String, Object?>{};
    final wrongByVersion = <String, Object?>{};
    for (final v in package.versions) {
      final onV = [for (final s in students) if (s.version == v) s];
      byVersion[v] = onV.isEmpty
          ? null
          : pyRound(onV.where((s) => correct[s.page]![item] == 1).length / onV.length * 100, 1);
      final counts = <String, int>{};
      for (final s in onV) {
        final given = s.responses[package.numbers[v]![item]] ?? 'BLANK';
        if (correct[s.page]![item] == 0 && given != 'BLANK') counts[given] = (counts[given] ?? 0) + 1;
      }
      String? best;
      for (final e in counts.entries) {
        if (best == null || e.value > counts[best]!) best = e.key;
      }
      wrongByVersion[v] = best;
    }
    double? discrimination;
    if (n >= 10) {
      final lower = order.take(groupN).map((i) => scores[i]).reduce((a, b) => a + b);
      final upper = order.skip(n - groupN).map((i) => scores[i]).reduce((a, b) => a + b);
      discrimination = pyRound(upper / groupN - lower / groupN, 3);
    }
    final mostWrong = [
      for (final v in package.versions)
        if (wrongByVersion[v] != null) 'V$v ${wrongByVersion[v]}',
    ].join(' · ');
    items.add(<String, Object?>{
      'question': package.numbers[first]![item],
      'item': item,
      'section': package.sections[item],
      'standard': package.standards[item],
      'questions': {for (final v in package.versions) v: package.numbers[v]![item]},
      'answers': {for (final v in package.versions) v: keys[v]![item]},
      'correct_answer': [for (final v in package.versions) 'V$v ${keys[v]![item]}'].join(' · '),
      'n_correct': nCorrect,
      'percent_correct': pct,
      'difficulty': pyRound(nCorrect / n, 3),
      'point_biserial': _pointBiserial(scores, totals),
      'upper_lower_discrimination': discrimination,
      'pct_correct_by_version': byVersion,
      'most_common_wrong_by_version': wrongByVersion,
      'most_common_wrong': mostWrong.isEmpty ? null : mostWrong,
      // Letters mean different choices on each version, so there is no
      // combined A-E spread; the table shows dashes.
      'distribution': const <String, Object?>{},
      'flags': [
        for (final t in flagThresholds)
          if (100 - pct > t) 'missed_$t',
      ],
    });
  }
  items.sort((a, b) => (a['question']! as int).compareTo(b['question']! as int));

  double? kr20;
  if (total > 1 && n > 1) {
    final variance = pyVarianceInts(totals) * (n - 1) / n;
    if (variance > 0) {
      final pq = items.fold<double>(0, (sum, i) {
        final d = i['difficulty']! as double;
        return sum + d * (1 - d);
      });
      kr20 = pyRound(total / (total - 1) * (1 - pq / variance), 3);
    }
  }
  final mean = n > 0 ? totals.reduce((a, b) => a + b) / n : null;
  final sorted = [...totals]..sort();
  final median = n == 0 ? null : (n.isOdd ? sorted[n ~/ 2].toDouble() : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2);
  final stats = <String, Object?>{
    'student_count': n,
    'mean': mean == null ? null : pyRound(mean, 2),
    'median': median == null ? null : pyRound(median, 2),
    'standard_deviation': n > 1 ? pyRound(pyStdevInts(totals), 2) : null,
    'minimum': n > 0 ? sorted.first : null,
    'maximum': n > 0 ? sorted.last : null,
    'kr20': kr20,
  };

  Map<String, Map<String, Object?>> grouped(Map<String, String> field) {
    final groups = <String, List<String>>{};
    for (final item in package.items) {
      final name = (field[item] ?? '').isEmpty ? '(none)' : field[item]!;
      (groups[name] ??= []).add(item);
    }
    return {
      for (final entry in groups.entries)
        entry.key: <String, Object?>{
          'items': entry.value.length,
          'class_pct': pyRound(
            students.fold<int>(0, (sum, s) => sum + entry.value.where((i) => correct[s.page]![i] == 1).length) /
                (entry.value.length * n) *
                100,
            1,
          ),
          'by_page': {
            for (final s in students) '${s.page}': entry.value.where((i) => correct[s.page]![i] == 1).length,
          },
        },
    };
  }

  final standards = grouped(package.standards);
  final sections = grouped(package.sections);

  final studentRows = <Map<String, Object?>>[];
  for (var index = 0; index < n; index++) {
    final s = students[index];
    final v = s.version!;
    final itemAt = {for (final item in package.items) package.numbers[v]![item]!: item};
    final missed = [for (final item in package.items) if (correct[s.page]![item] == 0) package.numbers[v]![item]!]
      ..sort();
    final responses = [for (var q = 1; q <= package.questionCount; q++) s.responses[q] ?? 'BLANK'];
    final scored = [for (final item in package.items) s.responses[package.numbers[v]![item]] ?? 'BLANK'];
    final points = totals[index];
    studentRows.add(<String, Object?>{
      'page': s.page,
      'student_id': s.studentId,
      'student_id_read': s.studentId,
      'student_name': s.studentName,
      'version': v,
      'score': <String, Object?>{
        'correct': points,
        'incorrect': total - points - scored.where((g) => g == 'BLANK').length -
            scored.where((g) => g == 'MULTIPLE' || g.length > 1 && g != 'BLANK').length,
        'blank': scored.where((g) => g == 'BLANK').length,
        'multiple': scored.where((g) => g == 'MULTIPLE' || g.length > 1 && g != 'BLANK').length,
        'total': total,
        'percentage': pyRound(points / total * 100, 1),
        'missed_questions': missed,
      },
      'standards': {
        for (final entry in standards.entries)
          entry.key: {'correct': (entry.value['by_page']! as Map)['${s.page}'], 'items': entry.value['items']},
      },
      // In the student's own question order, so a sheet edited in Review
      // keeps its responses where they were read.
      'answers': [
        for (var q = 1; q <= package.questionCount; q++)
          <String, Object?>{
            'question': q,
            'response': responses[q - 1].length > 1 && responses[q - 1] != 'BLANK' ? 'MULTIPLE' : responses[q - 1],
            if (responses[q - 1].length > 1 && responses[q - 1] != 'BLANK' && responses[q - 1] != 'MULTIPLE')
              'marks': responses[q - 1],
            'item': itemAt[q],
            // The letters this question offers, for Review's answer menu.
            if (itemAt[q] != null && package.options.containsKey(itemAt[q])) 'options': package.options[itemAt[q]],
            'correct_answer': itemAt[q] == null ? null : keys[v]![itemAt[q]],
            'correct': itemAt[q] != null && correct[s.page]![itemAt[q]] == 1,
            'confidence': s.confidence[q] ?? const <String, Object?>{},
          },
      ],
    });
  }

  return <String, Object?>{
    'schema_version': '1.0',
    'run_id': runId,
    'status': 'completed',
    'created_at': createdAt,
    'exam': <String, Object?>{
      'name': examName,
      'source_file': sourceFile,
      'source_type': 'pdf_scan',
      'form': 'package',
      if (package.form != null) 'sheet_form': package.form,
      'student_id_scanning': true,
      'question_count': total,
      'versions': package.versions,
      'key_source': package.hasAnswers ? 'package' : 'key sheets',
      'items': [
        for (final i in items)
          {for (final k in ['item', 'section', 'standard', 'questions', 'answers']) k: i[k]},
      ],
      'answer_key': [for (final i in items) {'question': i['question'], 'answer': i['correct_answer']}],
    },
    'summary': <String, Object?>{
      ...stats,
      'mean_percentage': mean == null ? null : pyRound(mean / total * 100, 1),
      'median_percentage': median == null ? null : pyRound(median / total * 100, 1),
    },
    'students': studentRows,
    'items': items,
    'standards': {
      for (final e in standards.entries) e.key: {'items': e.value['items'], 'class_pct': e.value['class_pct']},
    },
    'sections': {
      for (final e in sections.entries) e.key: {'items': e.value['items'], 'class_pct': e.value['class_pct']},
    },
    'review_items': kept,
    'key_mismatches': keyed.mismatches,
    'not_scored': excluded,
    'warnings': [
      if (keyed.mismatches.isNotEmpty) {'code': 'key_mismatch', 'count': keyed.mismatches.length},
      if (kept.isNotEmpty) {'code': 'review_required', 'count': kept.length},
    ],
    'corrections': const <Object?>[],
  };
}

/// The package a session carries, or null for an ordinary test.
TestPackage? packageOf(Map<String, Object?> session) {
  final text = session['package'];
  if (text is! String || text.isEmpty) return null;
  return TestPackage.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
}
