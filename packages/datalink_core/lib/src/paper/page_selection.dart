/// Which pages of a scan to analyse. A port of `vendor/omr/page_selection.py`.
library;

/// Expands `all`, `odd`, `even` or a comma-separated list such as `1,3,7-15`.
/// Throws [FormatException] with the reader's own wording.
Set<int> parsePageSpec(String spec, int totalPages) {
  final normalized = spec.trim().toLowerCase();
  if (normalized == 'all') return {for (var p = 1; p <= totalPages; p++) p};
  if (normalized == 'odd') return {for (var p = 1; p <= totalPages; p += 2) p};
  if (normalized == 'even') return {for (var p = 2; p <= totalPages; p += 2) p};
  if (normalized.isEmpty) return <int>{};

  final selected = <int>{};
  for (final raw in normalized.split(',')) {
    final token = raw.trim();
    if (token.isEmpty) throw const FormatException('empty page entry');
    if (token.contains('-')) {
      final parts = token.split('-');
      if (parts.length != 2 || !parts.every((part) => _isDigits(part.trim()))) {
        throw FormatException('invalid page range: ${_repr(token)}');
      }
      final start = int.parse(parts[0].trim());
      final end = int.parse(parts[1].trim());
      if (start > end) throw FormatException('page range starts after it ends: ${_repr(token)}');
      for (var p = start; p <= end; p++) {
        selected.add(p);
      }
    } else if (_isDigits(token)) {
      selected.add(int.parse(token));
    } else {
      throw FormatException('invalid page entry: ${_repr(token)}');
    }
  }
  final outside = (selected.where((p) => p < 1 || p > totalPages).toList()..sort());
  if (outside.isNotEmpty) {
    throw FormatException("page(s) outside this PDF's 1-$totalPages range: $outside");
  }
  return selected;
}

bool _isDigits(String text) => text.isNotEmpty && text.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

String _repr(String text) => "'$text'";
