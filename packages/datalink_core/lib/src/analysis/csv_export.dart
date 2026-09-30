/// CSV export and filenames. Ports of `records_to_csv` and
/// `safe_export_filename` in `server.py`.
library;

import '../protocol/python_compat.dart';

/// A filename that is safe on any filesystem: ASCII letters, digits, space,
/// dot, underscore and hyphen, with everything else replaced by `_`.
String safeExportFilename(String testName) {
  final buffer = StringBuffer();
  for (final unit in pyStrip(testName).codeUnits) {
    final isAscii = unit < 0x80;
    final isAlnum = (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x61 && unit <= 0x7a);
    final allowed = isAscii && (isAlnum || ' ._-'.codeUnits.contains(unit));
    buffer.writeCharCode(allowed ? unit : 0x5f);
  }
  var cleaned = buffer.toString();
  cleaned = _stripChars(cleaned, ' .');
  if (cleaned.isEmpty) cleaned = 'datalink-session';
  return cleaned.toLowerCase().endsWith('.csv') ? cleaned : '$cleaned.csv';
}

String _stripChars(String text, String chars) {
  var start = 0;
  var end = text.length;
  while (start < end && chars.contains(text[start])) {
    start++;
  }
  while (end > start && chars.contains(text[end - 1])) {
    end--;
  }
  return text.substring(start, end);
}

/// One CSV shape for both a live session and one replayed from history.
///
/// Returns text; callers encode it as UTF-8. Python's `csv.writer` terminates
/// rows with CRLF and quotes only fields that need it.
String recordsToCsv(
  List<Map<String, Object?>> records,
  String className,
  int fallbackColumns,
) {
  var maximum = fallbackColumns;
  if (records.isNotEmpty) {
    maximum = records
        .map((record) => (record['responses']! as List<Object?>).length)
        .reduce((a, b) => a > b ? a : b);
  }
  final rows = <List<String>>[
    [
      'Scan',
      'Role',
      'Class',
      'Student ID',
      'Student Name',
      'Received At',
      'Answered',
      for (var index = 1; index <= maximum; index++) 'Q$index',
    ],
    for (final record in records)
      [
        _text(record['number']),
        _text(record['role'] ?? 'student'),
        className,
        _text(record['student_id']),
        _text(record['student_name']),
        _text(record['received_at']),
        _text(record['answered_count']),
        for (final value in record['responses']! as List<Object?>) _text(value),
      ],
  ];
  final out = StringBuffer();
  for (final row in rows) {
    out
      ..writeAll(row.map(_csvField), ',')
      ..write('\r\n');
  }
  return out.toString();
}

/// `x or ""` then `str()`: None, "" and 0 all render as an empty string for
/// the optional columns, but a real 0 must stay 0 for the numeric ones.
String _text(Object? value) => value == null ? '' : value.toString();

String _csvField(String field) {
  final needsQuotes = field.contains(',') ||
      field.contains('"') ||
      field.contains('\r') ||
      field.contains('\n');
  if (!needsQuotes) return field;
  return '"${field.replaceAll('"', '""')}"';
}
