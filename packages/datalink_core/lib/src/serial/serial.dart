import 'dart:typed_data';

/// Line settings for opening the scanner. The defaults are the only ones the
/// hardware has ever been seen to use, recovered from the official Windows
/// application's CP210x control transfers (see docs/PROTOCOL.md).
class SerialSettings {
  const SerialSettings({
    this.baudRate = 38400,
    this.dataBits = 8,
    this.parity = SerialParity.none,
    this.stopBits = 1,
    this.readTimeoutSeconds = 0.05,
    this.writeTimeoutSeconds = 1.0,
    this.exclusive = true,
  });

  final int baudRate;
  final int dataBits;
  final SerialParity parity;
  final int stopBits;

  /// How long one `read` waits for data before returning what it has.
  final double readTimeoutSeconds;
  final double writeTimeoutSeconds;

  /// Ask the OS to refuse other openers while this one holds the port.
  ///
  /// macOS lets two processes open one /dev/cu.* device and they take each
  /// other's bytes without either being told (see docs/PROTOCOL.md). The
  /// original found out who else had it open by running `lsof`, which a
  /// sandboxed app cannot do usefully. Holding the port exclusively closes the
  /// same hole from our side; it cannot detect a holder that did not do the
  /// same.
  final bool exclusive;
}

enum SerialParity { none, even, odd }

/// The port itself failed: a read or write error, a device that vanished. This
/// is deliberately not a [DataLinkError]. Those are protocol problems the
/// controller skips past (one bad record must not stop a session); this one
/// means the connection is gone, and is fatal to it. The Python app had the
/// same split between `DataLinkError` and pyserial's `SerialException`.
class SerialException implements Exception {
  const SerialException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An open serial port. Mirrors the small slice of pyserial the original uses,
/// so the driver above it is a line-for-line port.
abstract interface class SerialConnection {
  /// Drive the modem-control lines. The scanner needs DTR off and RTS on.
  Future<void> setDtr({required bool on});
  Future<void> setRts({required bool on});

  /// Bytes already received and waiting to be read.
  int get inWaiting;

  Future<void> resetInputBuffer();

  Future<void> write(Uint8List data);

  /// Wait until the output has left the port (pyserial's `flush`).
  Future<void> flush();

  /// Read up to [size] bytes, waiting no longer than the read timeout for
  /// them. Returns whatever arrived, which may be nothing.
  Future<Uint8List> read(int size);

  Future<void> close();
}

/// Finds and opens serial ports. The real one talks to the OS; tests use a
/// scripted one.
abstract interface class SerialTransport {
  /// Device paths that could be the scanner, sorted.
  Future<List<String>> listPorts();

  Future<SerialConnection> open(String path, SerialSettings settings);
}

/// Time, as the driver needs it. Injected so the handshake's timing can be
/// checked without waiting for it.
abstract interface class Clock {
  /// Seconds on a monotonic clock.
  double monotonic();

  Future<void> sleep(double seconds);
}

/// The real clock.
class SystemClock implements Clock {
  SystemClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  double monotonic() => _stopwatch.elapsedMicroseconds / 1e6;

  @override
  Future<void> sleep(double seconds) =>
      Future<void>.delayed(Duration(microseconds: (seconds * 1e6).round()));
}
