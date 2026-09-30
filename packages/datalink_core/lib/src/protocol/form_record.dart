import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';
import 'python_compat.dart';

/// Coerce and range-check a questions-per-form value.
int validateQuestionCount(Object? value) {
  final count = pyInt(value);
  if (count == null) {
    throw const DataLinkError('Questions per form must be a whole number');
  }
  if (count < minAnswerCount || count > maxAnswerCount) {
    throw const DataLinkError(
      'Questions per form must be between $minAnswerCount and $maxAnswerCount',
    );
  }
  return count;
}

/// One complete 211-field form record as the scanner sends it.
class DataLinkFormRecord {
  const DataLinkFormRecord({
    required this.receivedAt,
    required this.fields,
    required this.responses,
  });

  /// Parse one CSV line (no CRLF). Mirrors `DataLinkFormRecord.from_line`,
  /// including the order the checks run in, since the first to fail decides
  /// the message the teacher sees.
  factory DataLinkFormRecord.fromLine(
    Uint8List line, {
    Object? questionCount = defaultAnswerCount,
    DateTime Function()? now,
  }) {
    final count = validateQuestionCount(questionCount);
    for (final byte in line) {
      if (byte > 0x7f) throw const DataLinkError('Form record is not ASCII');
    }
    final text = String.fromCharCodes(line);

    final List<String> fields;
    try {
      fields = pyCsvRow(text);
    } on FormatException {
      throw const DataLinkError('Form record contains a stray line break');
    }
    if (fields.length != expectedFieldCount) {
      throw DataLinkError(
        'Expected $expectedFieldCount CSV fields; received ${fields.length}',
      );
    }

    final responses = <String>[
      for (final value in fields.sublist(answerStart, answerStart + count))
        pyStrip(value),
    ];
    final invalid = <String>{
      for (final value in responses)
        if (value != '' &&
            value != '*' &&
            !value.codeUnits.every((unit) => unit >= 0x41 && unit <= 0x45))
          value,
    };
    if (invalid.isNotEmpty) {
      final sorted = invalid.toList()..sort();
      throw DataLinkError('Unexpected response values: ${pyReprList(sorted)}');
    }

    return DataLinkFormRecord(
      receivedAt: pyIsoUtc((now ?? DateTime.now)()),
      fields: List.unmodifiable(fields),
      responses: List.unmodifiable(responses),
    );
  }

  /// ISO-8601 in UTC, formatted as Python's `isoformat()` does.
  final String receivedAt;
  final List<String> fields;
  final List<String> responses;

  /// The privacy-minimal view that is stored and logged. Key order matches the
  /// original because it is written to JSONL and read back by humans.
  Map<String, Object?> publicDict({bool includeRawFields = false}) {
    final scannerId = pyStrip(fields[studentIdField]);
    final marked = pyStrip(fields[scannerScoreField]);
    return <String, Object?>{
      'received_at': receivedAt,
      'responses': responses,
      'answered_count': responses.where((value) => value.isNotEmpty).length,
      'scanner_id': pyIsDigit(scannerId) ? scannerId : null,
      // The machine's own marking, to set beside ours.
      'scanner_score': pyIsDigit(marked) ? int.parse(marked) : null,
      if (includeRawFields) 'fields': fields,
    };
  }
}
