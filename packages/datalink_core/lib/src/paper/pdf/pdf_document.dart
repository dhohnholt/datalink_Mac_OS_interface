/// A small PDF reader: enough to find the pages of a scanned document and the
/// picture on each one.
///
/// It is not a general PDF library. The batches this app reads come from
/// document scanners, where a page is a picture and nothing else, so what is
/// needed is: the object tree, the page list, stream filters for the picture,
/// and a way to recover when the cross-reference table lies (copiers and
/// scanners write those wrongly often enough that poppler's rebuild step is
/// something the Python app relied on without anyone noticing).
library;

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

/// A file the reader cannot use, in words for a teacher.
class PdfException implements Exception {
  const PdfException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A page this reader can't draw. Distinct from [PdfException] so a caller can
/// say "this PDF is not a scanned sheet" rather than "this is not a PDF".
class PdfUnsupported extends PdfException {
  const PdfUnsupported(super.message);
}

class PdfName {
  const PdfName(this.value);
  final String value;
  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '/$value';
}

class PdfRef {
  const PdfRef(this.number, this.generation);
  final int number;
  final int generation;
  @override
  String toString() => '$number $generation R';
}

class PdfString {
  const PdfString(this.bytes);
  final Uint8List bytes;
}

/// An operator in a content stream.
class PdfKeyword {
  const PdfKeyword(this.value);
  final String value;
  @override
  String toString() => value;
}

typedef PdfDict = Map<String, Object?>;

class PdfStream {
  PdfStream(this.dict, this.raw);
  final PdfDict dict;
  final Uint8List raw;
}

bool _isWhite(int c) => c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
bool _isDelimiter(int c) =>
    c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D ||
    c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;
bool _isRegular(int c) => !_isWhite(c) && !_isDelimiter(c);

/// Reads objects from bytes. Used for the file and for content streams.
class PdfLexer {
  PdfLexer(this.bytes, [this.pos = 0]);

  final Uint8List bytes;
  int pos;

  bool get atEnd {
    skipWhite();
    return pos >= bytes.length;
  }

  void skipWhite() {
    while (pos < bytes.length) {
      final c = bytes[pos];
      if (_isWhite(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < bytes.length && bytes[pos] != 10 && bytes[pos] != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  /// The next object, or a [PdfKeyword] for anything bare (`obj`, `stream`,
  /// operators). With [allowRefs] set, `1 0 R` becomes a [PdfRef].
  Object? read({bool allowRefs = true}) {
    skipWhite();
    if (pos >= bytes.length) throw const PdfException('Unexpected end of data');
    final c = bytes[pos];
    if (c == 0x3C) {
      if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3C) {
        pos += 2;
        return _readDict(allowRefs);
      }
      return _readHexString();
    }
    if (c == 0x5B) {
      pos++;
      final list = <Object?>[];
      while (true) {
        skipWhite();
        if (pos >= bytes.length) throw const PdfException('Unterminated array');
        if (bytes[pos] == 0x5D) {
          pos++;
          return list;
        }
        list.add(read(allowRefs: allowRefs));
      }
    }
    if (c == 0x28) return _readLiteralString();
    if (c == 0x2F) return _readName();
    if (c == 0x29 || c == 0x3E || c == 0x5D || c == 0x7B || c == 0x7D) {
      pos++;
      return PdfKeyword(String.fromCharCode(c));
    }
    final start = pos;
    while (pos < bytes.length && _isRegular(bytes[pos])) {
      pos++;
    }
    final text = latin1.decode(bytes.sublist(start, pos));
    final number = _number(text);
    if (number != null) {
      if (allowRefs && number is int && number >= 0) {
        final save = pos;
        final generation = _tryInt();
        if (generation != null) {
          skipWhite();
          if (pos < bytes.length && bytes[pos] == 0x52 &&
              (pos + 1 >= bytes.length || !_isRegular(bytes[pos + 1]))) {
            pos++;
            return PdfRef(number, generation);
          }
        }
        pos = save;
      }
      return number;
    }
    switch (text) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    return PdfKeyword(text);
  }

  int? _tryInt() {
    skipWhite();
    final start = pos;
    while (pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x39) {
      pos++;
    }
    if (pos == start || (pos < bytes.length && _isRegular(bytes[pos]))) {
      pos = start;
      return null;
    }
    return int.parse(latin1.decode(bytes.sublist(start, pos)));
  }

  static num? _number(String text) {
    if (text.isEmpty) return null;
    final first = text.codeUnitAt(0);
    final numeric = (first >= 0x30 && first <= 0x39) || first == 0x2B || first == 0x2D || first == 0x2E;
    if (!numeric) return null;
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    return double.tryParse(text);
  }

  PdfDict _readDict(bool allowRefs) {
    final dict = <String, Object?>{};
    while (true) {
      skipWhite();
      if (pos >= bytes.length) throw const PdfException('Unterminated dictionary');
      if (bytes[pos] == 0x3E) {
        pos += 2;
        return dict;
      }
      final key = read(allowRefs: false);
      if (key is! PdfName) throw const PdfException('Dictionary key is not a name');
      skipWhite();
      if (pos < bytes.length && bytes[pos] == 0x3E) {
        dict[key.value] = null;
        continue;
      }
      dict[key.value] = read(allowRefs: allowRefs);
    }
  }

  PdfName _readName() {
    pos++;
    final out = <int>[];
    while (pos < bytes.length && _isRegular(bytes[pos])) {
      var c = bytes[pos++];
      if (c == 0x23 && pos + 1 < bytes.length) {
        final value = int.tryParse(latin1.decode(bytes.sublist(pos, pos + 2)), radix: 16);
        if (value != null) {
          c = value;
          pos += 2;
        }
      }
      out.add(c);
    }
    return PdfName(latin1.decode(out));
  }

  PdfString _readHexString() {
    pos++;
    final digits = <int>[];
    while (pos < bytes.length && bytes[pos] != 0x3E) {
      final value = int.tryParse(String.fromCharCode(bytes[pos]), radix: 16);
      if (value != null) digits.add(value);
      pos++;
    }
    pos++;
    if (digits.length.isOdd) digits.add(0);
    return PdfString(Uint8List.fromList([
      for (var i = 0; i < digits.length; i += 2) digits[i] * 16 + digits[i + 1],
    ]));
  }

  PdfString _readLiteralString() {
    pos++;
    final out = <int>[];
    var depth = 1;
    while (pos < bytes.length) {
      final c = bytes[pos++];
      if (c == 0x5C && pos < bytes.length) {
        final e = bytes[pos++];
        switch (e) {
          case 0x6E:
            out.add(10);
          case 0x72:
            out.add(13);
          case 0x74:
            out.add(9);
          case 0x62:
            out.add(8);
          case 0x66:
            out.add(12);
          case 13:
            if (pos < bytes.length && bytes[pos] == 10) pos++;
          case 10:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var value = e - 0x30;
              for (var i = 0; i < 2 && pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x37; i++) {
                value = value * 8 + bytes[pos++] - 0x30;
              }
              out.add(value & 0xFF);
            } else {
              out.add(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.add(c);
      } else if (c == 0x29) {
        if (--depth == 0) break;
        out.add(c);
      } else {
        out.add(c);
      }
    }
    return PdfString(Uint8List.fromList(out));
  }
}

class _XrefEntry {
  const _XrefEntry.offset(this.offset)
      : container = 0,
        index = 0;
  const _XrefEntry.compressed(this.container, this.index) : offset = -1;
  final int offset;
  final int container;
  final int index;
  bool get isCompressed => offset < 0;
}

/// One page, with the attributes it inherits resolved.
class PdfPage {
  PdfPage._(this.document, this.dict, this.mediaBox, this.rotate, this.resources);

  final PdfDocument document;
  final PdfDict dict;

  /// `[x0, y0, x1, y1]`, normalised so x0 < x1 and y0 < y1.
  final List<double> mediaBox;
  final int rotate;
  final PdfDict resources;

  double get width => mediaBox[2] - mediaBox[0];
  double get height => mediaBox[3] - mediaBox[1];

  /// The page's content, all streams joined.
  Uint8List content() {
    final contents = document.resolve(dict['Contents']);
    final parts = <Uint8List>[];
    void add(Object? item) {
      final resolved = document.resolve(item);
      if (resolved is PdfStream) parts.add(document.decodeStream(resolved));
    }

    if (contents is List) {
      contents.forEach(add);
    } else {
      add(contents);
    }
    final out = BytesBuilder(copy: false);
    for (final part in parts) {
      out.add(part);
      out.addByte(10);
    }
    return out.takeBytes();
  }
}

class PdfDocument {
  PdfDocument._(this.bytes);

  /// Opens [bytes], repairing the cross-reference table if it is wrong.
  factory PdfDocument.open(Uint8List bytes) {
    final document = PdfDocument._(bytes);
    document._start();
    return document;
  }

  final Uint8List bytes;
  final Map<int, _XrefEntry> _xref = {};
  final Map<int, Object?> _cache = {};
  final Map<int, Map<int, Object?>> _objectStreams = {};
  PdfDict _trailer = {};
  bool _rebuilt = false;
  List<PdfPage>? _pages;

  void _start() {
    final head = latin1.decode(bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024));
    if (!head.contains('%PDF-')) {
      throw const PdfException('That file does not look like a PDF.');
    }
    try {
      _readXrefChain();
      _checkRoot();
    } on Object {
      _rebuild();
    }
    if (_trailer.containsKey('Encrypt')) {
      throw const PdfException(
        'That PDF is password-protected. Save an unprotected copy and try again.',
      );
    }
  }

  void _checkRoot() {
    final root = resolve(_trailer['Root']);
    if (root is! Map<String, Object?>) throw const PdfException('No catalog');
    final pages = resolve(root['Pages']);
    if (pages is! Map<String, Object?>) throw const PdfException('No page tree');
  }

  // --------------------------------------------------------------- xref

  void _readXrefChain() {
    _xref.clear();
    _cache.clear();
    _objectStreams.clear();
    final tailStart = bytes.length > 2048 ? bytes.length - 2048 : 0;
    final tail = latin1.decode(bytes.sublist(tailStart));
    final marker = tail.lastIndexOf('startxref');
    if (marker < 0) throw const PdfException('No startxref');
    final lexer = PdfLexer(bytes, tailStart + marker + 'startxref'.length);
    var offset = lexer.read() as int;
    final seen = <int>{};
    PdfDict? first;
    while (true) {
      if (!seen.add(offset) || offset < 0 || offset >= bytes.length) break;
      final reader = PdfLexer(bytes, offset);
      reader.skipWhite();
      PdfDict trailer;
      if (_startsWith(reader.pos, 'xref')) {
        reader.pos += 4;
        trailer = _readXrefTable(reader);
        final hybrid = trailer['XRefStm'];
        if (hybrid is int) {
          _readXrefStream(hybrid);
        }
      } else {
        trailer = _readXrefStream(offset);
      }
      first ??= trailer;
      final prev = trailer['Prev'];
      if (prev is! int) break;
      offset = prev;
    }
    if (first == null) throw const PdfException('No cross-reference data');
    _trailer = first;
  }

  bool _startsWith(int at, String text) {
    if (at + text.length > bytes.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  PdfDict _readXrefTable(PdfLexer lexer) {
    while (true) {
      lexer.skipWhite();
      if (_startsWith(lexer.pos, 'trailer')) {
        lexer.pos += 7;
        final trailer = lexer.read();
        if (trailer is! Map<String, Object?>) throw const PdfException('Bad trailer');
        return trailer;
      }
      final start = lexer.read(allowRefs: false);
      final count = lexer.read(allowRefs: false);
      if (start is! int || count is! int) throw const PdfException('Bad xref subsection');
      for (var i = 0; i < count; i++) {
        final offset = lexer.read(allowRefs: false);
        final generation = lexer.read(allowRefs: false);
        final flag = lexer.read(allowRefs: false);
        if (offset is! int || generation is! int || flag is! PdfKeyword) {
          throw const PdfException('Bad xref entry');
        }
        final number = start + i;
        if (flag.value == 'n' && !_xref.containsKey(number)) {
          _xref[number] = _XrefEntry.offset(offset);
        } else if (flag.value == 'f') {
          _xref.putIfAbsent(number, () => const _XrefEntry.offset(0));
        }
      }
    }
  }

  PdfDict _readXrefStream(int offset) {
    final object = _parseIndirectAt(offset, null);
    if (object is! PdfStream) throw const PdfException('Bad xref stream');
    final dict = object.dict;
    final w = (dict['W'] as List).cast<int>();
    final size = dict['Size'] as int;
    final index = dict['Index'] is List ? (dict['Index'] as List).cast<int>() : [0, size];
    final data = decodeStream(object);
    var p = 0;
    int field(int width) {
      var value = 0;
      for (var i = 0; i < width; i++) {
        value = (value << 8) | data[p++];
      }
      return value;
    }

    for (var s = 0; s + 1 < index.length; s += 2) {
      for (var i = 0; i < index[s + 1]; i++) {
        final type = w[0] == 0 ? 1 : field(w[0]);
        final a = field(w[1]);
        final b = field(w[2]);
        final number = index[s] + i;
        if (_xref.containsKey(number)) continue;
        if (type == 1) {
          _xref[number] = _XrefEntry.offset(a);
        } else if (type == 2) {
          _xref[number] = _XrefEntry.compressed(a, b);
        }
      }
    }
    return dict;
  }

  /// Walks the whole file for `n g obj`, the way poppler's repair step does.
  void _rebuild() {
    if (_rebuilt) throw const PdfException('That file does not look like a PDF.');
    _rebuilt = true;
    _xref.clear();
    _cache.clear();
    _objectStreams.clear();
    _pages = null;
    final text = latin1.decode(bytes);
    final header = RegExp(r'(?<![0-9])(\d+)[ \t]+(\d+)[ \t]*obj(?![a-z])');
    final objectStreams = <int>[];
    for (final match in header.allMatches(text)) {
      final number = int.parse(match.group(1)!);
      _xref[number] = _XrefEntry.offset(match.start);
      final peek = text.substring(match.end, text.length < match.end + 300 ? text.length : match.end + 300);
      if (RegExp(r'/Type\s*/ObjStm').hasMatch(peek)) objectStreams.add(number);
    }
    var trailer = <String, Object?>{};
    for (final match in RegExp('trailer').allMatches(text)) {
      try {
        final value = PdfLexer(bytes, match.end).read();
        if (value is Map<String, Object?> && value.containsKey('Root')) {
          trailer = {...trailer, ...value};
        }
      } on Object {
        continue;
      }
    }
    for (final number in objectStreams) {
      try {
        final stream = _load(number);
        if (stream is! PdfStream) continue;
        final contents = _objectStream(number);
        for (final inner in contents.keys) {
          _xref.putIfAbsent(inner, () => _XrefEntry.compressed(number, 0));
        }
      } on Object {
        continue;
      }
    }
    if (!trailer.containsKey('Root')) {
      for (final number in _xref.keys.toList()) {
        try {
          final object = _load(number);
          final dict = object is PdfStream ? object.dict : object;
          if (dict is Map<String, Object?> && dict['Type'] == const PdfName('XRef') && dict.containsKey('Root')) {
            trailer = {...trailer, ...dict};
          } else if (dict is Map<String, Object?> && dict['Type'] == const PdfName('Catalog')) {
            trailer['Root'] ??= PdfRef(number, 0);
          }
        } on Object {
          continue;
        }
      }
    }
    _trailer = trailer;
    try {
      _checkRoot();
    } on Object {
      throw const PdfException('That file does not look like a PDF.');
    }
  }

  // ------------------------------------------------------------ objects

  Object? resolve(Object? value) {
    var current = value;
    for (var i = 0; i < 32 && current is PdfRef; i++) {
      current = _load(current.number);
    }
    return current;
  }

  Object? _load(int number) {
    if (_cache.containsKey(number)) return _cache[number];
    final entry = _xref[number];
    if (entry == null) return null;
    Object? value;
    if (entry.isCompressed) {
      value = _objectStream(entry.container)[number];
    } else {
      if (entry.offset <= 0) return null;
      try {
        value = _parseIndirectAt(entry.offset, number);
      } on PdfException {
        if (_rebuilt) rethrow;
        _rebuild();
        return _load(number);
      }
    }
    _cache[number] = value;
    return value;
  }

  Object? _parseIndirectAt(int offset, int? expected) {
    if (offset < 0 || offset >= bytes.length) throw const PdfException('Object offset out of range');
    final lexer = PdfLexer(bytes, offset);
    final number = lexer.read(allowRefs: false);
    final generation = lexer.read(allowRefs: false);
    final keyword = lexer.read(allowRefs: false);
    if (number is! int || generation is! int || keyword is! PdfKeyword || keyword.value != 'obj') {
      throw const PdfException('Bad object header');
    }
    if (expected != null && number != expected) throw const PdfException('Wrong object');
    final value = lexer.read();
    if (value is Map<String, Object?>) {
      lexer.skipWhite();
      if (_startsWith(lexer.pos, 'stream')) {
        var start = lexer.pos + 6;
        if (start < bytes.length && bytes[start] == 13) start++;
        if (start < bytes.length && bytes[start] == 10) start++;
        final length = resolveLength(value['Length']);
        var end = -1;
        if (length != null && start + length <= bytes.length) {
          final check = PdfLexer(bytes, start + length)..skipWhite();
          if (_startsWith(check.pos, 'endstream')) end = start + length;
        }
        if (end < 0) {
          end = _indexOf('endstream', start);
          if (end < 0) throw const PdfException('Unterminated stream');
          // The newline before `endstream` belongs to the marker, not the data.
          if (end > start && bytes[end - 1] == 10) end--;
          if (end > start && bytes[end - 1] == 13) end--;
        }
        return PdfStream(value, Uint8List.sublistView(bytes, start, end));
      }
    }
    return value;
  }

  int? resolveLength(Object? value) {
    if (value is int) return value;
    if (value is PdfRef) {
      // A length stored as an object: read it without recursing into streams.
      final entry = _xref[value.number];
      if (entry == null || entry.isCompressed || entry.offset <= 0) return null;
      try {
        final lexer = PdfLexer(bytes, entry.offset);
        lexer.read(allowRefs: false);
        lexer.read(allowRefs: false);
        lexer.read(allowRefs: false);
        final inner = lexer.read();
        return inner is int ? inner : null;
      } on Object {
        return null;
      }
    }
    return null;
  }

  int _indexOf(String needle, int from) {
    final first = needle.codeUnitAt(0);
    for (var i = from; i + needle.length <= bytes.length; i++) {
      if (bytes[i] == first && _startsWith(i, needle)) return i;
    }
    return -1;
  }

  Map<int, Object?> _objectStream(int container) {
    final cached = _objectStreams[container];
    if (cached != null) return cached;
    final stream = _load(container);
    if (stream is! PdfStream) throw const PdfException('Bad object stream');
    final data = decodeStream(stream);
    final count = stream.dict['N'] as int;
    final first = stream.dict['First'] as int;
    final header = PdfLexer(data);
    final numbers = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      numbers.add(header.read(allowRefs: false) as int);
      offsets.add(header.read(allowRefs: false) as int);
    }
    final out = <int, Object?>{};
    for (var i = 0; i < count; i++) {
      final lexer = PdfLexer(data, first + offsets[i]);
      try {
        out[numbers[i]] = lexer.read();
      } on Object {
        out[numbers[i]] = null;
      }
    }
    return _objectStreams[container] = out;
  }

  // ------------------------------------------------------------ streams

  /// The names of the filters on [stream], in the order they apply.
  List<String> filtersOf(PdfStream stream) {
    final raw = resolve(stream.dict['Filter'] ?? stream.dict['F']);
    if (raw == null) return const [];
    final list = raw is List ? raw : [raw];
    return [
      for (final item in list)
        if (resolve(item) case PdfName(:final value)) value,
    ];
  }

  List<PdfDict?> _paramsOf(PdfStream stream, int count) {
    final raw = resolve(stream.dict['DecodeParms'] ?? stream.dict['DP']);
    final list = raw is List ? raw : [raw];
    return [
      for (var i = 0; i < count; i++)
        if (i < list.length && resolve(list[i]) is Map<String, Object?>)
          resolve(list[i]) as PdfDict
        else
          null,
    ];
  }

  /// Decodes the stream's general-purpose filters. Image filters (DCT, JPX,
  /// CCITT, JBIG2) are not touched: [stopAtImageFilter] leaves them in place
  /// and returns the name so the caller can hand the bytes to a decoder.
  Uint8List decodeStream(PdfStream stream) => decodeStreamUpTo(stream).$1;

  (Uint8List, String?) decodeStreamUpTo(PdfStream stream) {
    final filters = filtersOf(stream);
    final params = _paramsOf(stream, filters.length);
    var data = stream.raw;
    for (var i = 0; i < filters.length; i++) {
      switch (filters[i]) {
        case 'FlateDecode' || 'Fl':
          data = _predict(_inflate(data), params[i]);
        case 'ASCIIHexDecode' || 'AHx':
          data = _asciiHex(data);
        case 'ASCII85Decode' || 'A85':
          data = _ascii85(data);
        case 'DCTDecode' || 'DCT' || 'JPXDecode' || 'CCITTFaxDecode' || 'CCF' || 'JBIG2Decode':
          return (data, filters[i]);
        default:
          throw PdfUnsupported('This PDF uses a compression (${filters[i]}) that is not supported.');
      }
    }
    return (data, null);
  }

  Uint8List _inflate(Uint8List data) {
    try {
      return Uint8List.fromList(ZLibDecoder().convert(data));
    } on Object {
      // Truncated or slightly corrupt: take what inflates, as poppler does.
      try {
        final inflater = archive.Inflate(data.sublist(2));
        return Uint8List.fromList(inflater.getBytes());
      } on Object {
        throw const PdfException('A page in this PDF is damaged and could not be decompressed.');
      }
    }
  }

  Uint8List _predict(Uint8List data, PdfDict? params) {
    final predictor = params == null ? 1 : (resolve(params['Predictor']) as int? ?? 1);
    if (predictor <= 1) return data;
    final colors = resolve(params!['Colors']) as int? ?? 1;
    final bits = resolve(params['BitsPerComponent']) as int? ?? 8;
    final columns = resolve(params['Columns']) as int? ?? 1;
    final bytesPerPixel = (colors * bits + 7) ~/ 8;
    final rowBytes = (colors * bits * columns + 7) ~/ 8;
    if (predictor == 2) {
      if (bits != 8) throw const PdfUnsupported('Unsupported TIFF predictor.');
      final out = Uint8List.fromList(data);
      final rows = out.length ~/ rowBytes;
      for (var r = 0; r < rows; r++) {
        for (var i = bytesPerPixel; i < rowBytes; i++) {
          out[r * rowBytes + i] = (out[r * rowBytes + i] + out[r * rowBytes + i - bytesPerPixel]) & 0xFF;
        }
      }
      return out;
    }
    final rows = (data.length + rowBytes) ~/ (rowBytes + 1);
    final out = Uint8List(rows * rowBytes);
    var previous = Uint8List(rowBytes);
    var src = 0;
    for (var r = 0; r < rows; r++) {
      if (src >= data.length) break;
      final type = data[src++];
      final row = Uint8List(rowBytes);
      final available = (data.length - src) < rowBytes ? data.length - src : rowBytes;
      row.setRange(0, available, data, src);
      src += available;
      for (var i = 0; i < rowBytes; i++) {
        final left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
        final up = previous[i];
        final upLeft = i >= bytesPerPixel ? previous[i - bytesPerPixel] : 0;
        switch (type) {
          case 1:
            row[i] = (row[i] + left) & 0xFF;
          case 2:
            row[i] = (row[i] + up) & 0xFF;
          case 3:
            row[i] = (row[i] + ((left + up) >> 1)) & 0xFF;
          case 4:
            final p = left + up - upLeft;
            final pa = (p - left).abs();
            final pb = (p - up).abs();
            final pc = (p - upLeft).abs();
            final predictorValue = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft);
            row[i] = (row[i] + predictorValue) & 0xFF;
        }
      }
      out.setRange(r * rowBytes, (r + 1) * rowBytes, row);
      previous = row;
    }
    return out;
  }

  Uint8List _asciiHex(Uint8List data) {
    final digits = <int>[];
    for (final c in data) {
      if (c == 0x3E) break;
      final value = int.tryParse(String.fromCharCode(c), radix: 16);
      if (value != null) digits.add(value);
    }
    if (digits.length.isOdd) digits.add(0);
    return Uint8List.fromList([
      for (var i = 0; i < digits.length; i += 2) digits[i] * 16 + digits[i + 1],
    ]);
  }

  Uint8List _ascii85(Uint8List data) {
    final out = <int>[];
    var group = <int>[];
    for (var i = 0; i < data.length; i++) {
      final c = data[i];
      if (_isWhite(c)) continue;
      if (c == 0x7E) break;
      if (c == 0x7A && group.isEmpty) {
        out.addAll([0, 0, 0, 0]);
        continue;
      }
      group.add(c - 33);
      if (group.length == 5) {
        var v = 0;
        for (final g in group) {
          v = v * 85 + g;
        }
        out.addAll([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
        group = [];
      }
    }
    if (group.length > 1) {
      final n = group.length;
      while (group.length < 5) {
        group.add(84);
      }
      var v = 0;
      for (final g in group) {
        v = v * 85 + g;
      }
      final all = [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
      out.addAll(all.sublist(0, n - 1));
    }
    return Uint8List.fromList(out);
  }

  // -------------------------------------------------------------- pages

  List<PdfPage> get pages => _pages ??= _collectPages();

  int get pageCount => pages.length;

  List<PdfPage> _collectPages() {
    final root = resolve(_trailer['Root']) as PdfDict;
    final out = <PdfPage>[];
    final seen = <Object>{};

    void walk(Object? node, PdfDict inherited, int depth) {
      if (depth > 64) return;
      final reference = node;
      final dict = resolve(node);
      if (dict is! Map<String, Object?>) return;
      if (reference is PdfRef && !seen.add(reference.number)) return;
      final merged = <String, Object?>{
        ...inherited,
        for (final key in const ['Resources', 'MediaBox', 'CropBox', 'Rotate'])
          if (dict.containsKey(key)) key: dict[key],
      };
      final kids = resolve(dict['Kids']);
      final isPages = dict['Type'] == const PdfName('Pages') || (kids is List && dict['Type'] != const PdfName('Page'));
      if (isPages && kids is List) {
        for (final kid in kids) {
          walk(kid, merged, depth + 1);
        }
        return;
      }
      out.add(_makePage(dict, merged));
    }

    walk(root['Pages'], const {}, 0);
    if (out.isEmpty) throw const PdfException('That PDF has no pages.');
    return out;
  }

  PdfPage _makePage(PdfDict dict, PdfDict inherited) {
    final box = resolve(inherited['MediaBox']);
    List<double> mediaBox;
    if (box is List && box.length == 4) {
      final v = [for (final item in box) (resolve(item) as num).toDouble()];
      mediaBox = [
        v[0] < v[2] ? v[0] : v[2],
        v[1] < v[3] ? v[1] : v[3],
        v[0] < v[2] ? v[2] : v[0],
        v[1] < v[3] ? v[3] : v[1],
      ];
    } else {
      mediaBox = [0, 0, 612, 792];
    }
    final rotate = resolve(inherited['Rotate']);
    final resources = resolve(inherited['Resources']);
    return PdfPage._(
      this,
      dict,
      mediaBox,
      rotate is int ? ((rotate % 360) + 360) % 360 : 0,
      resources is Map<String, Object?> ? resources : const {},
    );
  }
}
