// Replays tools/goldens/make_protocol_goldens.py against the Dart port.
//
// Every expectation below was produced by running the original Python
// (src/datalink_scanner/interface.py). Regenerate the file, don't edit it:
//
//   .venv/bin/python tools/goldens/make_protocol_goldens.py
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

import 'support/fake_serial.dart';

late final Map<String, Object?> golden;

List<Object?> list(String key) => (golden[key]! as List<Object?>);

Map<String, Object?> asMap(Object? value) => (value! as Map).cast();

/// What a record exposes, minus the wall-clock timestamp.
Map<String, Object?> shown(DataLinkFormRecord record) =>
    record.publicDict(includeRawFields: true)..remove('received_at');

Object? decodeCountInput(Object? input) {
  if (input is Map) {
    if (input.containsKey('float')) return double.parse(input['float']! as String);
    if (input.containsKey('null')) return null;
  }
  return input;
}

void main() {
  setUpAll(() {
    golden = (jsonDecode(
      File('test/goldens/protocol.json').readAsStringSync(),
    ) as Map)
        .cast<String, Object?>();
  });

  test('constants match the Python module', () {
    final constants = asMap(golden['constants']);
    expect(baudRate, constants['baud']);
    expect(expectedFieldCount, constants['expected_field_count']);
    expect(answerStart, constants['answer_start']);
    expect(
      initializationCommands.map(String.fromCharCodes).toList(),
      constants['initialization'],
    );
    expect(
      dataCollectionCommands.map(String.fromCharCodes).toList(),
      constants['data_collection'],
    );
    expect(scannerMessages, constants['messages']);
  });

  group('validateQuestionCount', () {
    test('agrees with Python on every input', () {
      for (final raw in list('question_count')) {
        final entry = asMap(raw);
        final input = decodeCountInput(entry['input']);
        final nonAscii = input is String && input.codeUnits.any((u) => u > 0x7f);
        if (nonAscii) {
          // Known difference: Python's int() reads any Unicode decimal digit
          // ('١٢' is 12). The value comes from a numeric field, so the port
          // accepts ASCII digits only and says it is not a whole number.
          expect(
            () => validateQuestionCount(input),
            throwsA(
              isA<DataLinkError>().having(
                (e) => e.message,
                'message',
                'Questions per form must be a whole number',
              ),
            ),
            reason: 'input $input',
          );
        } else if (entry.containsKey('ok')) {
          expect(validateQuestionCount(input), entry['ok'], reason: '$input');
        } else {
          expect(
            () => validateQuestionCount(input),
            throwsA(
              isA<DataLinkError>().having(
                (e) => e.message,
                'message',
                entry['error'],
              ),
            ),
            reason: '$input',
          );
        }
      }
    });
  });

  group('DataLinkFormRecord.fromLine', () {
    test('agrees with Python on every record', () {
      for (final raw in list('records')) {
        final entry = asMap(raw);
        final name = entry['name']! as String;
        final line = bytesOfHex(entry['line_hex']! as String);
        final count = entry['question_count'];
        if (entry.containsKey('ok')) {
          final record = DataLinkFormRecord.fromLine(line, questionCount: count);
          expect(shown(record), entry['ok'], reason: name);
        } else {
          expect(
            () => DataLinkFormRecord.fromLine(line, questionCount: count),
            throwsA(
              isA<DataLinkError>().having(
                (e) => e.message,
                'message',
                entry['error'],
              ),
            ),
            reason: name,
          );
        }
      }
    });

    test('a stray CR or LF is an unreadable record, not a crash', () {
      // Python's csv module raises csv.Error here, which escaped the stream
      // parser and killed the read loop. The port reports it like any other
      // unreadable line. This is the one deliberate difference.
      for (final raw in list('stray_breaks')) {
        final entry = asMap(raw);
        expect(entry['python'], startsWith('csv.Error'));
        expect(
          () => DataLinkFormRecord.fromLine(bytesOfHex(entry['line_hex']! as String)),
          throwsA(
            isA<DataLinkError>().having(
              (e) => e.message,
              'message',
              'Form record contains a stray line break',
            ),
          ),
          reason: entry['name']! as String,
        );
      }
    });

    test('received_at is formatted as Python isoformat does', () {
      final line = bytesOfHex(asMap(list('records').first)['line_hex']! as String);
      final withMicros = DataLinkFormRecord.fromLine(
        line,
        now: () => DateTime.utc(2026, 9, 16, 18, 5, 7, 802, 284),
      );
      expect(withMicros.receivedAt, '2026-09-16T18:05:07.802284+00:00');
      final whole = DataLinkFormRecord.fromLine(
        line,
        now: () => DateTime.utc(2026, 9, 16, 18, 5, 7),
      );
      expect(whole.receivedAt, '2026-09-16T18:05:07+00:00');
    });
  });

  group('DataLinkStreamParser', () {
    test('agrees with Python step for step', () {
      for (final raw in list('stream')) {
        final entry = asMap(raw);
        final name = entry['name']! as String;
        var now = 0.0;
        final parser = DataLinkStreamParser(
          questionCount: entry['question_count'],
          monotonic: () => now,
        );
        var index = 0;
        for (final stepRaw in entry['steps']! as List<Object?>) {
          final step = asMap(stepRaw);
          now = (step['at']! as num).toDouble();
          final reason = '$name, step ${index++}';
          if (step.containsKey('feed_hex')) {
            final chunk = parser.feed(bytesOfHex(step['feed_hex']! as String));
            expect(chunk.records.map(shown).toList(), step['records'], reason: reason);
            expect(chunk.messages, step['messages'], reason: reason);
          }
          if (step['stale_requested'] == true) {
            expect(parser.takeStaleFragment(), step['stale'], reason: reason);
          }
          expect(hexOf(parser.pendingBytes), step['pending_hex'], reason: reason);
        }
      }
    });
  });

  group('describeMessage', () {
    test('agrees with Python on every line', () {
      for (final raw in list('messages')) {
        final entry = asMap(raw);
        final (kind, text) = describeMessage(entry['text']! as String);
        expect(kind.name, entry['kind'], reason: '${entry['text']}');
        expect(text, entry['shown'], reason: '${entry['text']}');
      }
    });
  });

  group('discoverPort', () {
    test('agrees with Python on every listing', () {
      for (final raw in list('discover_port')) {
        final entry = asMap(raw);
        final found = (entry['found']! as List<Object?>).cast<String>();
        if (entry.containsKey('ok')) {
          expect(discoverPort(found), entry['ok'], reason: '$found');
        } else {
          expect(
            () => discoverPort(found),
            throwsA(
              isA<DataLinkError>().having(
                (e) => e.message,
                'message',
                entry['error'],
              ),
            ),
            reason: '$found',
          );
        }
      }
    });
  });

  group('pyJsonEncode', () {
    test('writes the same bytes as json.dumps', () {
      for (final raw in list('json')) {
        final entry = asMap(raw);
        final value = entry['value'];
        final label = jsonEncode(value);
        expect(pyJsonEncode(value), entry['default'], reason: label);
        expect(pyJsonEncode(value, sortKeys: true), entry['sorted'], reason: label);
        expect(pyJsonEncode(value, compact: true), entry['compact'], reason: label);
        expect(pyJsonEncode(value, indent: 2), entry['indent2'], reason: label);
        expect(
          pyJsonEncode(value, sortKeys: true, indent: 2),
          entry['sorted_indent2'],
          reason: label,
        );
      }
    });
  });

  group('DataLinkScanner against a scripted port', () {
    test('produces the same bytes, delays and answers as Python', () async {
      final deviceReplies = asMap(golden['device_replies']).cast<String, String>();
      // The scenario inputs live in the generator, not in the golden, so each
      // one is rebuilt here from the recorded trace's own first line. To keep
      // the test honest the actions are read back from the golden.
      for (final raw in list('driver')) {
        final entry = asMap(raw);
        final name = entry['name']! as String;
        final scenario = asMap(entry['scenario']);
        final clock = FakeClock();
        final trace = <String>[];
        final transport = ScriptedTransport(
          scenario: scenario,
          clock: clock,
          trace: trace,
          deviceReplies: deviceReplies,
        );
        final scanner = DataLinkScanner(
          '/dev/cu.fake',
          transport: transport,
          clock: clock,
          questionCount: 30,
        );

        final results = <Map<String, Object?>>[];
        for (final actionRaw in scenario['actions']! as List<Object?>) {
          final action = actionRaw is String ? actionRaw : asMap(actionRaw);
          final label = action is String ? action : (action as Map).keys.first as String;
          final result = <String, Object?>{'action': label};
          try {
            switch (label) {
              case 'open':
                await scanner.open();
              case 'close':
                await scanner.close();
              case 'version':
                result['result'] = await scanner.version();
              case 'initialize':
                result['result'] = _transcript(await scanner.initialize());
              case 'enter_data_collection':
                result['result'] = _transcript(await scanner.enterDataCollection());
              case 'resynchronize':
                result['result'] = _transcript(await scanner.resynchronize());
              case 'transact':
                final arg = (action as Map)['transact']! as String;
                result['arg'] = arg;
                result['result'] =
                    await scanner.transact(Uint8List.fromList(arg.codeUnits));
              case 'inject':
                final hex = (action as Map)['inject']! as String;
                result['arg'] = hex;
                transport.connection!.queue.addAll(bytesOfHex(hex));
              case 'read_available':
                final chunk = await scanner.readAvailable();
                result['result'] = {
                  'records': chunk.records.map(shown).toList(),
                  'messages': chunk.messages,
                };
              default:
                fail('unknown action $label');
            }
          } on DataLinkError catch (error) {
            result['error'] = error.message;
          }
          result['at'] = clock.now;
          results.add(result);
        }

        expect(trace, entry['trace'], reason: '$name: trace');
        final expected = (entry['results']! as List<Object?>).map(asMap).toList();
        expect(results.length, expected.length, reason: name);
        for (var i = 0; i < expected.length; i++) {
          final want = expected[i];
          final got = results[i];
          expect(got['action'], want['action'], reason: '$name #$i');
          expect(got['error'], want['error'], reason: '$name #$i error');
          expect(got['result'], want['result'], reason: '$name #$i result');
          expect(
            got['at']! as double,
            closeTo((want['at']! as num).toDouble(), 1e-6),
            reason: '$name #$i time',
          );
        }
      }
    });
  });
}

List<List<String>> _transcript(List<Exchange> exchanges) =>
    [for (final (command, reply) in exchanges) [command, reply]];
