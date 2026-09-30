import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';

/// Time for controller tests: sleeping advances a virtual clock and yields to
/// the event loop, so background loops make progress without real waiting.
class YieldingClock implements Clock {
  double now = 0;

  @override
  double monotonic() => now;

  @override
  Future<void> sleep(double seconds) async {
    now += seconds;
    await Future<void>.delayed(Duration.zero);
  }
}

/// A scripted scanner behind a [SerialTransport]: it answers commands the way
/// the captured device did, and lets a test push arbitrary bytes at the host.
class LiveFakeTransport implements SerialTransport {
  LiveFakeTransport({
    required this.clock,
    this.ports = const ['/dev/cu.usbserial-1200'],
    Map<String, String>? replies,
  }) : replies = replies ?? defaultReplies;

  static const Map<String, String> defaultReplies = {
    'V': 'ADV 1200OK\r\n',
    'R1': 'OK\r\n',
    'R5': 'OK\r\n',
    'T2': '5.5\r\n',
    'N8': 'OK\r\n',
    'A8': 'OK\r\n',
    'M8': 'OK\r\n',
    'M0': 'OK\r\n',
    'Q1': '4658\r\n',
    'P5': '0009654,0000387,0009654,\r\n',
    'X7': '11/22/11 Standard\r\n',
    'T4': 'S32155\r\n',
    'M6': 'OK\r\n',
  };

  final Clock clock;
  final List<String> ports;
  final Map<String, String> replies;

  /// Every command the host wrote, in order.
  final List<String> written = <String>[];
  LiveFakeConnection? connection;

  /// When set, the next `read` throws it: a device that vanished.
  Object? failReadsWith;

  @override
  Future<List<String>> listPorts() async => ports;

  @override
  Future<SerialConnection> open(String path, SerialSettings settings) async {
    return connection = LiveFakeConnection(this);
  }

  /// Put bytes in front of the host, as the scanner would send them.
  void send(List<int> bytes) => connection!.queue.addAll(bytes);

  void sendText(String text) => send(ascii.encode(text));

  /// A complete 211-field record line, CRLF-terminated.
  void sendRecord(
    List<String> responses, {
    String studentId = '900011',
    String? score,
  }) {
    final fields = List<String>.filled(expectedFieldCount, '');
    fields[0] = studentId;
    if (score != null) fields[1] = score;
    for (var i = 0; i < responses.length; i++) {
      fields[answerStart + i] = responses[i];
    }
    sendText('${fields.join(',')}\r\n');
  }
}

class LiveFakeConnection implements SerialConnection {
  LiveFakeConnection(this.transport);

  final LiveFakeTransport transport;
  final List<int> queue = <int>[];
  bool closed = false;

  @override
  Future<void> setDtr({required bool on}) async {}

  @override
  Future<void> setRts({required bool on}) async {}

  @override
  int get inWaiting => queue.length;

  @override
  Future<void> resetInputBuffer() async => queue.clear();

  @override
  Future<void> write(Uint8List data) async {
    final command = String.fromCharCodes(data);
    transport.written.add(command);
    final reply = transport.replies[command];
    if (reply != null) queue.addAll(ascii.encode(reply));
  }

  @override
  Future<void> flush() async {}

  @override
  Future<Uint8List> read(int size) async {
    final failure = transport.failReadsWith;
    if (failure != null) throw failure;
    if (queue.isEmpty) {
      // A real empty read waits out its 50 ms timeout; spend that on the
      // virtual clock so deadline loops terminate, and give the event loop a
      // turn as the wait would.
      final clock = transport.clock;
      if (clock is YieldingClock) clock.now += 0.05;
      await Future<void>.delayed(Duration.zero);
      return Uint8List(0);
    }
    final take = size < queue.length ? size : queue.length;
    final out = Uint8List.fromList(queue.sublist(0, take));
    queue.removeRange(0, take);
    return out;
  }

  @override
  Future<void> close() async => closed = true;
}

/// Let background loops run until [done] holds, or fail after [turns] turns.
Future<void> pumpUntil(bool Function() done, {int turns = 400}) async {
  for (var i = 0; i < turns; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  if (!done()) throw StateError('condition not reached after $turns turns');
}
