import 'dart:typed_data';

import '../serial/serial.dart';
import 'constants.dart';
import 'errors.dart';
import 'python_compat.dart';
import 'stream_parser.dart';

/// One command and what the scanner said back.
typedef Exchange = (String command, String reply);

/// Talks to a DataLink 1200 over a [SerialConnection]. A port of
/// `DirectDataLinkScanner` in `interface.py`; the sleeps, their order and the
/// retry behaviour are kept exactly, because they were tuned on hardware.
class DataLinkScanner {
  DataLinkScanner(
    this.port, {
    required this._transport,
    required this._clock,
    this.responseTimeoutSeconds = 1.0,
    Object? questionCount = defaultAnswerCount,
    this._now,
  }) : parser = DataLinkStreamParser(
          questionCount: questionCount,
          monotonic: _clock.monotonic,
          now: _now,
        );

  final String port;
  final double responseTimeoutSeconds;
  final SerialTransport _transport;
  final Clock _clock;
  final DateTime Function()? _now;

  DataLinkStreamParser parser;
  SerialConnection? _serial;

  bool get isOpen => _serial != null;

  Future<void> open() async {
    final connection = await _transport.open(port, const SerialSettings());
    _serial = connection;
    // Match the CP210x state recovered from USBPcap immediately before the
    // official Windows application sends V: DTR off and RTS on.
    await connection.setDtr(on: false);
    await connection.setRts(on: false);
    await _clock.sleep(0.15);
    await connection.resetInputBuffer();
    await connection.setDtr(on: false);
    await connection.setRts(on: true);
    await _clock.sleep(0.25);
  }

  Future<void> close() async {
    final connection = _serial;
    if (connection != null) {
      _serial = null;
      await connection.close();
    }
  }

  SerialConnection _requireOpen() =>
      _serial ?? (throw const DataLinkError('Scanner port is not open'));

  /// Send one command and collect the reply up to its CRLF.
  Future<String> transact(Uint8List command) async {
    final connection = _requireOpen();
    await connection.write(command);
    await connection.flush();
    final deadline = _clock.monotonic() + responseTimeoutSeconds;
    final reply = <int>[];
    while (_clock.monotonic() < deadline) {
      final waiting = connection.inWaiting;
      final chunk = await connection.read(waiting < 1 ? 1 : waiting);
      if (chunk.isNotEmpty) {
        reply.addAll(chunk);
        if (reply.length >= 2 &&
            reply[reply.length - 2] == 0x0d &&
            reply[reply.length - 1] == 0x0a) {
          break;
        }
      }
    }
    if (reply.isEmpty) {
      throw DataLinkError('No response to ${String.fromCharCodes(command)}');
    }
    return _rstripCrlf(_decodeReplacing(reply));
  }

  /// Ask who is there, allowing for a connection that has not settled.
  ///
  /// The first exchanges after the port opens are not reliable. Measured on
  /// hardware: twelve of the first forty-one replies to V lost a character, and
  /// on another occasion sixty consecutive V's got no answer at all, then a
  /// hundred and eighty in a row were clean. Failing the whole connection on
  /// the first of those is why a teacher saw "Unexpected version response".
  Future<String> version({int attempts = 4}) async {
    var last = '';
    for (var attempt = 0; attempt < attempts; attempt++) {
      var answered = false;
      try {
        last = await transact(initializationCommands.first);
        answered = true;
      } on DataLinkError catch (error) {
        last = error.message;
      }
      if (answered && last.contains('ADV 1200OK')) return last;
      await _clock.sleep(0.25 * (attempt + 1));
    }
    throw DataLinkError(
      'The scanner did not identify itself after $attempts tries; '
      'the last answer was ${pyRepr(last)}. If another program has the '
      'scanner open, close it and try again.',
    );
  }

  Future<List<Exchange>> initialize() async {
    final transcript = <Exchange>[('V', await version())];
    for (final command in initializationCommands.skip(1)) {
      final reply = await transact(command);
      transcript.add((String.fromCharCodes(command), reply));
      // Match the spacing visible in the official application's capture.
      // Back-to-back diagnostic queries can make the scanner drop X7.
      await _clock.sleep(0.06);
    }
    return transcript;
  }

  Future<List<Exchange>> enterDataCollection() async {
    final transcript = <Exchange>[];
    for (final command in dataCollectionCommands) {
      final reply = await transact(command);
      transcript.add((String.fromCharCodes(command), reply));
      await _clock.sleep(0.06);
    }
    return transcript;
  }

  /// Re-send the captured handshake on a port that is already open.
  ///
  /// This is what the teacher does by hand when the scanner stops taking
  /// sheets. The bytes are the ones the handshake already sends, so nothing new
  /// is written to the device. Anything the scanner was part-way through saying
  /// is dropped, which is the point.
  Future<List<Exchange>> resynchronize() async {
    final connection = _requireOpen();
    await connection.resetInputBuffer();
    parser = DataLinkStreamParser(
      questionCount: parser.questionCount,
      monotonic: _clock.monotonic,
      now: _now,
    );
    return [...await initialize(), ...await enterDataCollection()];
  }

  Future<ParsedChunk> readAvailable() async {
    final connection = _requireOpen();
    final waiting = connection.inWaiting;
    final chunk = await connection.read(waiting < 1 ? 1 : waiting);
    return parser.feed(chunk);
  }

  static String _decodeReplacing(List<int> bytes) => String.fromCharCodes(
        bytes.map((byte) => byte > 0x7f ? 0xfffd : byte),
      );

  static String _rstripCrlf(String text) {
    var end = text.length;
    while (end > 0) {
      final unit = text.codeUnitAt(end - 1);
      if (unit != 0x0d && unit != 0x0a) break;
      end--;
    }
    return text.substring(0, end);
  }
}

/// Choose the scanner's port from the device paths that exist.
///
/// macOS exposes the same adapter as both `cu.*` and `tty.*`. The `cu.*`
/// endpoint is the correct callout device for an application initiating a
/// session. Port of `discover_port` in `interface.py`, minus the `glob`.
String discoverPort(Iterable<String> found) {
  final candidates = ({
    ...found.where(
      (path) =>
          path.startsWith('/dev/cu.usbserial') ||
          path.startsWith('/dev/tty.usbserial'),
    ),
  }.toList())
    ..sort();
  if (candidates.isEmpty) {
    throw const DataLinkError('No /dev/cu.usbserial* DataLink port was found');
  }
  final preferred = candidates
      .where((path) => path.startsWith('/dev/cu.') && path.endsWith('1200'))
      .toList();
  if (preferred.length == 1) return preferred.first;
  if (candidates.length == 1) return candidates.first;
  throw const DataLinkError(
    'Multiple USB serial ports found; select one with --port',
  );
}
