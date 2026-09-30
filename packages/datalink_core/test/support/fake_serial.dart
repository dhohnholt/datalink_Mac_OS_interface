import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';

/// Virtual time: sleeping and empty reads advance it, nothing actually waits.
class FakeClock implements Clock {
  double now = 0;

  @override
  double monotonic() => now;

  @override
  Future<void> sleep(double seconds) async {
    now += seconds;
  }
}

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List bytesOfHex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

/// The Dart twin of `FakeSerial` in tools/goldens/make_protocol_goldens.py.
///
/// It writes the same trace lines, so a scenario run through the Python driver
/// and through the Dart one can be compared line for line.
class ScriptedConnection implements SerialConnection {
  ScriptedConnection({
    required this.scenario,
    required this.clock,
    required this.trace,
    required this.deviceReplies,
  });

  final Map<String, Object?> scenario;
  final FakeClock clock;
  final List<String> trace;
  final Map<String, String> deviceReplies;

  final List<int> queue = <int>[];
  final List<Uint8List> pending = <Uint8List>[];
  final Map<String, int> _sent = <String, int>{};
  static const double _timeout = 0.05;

  void log(String text) => trace.add('${clock.now.toStringAsFixed(3)} $text');

  String _python(bool value) => value ? 'True' : 'False';

  @override
  Future<void> setDtr({required bool on}) async => log('dtr=${_python(on)}');

  @override
  Future<void> setRts({required bool on}) async => log('rts=${_python(on)}');

  @override
  int get inWaiting => queue.length;

  @override
  Future<void> resetInputBuffer() async {
    queue.clear();
    log('reset_input_buffer');
  }

  @override
  Future<void> write(Uint8List data) async {
    final command = String.fromCharCodes(data);
    log('write $command');
    final count = _sent[command] ?? 0;
    _sent[command] = count + 1;

    final replies = (scenario['replies'] as Map<String, Object?>?) ?? const {};
    final scripted = replies[command];
    String hex;
    if (scripted == null) {
      hex = deviceReplies[command] ?? '';
    } else {
      final list = scripted as List<Object?>;
      hex = list[count < list.length ? count : list.length - 1]! as String;
    }
    final bytes = bytesOfHex(hex);
    final chunk = scenario['chunk'] as int?;
    if (chunk != null && chunk > 0) {
      for (var i = 0; i < bytes.length; i += chunk) {
        pending.add(
          Uint8List.sublistView(
            bytes,
            i,
            i + chunk > bytes.length ? bytes.length : i + chunk,
          ),
        );
      }
    } else {
      queue.addAll(bytes);
    }
  }

  @override
  Future<void> flush() async => log('flush');

  @override
  Future<Uint8List> read(int size) async {
    if (queue.isEmpty && pending.isNotEmpty) queue.addAll(pending.removeAt(0));
    if (queue.isNotEmpty) {
      final take = size < queue.length ? size : queue.length;
      final out = Uint8List.fromList(queue.sublist(0, take));
      queue.removeRange(0, take);
      log('read ${out.length}');
      return out;
    }
    clock.now += _timeout;
    log('read 0');
    return Uint8List(0);
  }

  @override
  Future<void> close() async => log('close');
}

class ScriptedTransport implements SerialTransport {
  ScriptedTransport({
    required this.scenario,
    required this.clock,
    required this.trace,
    required this.deviceReplies,
  });

  final Map<String, Object?> scenario;
  final FakeClock clock;
  final List<String> trace;
  final Map<String, String> deviceReplies;
  ScriptedConnection? connection;

  @override
  Future<List<String>> listPorts() async => const ['/dev/cu.fake'];

  @override
  Future<SerialConnection> open(String path, SerialSettings settings) async {
    trace.add(
      '${clock.now.toStringAsFixed(3)} open $path baud=${settings.baudRate} '
      'bytesize=${settings.dataBits} parity=N stopbits=${settings.stopBits} '
      'timeout=${_py(settings.readTimeoutSeconds)} '
      'write_timeout=${_py(settings.writeTimeoutSeconds)}',
    );
    return connection = ScriptedConnection(
      scenario: scenario,
      clock: clock,
      trace: trace,
      deviceReplies: deviceReplies,
    );
  }

  static String _py(double v) => v.toString();
}
