import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';

import 'libc.dart' as c;

/// Finds and opens serial ports through libc.
///
/// Opening is what `com.apple.security.device.serial` gates; nothing else in
/// here needs an entitlement.
class PosixSerialTransport implements SerialTransport {
  /// [deviceDirectory] is where port nodes live; tests point it at a folder.
  PosixSerialTransport({
    this.deviceDirectory = '/dev',
    this.requireModemLines = true,
  });

  final String deviceDirectory;

  /// The scanner needs RTS on and DTR off, so failing to drive them is a real
  /// error on hardware. A pseudo-terminal has no modem lines; tests turn this
  /// off so the rest of the stack can still be exercised.
  final bool requireModemLines;

  @override
  Future<List<String>> listPorts() async {
    final found = <String>{};
    try {
      await for (final entry in Directory(deviceDirectory).list()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('cu.usbserial') || name.startsWith('tty.usbserial')) {
          found.add('$deviceDirectory/$name');
        }
      }
    } on FileSystemException {
      // Listing /dev can be refused; "no ports" is the honest answer then.
      return const <String>[];
    }
    return found.toList()..sort();
  }

  @override
  Future<SerialConnection> open(String path, SerialSettings settings) async {
    final fd = c.openPath(path, c.oRdwr | c.oNoctty | c.oNonblock | c.oCloexec);
    if (fd < 0) throw _openError(path, c.errno);
    try {
      if (settings.exclusive) {
        // The same advisory lock pyserial takes for `exclusive=True`, and taken
        // first for the same reason: before anything else is changed.
        if (c.flock(fd, c.lockEx | c.lockNb) != 0) {
          final code = c.errno;
          if (code == c.eagain) throw _busy;
        }
      }
      _configure(fd, settings);
      if (settings.exclusive) {
        // Best effort, and only as good as the driver: where it is honoured,
        // a program that opens the port after us is refused by the kernel,
        // which advisory locking cannot do. Some drivers ignore it.
        c.ioctlNone(fd, c.tiocexcl);
      }
    } on Object {
      c.close(fd);
      rethrow;
    }
    return PosixSerialConnection._(fd, path, settings, requireModemLines);
  }

  /// The same raw-mode setup pyserial performs on POSIX, field for field, so
  /// the line behaves as it did under the Python app.
  void _configure(int fd, SerialSettings settings) {
    final termios = c.Termios();
    try {
      if (c.tcgetattr(fd, termios.pointer) != 0) {
        throw DataLinkError(
          'Could not read the port settings: ${c.errnoMessage(c.errno)}',
        );
      }
      var cflag = termios.cflag | c.clocal | c.cread;
      var lflag = termios.lflag &
          ~(c.icanon |
              c.echo |
              c.echoe |
              c.echok |
              c.echonl |
              c.isig |
              c.iexten |
              c.echoprt |
              c.echoctl |
              c.echoke);
      var oflag = termios.oflag & ~(c.opost | c.onlcr | c.ocrnl);
      var iflag = termios.iflag &
          ~(c.inlcr | c.igncr | c.icrnl | c.igNbrk | c.parmrk);

      cflag = (cflag & ~c.csize) | c.cs8;
      if (settings.dataBits != 8) {
        throw DataLinkError('Unsupported data bits: ${settings.dataBits}');
      }
      cflag &= ~c.cstopb;
      if (settings.stopBits != 1) {
        throw DataLinkError('Unsupported stop bits: ${settings.stopBits}');
      }
      cflag &= ~(c.parenb | c.parodd);
      iflag &= ~(c.inpck | c.istrip);
      if (settings.parity != SerialParity.none) {
        throw const DataLinkError('Only no-parity is supported');
      }
      iflag &= ~(c.ixon | c.ixoff | c.ixany);
      cflag &= ~c.crtscts;

      termios
        ..iflag = iflag
        ..oflag = oflag
        ..cflag = cflag
        ..lflag = lflag
        // On Darwin a speed is its own number, so 38400 is B38400.
        ..ispeed = settings.baudRate
        ..ospeed = settings.baudRate
        ..setCc(c.vmin, 0)
        ..setCc(c.vtime, (settings.readTimeoutSeconds * 10).floor());
      if (c.tcsetattr(fd, c.tcsanow, termios.pointer) != 0) {
        throw DataLinkError(
          'Could not configure the port: ${c.errnoMessage(c.errno)}',
        );
      }
    } finally {
      termios.free();
    }
  }

  static const DataLinkError _busy = DataLinkError(
    'Another program already has the scanner open. Close it first — two '
    'programs reading the same port lose characters from each other.',
  );

  DataLinkError _openError(String path, int code) {
    final reason = c.errnoMessage(code);
    if (code == c.ebusy) return _busy;
    if (code == c.eperm || code == c.eacces) {
      return DataLinkError(
        'macOS did not allow DataLink Scanner to open $path ($reason, '
        'errno $code). If the scanner is plugged in, this is the sandbox '
        'refusing the serial port.',
      );
    }
    return DataLinkError('Could not open $path: $reason (errno $code)');
  }
}

/// An open serial device.
class PosixSerialConnection implements SerialConnection {
  PosixSerialConnection._(
    this._fd,
    this.path,
    this._settings,
    this._requireModemLines,
  );

  final int _fd;
  final String path;
  final SerialSettings _settings;
  final bool _requireModemLines;
  bool _closed = false;

  @override
  Future<void> setDtr({required bool on}) async => _modem(c.tiocmDtr, on: on);

  @override
  Future<void> setRts({required bool on}) async => _modem(c.tiocmRts, on: on);

  void _modem(int bit, {required bool on}) {
    _check();
    final result = c.ioctlInt(_fd, on ? c.tiocmbis : c.tiocmbic, bit);
    if (result != 0) {
      if (!_requireModemLines && c.errno == c.enotty) return;
      throw SerialException(
        'Could not set a modem line: ${c.errnoMessage(c.errno)}',
      );
    }
  }

  /// Current modem-control bits (TIOCM_*), for diagnostics and tests.
  int get modemBits {
    _check();
    final out = <int>[];
    if (c.ioctlInt(_fd, c.tiocmget, 0, out) != 0) {
      throw SerialException(
        'Could not read the modem lines: ${c.errnoMessage(c.errno)}',
      );
    }
    return out.single;
  }

  @override
  int get inWaiting {
    _check();
    final out = <int>[];
    if (c.ioctlInt(_fd, c.fionread, 0, out) != 0) return 0;
    return out.single;
  }

  @override
  Future<void> resetInputBuffer() async {
    _check();
    c.tcflush(_fd, c.tciflush);
  }

  @override
  Future<void> write(Uint8List data) async {
    _check();
    final deadline = Stopwatch()..start();
    var sent = 0;
    while (sent < data.length) {
      final put = c.writeBytes(_fd, Uint8List.sublistView(data, sent));
      if (put < 0) {
        throw SerialException('Scanner write failed: ${c.errnoMessage(c.errno)}');
      }
      sent += put;
      if (sent >= data.length) break;
      if (deadline.elapsedMicroseconds / 1e6 > _settings.writeTimeoutSeconds) {
        throw const SerialException('Scanner write timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Wait until the output queue is empty.
  ///
  /// Deliberately not `tcdrain`: that blocks the whole isolate until the far
  /// end has taken the bytes, which freezes the interface if the device stalls
  /// (and deadlocks any test that plays the device in the same isolate).
  /// Polling TIOCOUTQ gives the same guarantee without blocking.
  @override
  Future<void> flush() async {
    _check();
    final clock = Stopwatch()..start();
    final queued = <int>[];
    while (c.ioctlInt(_fd, c.tiocoutq, 0, queued) == 0 && queued.single > 0) {
      if (clock.elapsedMicroseconds / 1e6 > _settings.writeTimeoutSeconds) {
        throw const SerialException('Scanner write timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Wait up to the read timeout for [size] bytes and return what arrived.
  ///
  /// Polls without blocking the isolate, so the interface stays responsive
  /// while a sheet is being read. pyserial's `read(n)` behaves the same way:
  /// it returns early only when it has all n bytes.
  @override
  Future<Uint8List> read(int size) async {
    _check();
    final collected = BytesBuilder(copy: false);
    final clock = Stopwatch()..start();
    while (true) {
      final chunk = c.readBytes(_fd, size - collected.length);
      if (chunk == null) {
        throw SerialException('Scanner read failed: ${c.errnoMessage(c.errno)}');
      }
      collected.add(chunk);
      if (collected.length >= size) break;
      if (clock.elapsedMicroseconds / 1e6 >= _settings.readTimeoutSeconds) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return collected.takeBytes();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    c.ioctlNone(_fd, c.tiocnxcl);
    c.flock(_fd, c.lockUn);
    c.close(_fd);
  }

  void _check() {
    if (_closed) throw const DataLinkError('Scanner port is not open');
  }
}

/// Shorthand for the one place that wants a fully wired real transport.
SerialTransport defaultSerialTransport() => PosixSerialTransport();

