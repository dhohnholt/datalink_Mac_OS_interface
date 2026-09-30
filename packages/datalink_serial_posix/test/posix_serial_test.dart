@TestOn('mac-os')
library;

// Exercises the real libc path against a pseudo-terminal, so everything except
// the USB adapter itself is covered without a scanner attached. What this
// cannot show is whether the sandbox lets a signed app open /dev/cu.usbserial:
// that needs the hardware (see docs/flutter-port-plan.md, Phase 1).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:datalink_serial_posix/src/libc.dart' as c;
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const int _fSetfl = 4;
final int Function(int, int, int) _fcntl = DynamicLibrary.process().lookupFunction<
    Int Function(Int, Int, VarArgs<(Int,)>),
    int Function(int, int, int)>('fcntl');

/// A pseudo-terminal pair. The "device" end is the master; the port under test
/// is the slave path.
class Pty {
  Pty._(this.master, this.slave, this.slavePath);

  factory Pty.open() {
    final master = calloc<Int32>();
    final slave = calloc<Int32>();
    final name = calloc<Uint8>(256);
    try {
      if (c.openpty(master, slave, name, nullptr, nullptr) != 0) {
        throw StateError('openpty failed: ${c.errnoMessage(c.errno)}');
      }
      final path = name.cast<Utf8>().toDartString();
      // FIONREAD reports 0 on a pty master even with data waiting, so the
      // device end reads without blocking instead of asking how much is there.
      _fcntl(master.value, _fSetfl, c.oNonblock);
      return Pty._(master.value, slave.value, path);
    } finally {
      calloc
        ..free(master)
        ..free(slave)
        ..free(name);
    }
  }

  final int master;

  /// Held open for the life of the test so the pair never hangs up, and used
  /// to read back terminal settings without opening the slave a second time
  /// (which exclusive mode would refuse).
  final int slave;
  final String slavePath;

  void closeAll() {
    c.close(slave);
    c.close(master);
  }

  /// Bytes the port wrote, as seen at the device end.
  List<int> drain() => c.readBytes(master, 4096) ?? const <int>[];

  void sendFromDevice(List<int> bytes) {
    c.writeBytes(master, bytes);
  }
}

/// Answers each command the way the real scanner did in the captures.
class SimulatedScanner {
  SimulatedScanner(this.pty, this.replies) {
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) => _poll());
  }

  final Pty pty;
  final Map<String, String> replies;
  late final Timer _timer;
  final List<String> received = <String>[];

  void _poll() {
    final bytes = pty.drain();
    if (bytes.isEmpty) return;
    final command = String.fromCharCodes(bytes);
    received.add(command);
    final hex = replies[command];
    if (hex == null) return;
    pty.sendFromDevice([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  void stop() => _timer.cancel();
}

Map<String, Object?> loadGolden() => (jsonDecode(
      File('../datalink_core/test/goldens/protocol.json').readAsStringSync(),
    ) as Map)
    .cast<String, Object?>();

void main() {
  late Pty pty;
  // A pseudo-terminal has no modem lines, so the tests relax that one check.
  final transport = PosixSerialTransport(requireModemLines: false);

  setUp(() => pty = Pty.open());
  tearDown(() => pty.closeAll());

  group('PosixSerialTransport.open', () {
    test('configures the line like pyserial: raw, 38400, 8N1, VMIN 0', () async {
      final connection = await transport.open(pty.slavePath, const SerialSettings());
      addTearDown(connection.close);

      final termios = c.Termios();
      addTearDown(termios.free);
      expect(c.tcgetattr(pty.slave, termios.pointer), 0);

      expect(termios.lflag & (c.icanon | c.echo | c.isig | c.iexten), 0,
          reason: 'raw input');
      expect(termios.oflag & (c.opost | c.onlcr | c.ocrnl), 0,
          reason: 'no output translation');
      expect(termios.iflag & (c.icrnl | c.inlcr | c.igncr | c.ixon | c.ixoff), 0,
          reason: 'no input translation or software flow control');
      expect(termios.cflag & c.csize, c.cs8);
      expect(termios.cflag & (c.parenb | c.cstopb | c.crtscts), 0);
      expect(termios.cflag & (c.clocal | c.cread), c.clocal | c.cread);
      expect(termios.ispeed, 38400);
      expect(termios.ospeed, 38400);
      expect(termios.cc(c.vmin), 0);
    });

    test('a path that does not exist says so', () async {
      await expectLater(
        transport.open('/dev/cu.no-such-scanner', const SerialSettings()),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            allOf(contains('/dev/cu.no-such-scanner'), contains('errno 2')),
          ),
        ),
      );
    });

    test('a second opener is turned away while the first holds the port', () async {
      final first = await transport.open(pty.slavePath, const SerialSettings());
      addTearDown(first.close);
      await expectLater(
        transport.open(pty.slavePath, const SerialSettings()),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            startsWith('Another program already has the scanner open'),
          ),
        ),
      );
    });

    test('exclusive mode releases on close', () async {
      final first = await transport.open(pty.slavePath, const SerialSettings());
      await first.close();
      final second = await transport.open(pty.slavePath, const SerialSettings());
      await second.close();
    });
  });

  group('PosixSerialConnection', () {
    late SerialConnection connection;
    setUp(() async {
      connection = await transport.open(pty.slavePath, const SerialSettings());
    });
    tearDown(() => connection.close());

    test('bytes written reach the device, unmodified', () async {
      final payload = Uint8List.fromList([...'R1'.codeUnits, 0x0d, 0x0a, 0x00, 0xff]);
      await connection.write(payload);
      // flush waits for the far end to take the bytes, so the device has to be
      // reading while it does.
      final flushed = connection.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final seen = pty.drain();
      await flushed;
      expect(seen, payload);
    });

    test('bytes from the device arrive, and inWaiting counts them', () async {
      pty.sendFromDevice('ADV 1200OK\r\n'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connection.inWaiting, 12);
      final got = await connection.read(12);
      expect(String.fromCharCodes(got), 'ADV 1200OK\r\n');
      expect(connection.inWaiting, 0);
    });

    test('CR and LF are not translated on the way in', () async {
      pty.sendFromDevice([0x0d, 0x0a, 0x0a, 0x0d]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await connection.read(4), [0x0d, 0x0a, 0x0a, 0x0d]);
    });

    test('an empty read waits about the read timeout and returns nothing', () async {
      final clock = Stopwatch()..start();
      final got = await connection.read(1);
      clock.stop();
      expect(got, isEmpty);
      expect(clock.elapsedMilliseconds, inInclusiveRange(40, 200));
    });

    test('read returns as soon as it has all the bytes asked for', () async {
      pty.sendFromDevice([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final clock = Stopwatch()..start();
      expect(await connection.read(3), [1, 2, 3]);
      expect(clock.elapsedMilliseconds, lessThan(40));
    });

    test('resetInputBuffer discards what is waiting', () async {
      pty.sendFromDevice('stale'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connection.inWaiting, 5);
      await connection.resetInputBuffer();
      expect(connection.inWaiting, 0);
    });

    test('closing twice is harmless and use after close is refused', () async {
      await connection.close();
      await connection.close();
      await expectLater(
        connection.read(1),
        throwsA(isA<DataLinkError>()),
      );
    });

    test('DTR and RTS can be driven, where the terminal has modem lines', () async {
      final posix = connection as PosixSerialConnection;
      int? bits;
      try {
        bits = posix.modemBits;
      } on SerialException {
        // A pty has no modem lines on some systems; the real adapter does.
        markTestSkipped('pseudo-terminal has no modem control lines');
        return;
      }
      await posix.setDtr(on: false);
      await posix.setRts(on: true);
      bits = posix.modemBits;
      expect(bits & c.tiocmDtr, 0);
      expect(bits & c.tiocmRts, c.tiocmRts);
    });
  });

  group('listPorts', () {
    test('lists only usbserial nodes, sorted', () async {
      final dir = await Directory.systemTemp.createTemp('datalink-dev');
      addTearDown(() => dir.delete(recursive: true));
      for (final name in [
        'cu.usbserial-1200',
        'tty.usbserial-1200',
        'cu.Bluetooth-Incoming-Port',
        'cu.BoseQC45',
        'null',
      ]) {
        File('${dir.path}/$name').createSync();
      }
      final ports = await PosixSerialTransport(deviceDirectory: dir.path).listPorts();
      expect(ports, [
        '${dir.path}/cu.usbserial-1200',
        '${dir.path}/tty.usbserial-1200',
      ]);
    });

    test('a directory that cannot be listed is no ports, not an error', () async {
      final ports =
          await PosixSerialTransport(deviceDirectory: '/no/such/dir').listPorts();
      expect(ports, isEmpty);
    });
  });

  group('DataLinkScanner over the real transport', () {
    test('runs the full handshake and gets the answers Python got', () async {
      final golden = loadGolden();
      final replies = (golden['device_replies']! as Map).cast<String, String>();
      final expected = ((golden['driver']! as List).cast<Map<Object?, Object?>>())
          .firstWhere((s) => s['name'] == 'handshake');
      final results = (expected['results']! as List).cast<Map<Object?, Object?>>();

      final device = SimulatedScanner(pty, replies);
      addTearDown(device.stop);

      final scanner = DataLinkScanner(
        pty.slavePath,
        transport: transport,
        clock: SystemClock(),
        questionCount: 30,
      );
      await scanner.open();
      addTearDown(scanner.close);

      final initialization = await scanner.initialize();
      final dataCollection = await scanner.enterDataCollection();

      expect(
        [for (final (command, reply) in initialization) [command, reply]],
        results[1]['result'],
      );
      expect(
        [for (final (command, reply) in dataCollection) [command, reply]],
        results[2]['result'],
      );
      // And the bytes on the wire were exactly the captured command sequence,
      // each one unterminated.
      expect(device.received, [
        ...initializationCommands.map(String.fromCharCodes),
        ...dataCollectionCommands.map(String.fromCharCodes),
      ]);
    });

    test('parses a record the device sends after the handshake', () async {
      final golden = loadGolden();
      final replies = (golden['device_replies']! as Map).cast<String, String>();
      final device = SimulatedScanner(pty, replies);
      addTearDown(device.stop);

      final scanner = DataLinkScanner(
        pty.slavePath,
        transport: transport,
        clock: SystemClock(),
        questionCount: 30,
      );
      await scanner.open();
      addTearDown(scanner.close);

      final fields = List<String>.filled(expectedFieldCount, '');
      fields[0] = '900011';
      for (var i = 0; i < 30; i++) {
        fields[answerStart + i] = 'ABCDE'[i % 5];
      }
      pty.sendFromDevice(ascii.encode('${fields.join(',')}\r\n'));

      var seen = <DataLinkFormRecord>[];
      for (var i = 0; i < 50 && seen.isEmpty; i++) {
        seen = (await scanner.readAvailable()).records;
      }
      expect(seen, hasLength(1));
      expect(seen.single.responses.first, 'A');
      expect(seen.single.publicDict()['scanner_id'], '900011');
    });
  });
}
