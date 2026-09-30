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
  });

  final int baudRate;
  final int dataBits;
  final SerialParity parity;
  final int stopBits;

  /// How long one `read` waits for data before returning what it has.
  final double readTimeoutSeconds;
  final double writeTimeoutSeconds;
}

enum SerialParity { none, even, odd }

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
