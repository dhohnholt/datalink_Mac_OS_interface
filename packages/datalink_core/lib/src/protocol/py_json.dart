/// `json.dumps` as Python writes it.
///
/// Three things depend on the exact bytes: the JSONL session logs (read back by
/// people and by older versions), the scan fingerprint (a SHA-256 over
/// `json.dumps(..., sort_keys=True)`, which decides whether a retried upload
/// keeps its run id), and the payload sent to T-TESS. Dart's own encoder
/// differs on float formatting and does not escape non-ASCII, so this one is
/// written to match and pinned by golden files.
library;

/// Encode [value] the way `json.dumps` would.
///
/// [indent] null gives the default one-line form with `', '` and `': '`
/// separators; [compact] gives `','` and `':'`; a number of spaces gives the
/// pretty form. [sortKeys] orders object keys by code point.
String pyJsonEncode(
  Object? value, {
  bool sortKeys = false,
  bool compact = false,
  int? indent,
}) {
  final out = StringBuffer();
  _write(out, value, sortKeys, compact, indent, 0);
  return out.toString();
}

void _write(
  StringBuffer out,
  Object? value,
  bool sortKeys,
  bool compact,
  int? indent,
  int depth,
) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int) {
    out.write(value.toString());
  } else if (value is double) {
    out.write(_floatRepr(value));
  } else if (value is String) {
    _string(out, value);
  } else if (value is Map) {
    final keys = value.keys.map(_keyString).toList();
    final byKey = <String, Object?>{
      for (final entry in value.entries) _keyString(entry.key): entry.value,
    };
    if (sortKeys) keys.sort();
    if (keys.isEmpty) {
      out.write('{}');
      return;
    }
    final itemSeparator = compact || indent != null ? ',' : ', ';
    final keySeparator = compact ? ':' : ': ';
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(itemSeparator);
      if (indent != null) out.write('\n${' ' * (indent * (depth + 1))}');
      _string(out, keys[i]);
      out.write(keySeparator);
      _write(out, byKey[keys[i]], sortKeys, compact, indent, depth + 1);
    }
    if (indent != null) out.write('\n${' ' * (indent * depth)}');
    out.write('}');
  } else if (value is Iterable) {
    final items = value.toList();
    if (items.isEmpty) {
      out.write('[]');
      return;
    }
    final itemSeparator = compact || indent != null ? ',' : ', ';
    out.write('[');
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.write(itemSeparator);
      if (indent != null) out.write('\n${' ' * (indent * (depth + 1))}');
      _write(out, items[i], sortKeys, compact, indent, depth + 1);
    }
    if (indent != null) out.write('\n${' ' * (indent * depth)}');
    out.write(']');
  } else {
    throw ArgumentError('Cannot encode ${value.runtimeType} as JSON');
  }
}

/// Python turns any key into text: ints as digits, bools as true/false, None as
/// null. Only strings and ints occur in this app; anything else is a bug.
String _keyString(Object? key) {
  if (key is String) return key;
  if (key is int) return key.toString();
  if (key is bool) return key ? 'true' : 'false';
  if (key == null) return 'null';
  throw ArgumentError('Cannot use ${key.runtimeType} as a JSON key');
}

void _string(StringBuffer out, String text) {
  out.write('"');
  for (final unit in text.codeUnits) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0c:
        out.write(r'\f');
      default:
        if (unit < 0x20 || unit > 0x7e) {
          // ensure_ascii: one \uXXXX per UTF-16 unit, so astral characters
          // become a surrogate pair exactly as Python writes them.
          out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
}

/// `repr(float)`: the shortest string that round-trips, positional for
/// exponents from -4 up to 15 and scientific otherwise, with a two-digit
/// exponent and an explicit sign (`1e-07`, `1e+16`).
String _floatRepr(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value.isNegative ? '-Infinity' : 'Infinity';
  if (value == 0) return value.isNegative ? '-0.0' : '0.0';

  // Dart's toString already yields the shortest round-trip digits; only the
  // layout differs, so pull out digits and exponent and lay them out again.
  final text = value.abs().toString();
  String digits;
  int exponent; // value = 0.d1d2d3... * 10^exponent
  final e = text.indexOf('e');
  if (e >= 0) {
    final mantissa = text.substring(0, e);
    final power = int.parse(text.substring(e + 1));
    final dot = mantissa.indexOf('.');
    final whole = dot < 0 ? mantissa : mantissa.substring(0, dot);
    final fraction = dot < 0 ? '' : mantissa.substring(dot + 1);
    digits = whole + fraction;
    exponent = whole.length + power;
  } else {
    final dot = text.indexOf('.');
    final whole = text.substring(0, dot);
    final fraction = text.substring(dot + 1);
    if (whole != '0') {
      digits = whole + fraction;
      exponent = whole.length;
    } else {
      final leading = fraction.length - fraction.replaceFirst(RegExp('^0+'), '').length;
      digits = fraction.substring(leading);
      exponent = -leading;
    }
  }
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  if (digits.isEmpty) digits = '0';

  final sign = value.isNegative ? '-' : '';
  // In Python's terms decpt == exponent; scientific when decpt > 16 or < -3.
  if (exponent > 16 || exponent < -3) {
    final first = digits[0];
    final rest = digits.length > 1 ? '.${digits.substring(1)}' : '';
    final power = exponent - 1;
    final powerSign = power < 0 ? '-' : '+';
    final powerText = power.abs().toString().padLeft(2, '0');
    return '$sign$first${rest}e$powerSign$powerText';
  }
  if (exponent <= 0) {
    return '${sign}0.${'0' * -exponent}$digits';
  }
  if (digits.length <= exponent) {
    return '$sign${digits.padRight(exponent, '0')}.0';
  }
  return '$sign${digits.substring(0, exponent)}.${digits.substring(exponent)}';
}
