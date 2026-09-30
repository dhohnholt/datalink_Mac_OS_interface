import 'dart:async';
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';

/// Runs the serial path end to end and reports what happened in plain text.
///
/// This exists to answer one question that cannot be answered without the
/// scanner: does a signed, sandboxed build of this app get to use the serial
/// port? Every step is logged with enough detail (errno values included) to
/// tell "the sandbox said no" from "the scanner said nothing".
///
/// The report never contains a student ID: IDs are masked, and only counts and
/// shapes of records are written.
class HardwareCheck {
  HardwareCheck({
    required this.transport,
    required this.clock,
    required this.deviceDirectory,
    required this.appVersion,
    this.proxyPort = '/dev/cu.Bluetooth-Incoming-Port',
  });

  final SerialTransport transport;
  final Clock clock;
  final String deviceDirectory;
  final String appVersion;

  /// A serial node that exists on most Macs. Opening it is a stand-in for the
  /// scanner: it is served by the same kernel serial driver family, so if the
  /// sandbox allows it, that is evidence (not proof) about the CP210x node.
  final String proxyPort;

  final List<String> _lines = <String>[];

  void _log(String text) => _lines.add(text);

  Future<String> run({
    Duration listenFor = Duration.zero,
    void Function(String report)? onProgress,
  }) async {
    _lines.clear();
    void progress() => onProgress?.call(_lines.join('\n'));

    _log('DataLink Scanner hardware check');
    _log('app $appVersion, ${DateTime.now().toIso8601String()}');
    _log('os ${Platform.operatingSystemVersion}');
    _log('release mode: ${const bool.fromEnvironment('dart.vm.product')}');
    _log('');

    _section('Sandbox');
    final home = Platform.environment['HOME'] ?? '(unset)';
    _log('HOME env: $home');
    _log('working directory: ${Directory.current.path}');
    _log('');
    progress();

    _section('Serial nodes visible in $deviceDirectory');
    final names = await _listDevices();
    if (names == null) {
      _log('could not list $deviceDirectory');
    } else if (names.isEmpty) {
      _log('(no cu.* or tty.* entries)');
    } else {
      names.forEach(_log);
    }
    _log('');
    progress();

    _section('Proxy: open a serial node that is always there');
    await _proxyOpen(names ?? const <String>[]);
    _log('');
    progress();

    _section('Scanner');
    final ports = await transport.listPorts();
    _log('usbserial ports: ${ports.isEmpty ? '(none)' : ports.join(', ')}');
    if (ports.isEmpty) {
      _log('No scanner found. Plug in the DataLink 1200, switch it on, and run '
          'this again.');
      progress();
      return _lines.join('\n');
    }

    String port;
    try {
      port = discoverPort(ports);
    } on DataLinkError catch (error) {
      _log('port choice: ${error.message}');
      progress();
      return _lines.join('\n');
    }
    _log('using $port');
    progress();

    final scanner = DataLinkScanner(port, transport: transport, clock: clock);
    try {
      await scanner.open();
      _log('open: ok (DTR off, RTS on)');
      progress();
      _log('V -> ${await scanner.version()}');
      progress();
      for (final (command, reply) in await scanner.initialize()) {
        _log('  $command -> $reply');
      }
      for (final (command, reply) in await scanner.enterDataCollection()) {
        _log('  $command -> $reply');
      }
      _log('Data Collection: active');
      progress();

      if (listenFor > Duration.zero) {
        _log('');
        _log('Listening for ${listenFor.inSeconds} s — feed a sheet now.');
        progress();
        await _listen(scanner, listenFor, progress);
      }
    } on DataLinkError catch (error) {
      _log('FAILED: ${error.message}');
    } finally {
      await scanner.close();
      _log('closed');
    }
    progress();
    return _lines.join('\n');
  }

  void _section(String title) {
    _log('== $title');
  }

  Future<List<String>?> _listDevices() async {
    try {
      final found = <String>[];
      await for (final entry in Directory(deviceDirectory).list()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('cu.') || name.startsWith('tty.')) found.add(name);
      }
      return found..sort();
    } on FileSystemException catch (error) {
      _log('error: ${error.osError?.message ?? error.message}');
      return null;
    }
  }

  Future<void> _proxyOpen(List<String> listed) async {
    // Decided from the directory listing: Dart reports a character device as
    // "not found" from FileSystemEntity.type, so stat is no use here.
    final name = proxyPort.split('/').last;
    if (!listed.contains(name)) {
      _log('$proxyPort is not present on this Mac; skipped');
      return;
    }
    try {
      final connection = await transport.open(proxyPort, const SerialSettings());
      _log('open $proxyPort: ok');
      await connection.close();
    } on DataLinkError catch (error) {
      _log('open $proxyPort: ${error.message}');
    }
  }

  Future<void> _listen(
    DataLinkScanner scanner,
    Duration duration,
    void Function() progress,
  ) async {
    final stop = clock.monotonic() + duration.inMilliseconds / 1000;
    var sheets = 0;
    while (clock.monotonic() < stop) {
      try {
        final chunk = await scanner.readAvailable();
        final stale = scanner.parser.takeStaleFragment();
        for (final message in [...chunk.messages, ?stale]) {
          final (kind, text) = describeMessage(message);
          _log('[${kind.name}] $text');
        }
        for (final record in chunk.records) {
          sheets++;
          final shape = record.publicDict();
          final id = shape['scanner_id'] as String?;
          _log(
            'sheet $sheets: ${record.responses.length} answers, '
            '${shape['answered_count']} marked, '
            'student id ${id == null ? 'not read' : '${'#' * id.length} (masked)'}, '
            'scanner score ${shape['scanner_score'] ?? 'none'}',
          );
        }
        if (chunk.records.isNotEmpty || chunk.messages.isNotEmpty || stale != null) {
          progress();
        }
      } on DataLinkError catch (error) {
        _log('read failed: ${error.message}');
        progress();
        return;
      }
      await clock.sleep(0.025);
    }
    _log('Stopped listening; $sheets sheet(s) received.');
  }
}
