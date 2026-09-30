import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/services.dart';

import 'live_fake.dart';

/// A transport with no scanner attached.
class NoScannerTransport implements SerialTransport {
  @override
  Future<List<String>> listPorts() async => const [];

  @override
  Future<SerialConnection> open(String path, SerialSettings settings) =>
      throw const DataLinkError('No scanner in tests');
}

/// Records what the screen asked the operating system to do.
class RecordingActions implements PlatformActions {
  final List<({String name, String text, String extension})> saved = [];
  final List<String> revealed = [];
  final List<String> opened = [];
  String? nextSavePath = '/tmp/saved';

  @override
  Future<String?> saveText({
    required String suggestedName,
    required String text,
    required String extension,
  }) async {
    saved.add((name: suggestedName, text: text, extension: extension));
    return nextSavePath;
  }

  @override
  Future<void> reveal(String directory) async => revealed.add(directory);

  @override
  Future<void> openUrl(String url) async => opened.add(url);
}

/// Services over an in-memory library and a temp folder, with no hardware.
AppServices testServices({
  Store? store,
  RecordingActions? actions,
  SerialTransport? transport,
  Clock? clock,
  DateTime Function()? now,
}) {
  final db = store ?? Store.open(':memory:');
  final directory = Directory.systemTemp.createTempSync('datalink-app-test');
  return AppServices(
    store: db,
    workspace: Workspace(store: db, now: now ?? () => DateTime.utc(2026, 9, 30, 12), newId: () => 'run-1'),
    scanner: ScannerController(
      captureRoot: directory,
      store: db,
      transport: transport ?? NoScannerTransport(),
      clock: clock ?? YieldingClock(),
    ),
    actions: actions ?? RecordingActions(),
    dataDirectory: directory,
    portPollInterval: null,
  );
}

