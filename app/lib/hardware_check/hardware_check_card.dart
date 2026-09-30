import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../main.dart' show appVersion;
import 'hardware_check.dart';

/// Runs the serial path end to end and shows a report that can be copied and
/// sent back: the quickest way to tell "the sandbox said no" from "the scanner
/// said nothing". Lives in Settings under Diagnostics.
class HardwareCheckCard extends StatefulWidget {
  const HardwareCheckCard({super.key, this.runner, this.saver});

  /// Replaced in tests.
  final Future<String> Function(
    Duration listenFor,
    void Function(String) onProgress,
  )? runner;

  /// Writes the report somewhere and returns where, or null. Replaced in tests.
  final Future<String?> Function(String report)? saver;

  @override
  State<HardwareCheckCard> createState() => _HardwareCheckCardState();
}

class _HardwareCheckCardState extends State<HardwareCheckCard> {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Checks whether this app can open the scanner\'s serial port and talk '
          'to it. Plug in the DataLink 1200 and switch it on first. Student IDs '
          'are masked in the report.',
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
              onPressed: _running ? null : () => _start(const Duration(seconds: 60)),
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
        Semantics(
          label: 'Hardware check report',
          child: SelectableText(
            _report.isEmpty ? 'No report yet.' : _report,
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          ),
        ),
      ],
    );
  }
}
