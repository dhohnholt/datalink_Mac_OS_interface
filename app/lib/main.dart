import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'hardware_check/hardware_check.dart';

Future<void> main() async {
  // Headless mode for checking the sandboxed build from a terminal, where the
  // report lands on stdout instead of a window:
  //   DATALINK_HARDWARE_CHECK=1 "DataLink Scanner.app/Contents/MacOS/DataLink Scanner"
  final env = Platform.environment;
  if (env['DATALINK_HARDWARE_CHECK'] == '1') {
    final listen = int.tryParse(env['DATALINK_HARDWARE_LISTEN'] ?? '') ?? 0;
    final check = HardwareCheck(
      transport: PosixSerialTransport(),
      clock: SystemClock(),
      deviceDirectory: '/dev',
      appVersion: appVersion,
    );
    stdout.writeln(await check.run(listenFor: Duration(seconds: listen)));
    exit(0);
  }
  runApp(const DataLinkApp());
}

const String appVersion = '2.0.0+1';

class DataLinkApp extends StatelessWidget {
  const DataLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DataLink Scanner',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.green,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HardwareCheckPage(),
    );
  }
}

/// Temporary home screen while the port is built: it runs the serial path and
/// shows a report that can be copied and sent back.
class HardwareCheckPage extends StatefulWidget {
  const HardwareCheckPage({super.key, this.runner, this.saver});

  /// Replaced in tests.
  final Future<String> Function(
    Duration listenFor,
    void Function(String) onProgress,
  )? runner;

  /// Writes the report somewhere and returns where, or null. Replaced in tests.
  final Future<String?> Function(String report)? saver;

  @override
  State<HardwareCheckPage> createState() => _HardwareCheckPageState();
}

class _HardwareCheckPageState extends State<HardwareCheckPage> {
  String _report = '';
  bool _running = false;

  Future<String> _defaultRun(
    Duration listenFor,
    void Function(String) onProgress,
  ) {
    final check = HardwareCheck(
      transport: PosixSerialTransport(),
      clock: SystemClock(),
      deviceDirectory: '/dev',
      appVersion: appVersion,
    );
    return check.run(listenFor: listenFor, onProgress: onProgress);
  }

  Future<String?> _defaultSave(String report) async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/hardware-check.txt');
    await file.writeAsString(report);
    return file.path;
  }

  Future<void> _start(Duration listenFor) async {
    setState(() {
      _running = true;
      _report = 'Running…';
    });
    final run = widget.runner ?? _defaultRun;
    final report = await run(listenFor, (text) {
      if (mounted) setState(() => _report = text);
    });
    try {
      final path = await (widget.saver ?? _defaultSave)(report);
      if (mounted) {
        setState(() => _report = path == null ? report : '$report\n\nSaved to $path');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _report = '$report\n\n(could not save: $error)');
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DataLink Scanner — hardware check')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Checks whether this signed, sandboxed app can open the scanner\'s '
              'serial port and talk to it. Plug in the DataLink 1200 and switch '
              'it on first.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _running ? null : () => _start(Duration.zero),
                  child: const Text('Run check'),
                ),
                FilledButton.tonal(
                  onPressed:
                      _running ? null : () => _start(const Duration(seconds: 60)),
                  child: const Text('Run check, then listen 60 s for a sheet'),
                ),
                OutlinedButton(
                  onPressed: _report.isEmpty
                      ? null
                      : () => Clipboard.setData(ClipboardData(text: _report)),
                  child: const Text('Copy report'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Semantics(
                label: 'Hardware check report',
                child: SingleChildScrollView(
                  child: SelectableText(
                    _report.isEmpty ? 'No report yet.' : _report,
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
