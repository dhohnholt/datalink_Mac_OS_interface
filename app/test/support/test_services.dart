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

class MemorySecrets implements SecretStore {
  final Map<(String, String), String> items = {};

  @override
  Future<String?> read(String service, String account) async => items[(service, account)];

  @override
  Future<void> write(String service, String account, String secret) async =>
      items[(service, account)] = secret;

  @override
  Future<bool> delete(String service, String account) async =>
      items.remove((service, account)) != null;
}

/// A site that answers from a script; the last answer repeats.
class ScriptedHttp implements HttpTransport {
  ScriptedHttp([List<Object>? outcomes]) : outcomes = outcomes ?? [];

  final List<Object> outcomes;
  final List<({String method, Uri url, Map<String, String> headers, List<int>? body})> calls = [];

  @override
  Future<HttpReply> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    calls.add((method: method, url: url, headers: headers, body: body));
    if (outcomes.isEmpty) throw const SocketException('No site in tests');
    final outcome = outcomes[calls.length - 1 < outcomes.length ? calls.length - 1 : outcomes.length - 1];
    if (outcome is Exception) throw outcome;
    return outcome as HttpReply;
  }
}

HttpReply reply(int status, [Map<String, Object?> body = const {}]) => (status: status, body: body);

/// Services over an in-memory library and a temp folder, with no hardware.
AppServices testServices({
  Store? store,
  RecordingActions? actions,
  SerialTransport? transport,
  Clock? clock,
  DateTime Function()? now,
  MemorySecrets? secrets,
  ScriptedHttp? http,
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
    ttess: TtessClient(
      store: db,
      secrets: secrets ?? MemorySecrets(),
      http: http ?? ScriptedHttp(),
      sleep: (_) async {},
    ),
    portPollInterval: null,
  );
}

