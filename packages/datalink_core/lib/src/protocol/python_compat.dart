/// The small pieces of Python behaviour the port has to reproduce exactly.
///
/// Every function here is pinned to the reference by the golden files, so a
/// difference shows up as a failing test rather than as a subtly different
/// message on a teacher's screen.
library;

/// Whitespace as `str.strip()` sees it for ASCII input: the usual six plus the
/// four information separators `\x1c`..`\x1f`, which `str.isspace()` counts.
bool _isPySpace(int unit) =>
    unit == 0x20 || (unit >= 0x09 && unit <= 0x0d) || (unit >= 0x1c && unit <= 0x1f);

/// `str.strip()` for the ASCII text this app handles.
String pyStrip(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _isPySpace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isPySpace(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/// `str.isdigit()` restricted to ASCII: non-empty and every unit is 0-9.
bool pyIsDigit(String text) {
  if (text.isEmpty) return false;
  for (final unit in text.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// `repr(str)`, as it appears in error messages built with `{value!r}`.
String pyRepr(String text) {
  final hasSingle = text.contains("'");
  final hasDouble = text.contains('"');
  final quote = hasSingle && !hasDouble ? '"' : "'";
  final out = StringBuffer(quote);
  for (final rune in text.runes) {
    if (rune == 0x5c) {
      out.write(r'\\');
    } else if (rune == quote.codeUnitAt(0)) {
      out.write('\\$quote');
    } else if (rune == 0x0a) {
      out.write(r'\n');
    } else if (rune == 0x0d) {
      out.write(r'\r');
    } else if (rune == 0x09) {
      out.write(r'\t');
    } else if (rune < 0x20 || rune == 0x7f) {
      out.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(rune);
    }
  }
  out.write(quote);
  return out.toString();
}

/// `repr(list_of_str)`, e.g. `['Z', 'Q']`.
String pyReprList(Iterable<String> items) =>
    '[${items.map(pyRepr).join(', ')}]';

/// `int(value)` for the values a caller can plausibly hand over, or null when
/// Python would raise ValueError or TypeError.
///
/// Accepts ints, finite doubles (truncated toward zero), and strings the way
/// Python reads them: surrounding whitespace, an optional sign, digits, and
/// single underscores between digits.
int? pyInt(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is String) {
    final text = pyStrip(value);
    final match = RegExp(r'^([+-]?)([0-9]+(?:_[0-9]+)*)$').firstMatch(text);
    if (match == null) return null;
    final digits = match.group(2)!.replaceAll('_', '');
    final parsed = int.tryParse(digits);
    if (parsed == null) return null;
    return match.group(1) == '-' ? -parsed : parsed;
  }
  return null;
}

/// `datetime.isoformat()` for a UTC instant: `+00:00` rather than `Z`, and the
/// fractional part present only when the microsecond is non-zero.
String pyIsoUtc(DateTime when) {
  final utc = when.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final micros = utc.millisecond * 1000 + utc.microsecond;
  final year = utc.year.toString().padLeft(4, '0');
  final date = '$year-${two(utc.month)}-${two(utc.day)}';
  final time = '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
  final fraction = micros == 0 ? '' : '.${micros.toString().padLeft(6, '0')}';
  return '${date}T$time$fraction+00:00';
}

/// `next(csv.reader([text]))` with the default `excel` dialect.
///
/// Reproduces the reader's state machine, including the lenient cases: a quote
/// inside an unquoted field is literal, and a character after a closing quote
/// is appended to the field.
///
/// Deliberate difference: Python raises `csv.Error` when the line contains a
/// bare CR or LF. In the original that escaped the stream parser and killed the
/// read loop. Here it is an [FormatException], which the caller turns into an
/// ordinary "unreadable record" so one stray byte cannot stop a session.
List<String> pyCsvRow(String text) {
  if (text.contains('\r') || text.contains('\n')) {
    throw const FormatException('line break inside a record');
  }
  final fields = <String>[];
  final field = StringBuffer();
  var state = _CsvState.startField;
  var sawAny = false;

  void save() {
    fields.add(field.toString());
    field.clear();
  }

  for (final unit in text.codeUnits) {
    final char = String.fromCharCode(unit);
    sawAny = true;
    switch (state) {
      case _CsvState.startField:
        if (char == '"') {
          state = _CsvState.inQuoted;
        } else if (char == ',') {
          save();
        } else {
          field.write(char);
          state = _CsvState.inField;
        }
      case _CsvState.inField:
        if (char == ',') {
          save();
          state = _CsvState.startField;
        } else {
          field.write(char);
        }
      case _CsvState.inQuoted:
        if (char == '"') {
          state = _CsvState.quoteInQuoted;
        } else {
          field.write(char);
        }
      case _CsvState.quoteInQuoted:
        if (char == '"') {
          field.write('"');
          state = _CsvState.inQuoted;
        } else if (char == ',') {
          save();
          state = _CsvState.startField;
        } else {
          field.write(char);
          state = _CsvState.inField;
        }
    }
  }
  if (!sawAny) return <String>[];
  // End of input: every state but "just after a comma" holds a field. After a
  // trailing comma Python still emits the final empty field.
  save();
  return fields;
}

enum _CsvState { startField, inField, inQuoted, quoteInQuoted }
