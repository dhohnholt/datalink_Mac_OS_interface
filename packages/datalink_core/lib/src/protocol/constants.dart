/// Protocol constants. Ported from `src/datalink_scanner/interface.py`; the
/// comments there carry the evidence for each value and are not repeated here.
library;

import 'dart:convert';
import 'dart:typed_data';

const int baudRate = 38400;
const int expectedFieldCount = 211;
const int answerStart = 10;
const int studentIdField = 0;

/// Field 1 is the scanner's own score, marked against a key held in the
/// device. It reads `000` when no key is loaded, which is indistinguishable
/// from a sheet that scored nothing.
const int scannerScoreField = 1;

const int defaultAnswerCount = 50;
const int minAnswerCount = 1;
const int maxAnswerCount = 100;
const int protocolAnswerCeiling = expectedFieldCount - answerStart;

Uint8List _ascii(String text) => Uint8List.fromList(ascii.encode(text));

/// Exact host payloads observed during the initial DataLink Connect session.
/// Commands carry no terminator; replies end in CRLF.
final List<Uint8List> initializationCommands = List.unmodifiable(
  <String>[
    'V', 'R1', 'R5', 'T2', 'N8', 'A8', 'M8', 'M0', 'Q1', 'P5', 'X7', 'T4',
  ].map(_ascii),
);

/// The transition seen around Data Collection. `M6` is the only command absent
/// from the ordinary reinitialisation sequence.
final List<Uint8List> dataCollectionCommands = List.unmodifiable(
  <String>['R1', 'R5', 'M6', 'N8', 'A8', 'M8', 'M0'].map(_ascii),
);

const String unreadableRecord = 'Unreadable form record skipped';

const Map<String, String> scannerMessages = {
  'D1':
      'The scanner is waiting for side 1 of a two-sided form. '
      'It will not take another sheet until it has it — use Reset scanner '
      'to take it back to a fresh sheet.',
  'D2':
      'The scanner is waiting for side 2 of a two-sided form. '
      'It will not take another sheet until it has it — feed the back of '
      'that sheet, or use Reset scanner if the form is one-sided.',
};
