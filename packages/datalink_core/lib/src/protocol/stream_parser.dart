import 'dart:typed_data';

import 'constants.dart';
import 'errors.dart';
import 'form_record.dart';

/// What one read produced: complete records, and every other line.
typedef ParsedChunk = ({List<DataLinkFormRecord> records, List<String> messages});

double _defaultMonotonic() => _stopwatch.elapsedMicroseconds / 1e6;
final Stopwatch _stopwatch = Stopwatch()..start();

/// Incrementally separates control replies from complete form records.
class DataLinkStreamParser {
  DataLinkStreamParser({
    Object? questionCount = defaultAnswerCount,
    double Function()? monotonic,
    this._now,
  })  : _questionCount = validateQuestionCount(questionCount),
        _monotonic = monotonic ?? _defaultMonotonic;

  /// How long an unterminated line may sit in the buffer before it is given up
  /// on. The scanner ends everything it says with CRLF, so a fragment older
  /// than this is either a message it did not finish or line noise. It must not
  /// stay: the next record would be appended to it and read as one long
  /// malformed line, costing a sheet that went through perfectly well.
  static const double staleFragmentSeconds = 2.0;

  int _questionCount;
  final double Function() _monotonic;
  final DateTime Function()? _now;
  final List<int> _buffer = <int>[];
  double? _fragmentSince;

  int get questionCount => _questionCount;

  set questionCount(Object? value) => _questionCount = validateQuestionCount(value);

  Uint8List get pendingBytes => Uint8List.fromList(_buffer);

  ParsedChunk feed(List<int> data) {
    _buffer.addAll(data);
    final records = <DataLinkFormRecord>[];
    final messages = <String>[];

    while (true) {
      final boundary = _findCrlf();
      if (boundary < 0) break;
      final line = Uint8List.fromList(_buffer.sublist(0, boundary));
      _buffer.removeRange(0, boundary + 2);
      if (line.isEmpty) continue;
      if (_commaCount(line) >= _questionCount) {
        // One unreadable line must not take the rest of the read with it: the
        // bytes are already consumed and the paper has already gone through
        // the machine.
        try {
          records.add(
            DataLinkFormRecord.fromLine(
              line,
              questionCount: _questionCount,
              now: _now,
            ),
          );
        } on DataLinkError catch (error) {
          messages.add('$unreadableRecord: ${error.message}');
        }
      } else {
        messages.add(_decodeReplacing(line));
      }
    }

    _fragmentSince = _buffer.isEmpty ? null : (_fragmentSince ?? _monotonic());
    return (records: records, messages: messages);
  }

  /// Give up on a line the scanner never terminated, and return it.
  String? takeStaleFragment({double? now}) {
    final since = _fragmentSince;
    if (_buffer.isEmpty || since == null) return null;
    final at = now ?? _monotonic();
    if (at - since < staleFragmentSeconds) return null;
    final fragment = _decodeReplacing(_buffer);
    _buffer.clear();
    _fragmentSince = null;
    return fragment;
  }

  int _findCrlf() {
    for (var i = 0; i + 1 < _buffer.length; i++) {
      if (_buffer[i] == 0x0d && _buffer[i + 1] == 0x0a) return i;
    }
    return -1;
  }

  static int _commaCount(Uint8List line) {
    var count = 0;
    for (final byte in line) {
      if (byte == 0x2c) count++;
    }
    return count;
  }

  /// `bytes.decode('ascii', errors='replace')`: each byte above 0x7f becomes
  /// one U+FFFD.
  static String _decodeReplacing(List<int> bytes) => String.fromCharCodes(
        bytes.map((byte) => byte > 0x7f ? 0xfffd : byte),
      );
}
