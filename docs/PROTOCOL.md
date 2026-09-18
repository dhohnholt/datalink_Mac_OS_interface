DataLink 1200 Project Status

> Student IDs in this document are synthetic. The real IDs from the capture
> sessions were replaced one-for-one, so every comparison between sheets
> still holds.

What we are doing

Two parallel efforts, both aimed at getting usable exam data out of Apperson DataLink 1200 / Advantage 1200 scantron sheets, without relying on the old (broken, unsupported on current macOS) DataLink Connect software.

Track 1 — Software-only OMR (working, in use today). Scan sheets with a regular document scanner (ScanSnap S1500) to PDF, then use computer vision to read the bubbles directly from the scanned images. No hardware protocol needed. This is fully built and working: it reads student IDs and all 50 answers per sheet, auto-corrects for sheets fed at different rotations/scan registration, scores against a key, and produces item analysis. Proven accurate against hand-checked sheets across two different physical answer-sheet layouts.

Track 2 — Talking to the DataLink 1200 scanner directly (in progress). The scanner itself is a self-contained USB device that presumably already does its own scoring (it prints a score directly onto each sheet after scanning). If we can decode what it sends over its serial connection, we could get live, direct-from-hardware results instead of scan-then-process. This is the reverse-engineering effort described below.

What we have learned (Track 2 — hardware protocol)
Hardware identity — CONFIRMED
The DataLink 1200 connects over USB and enumerates as a standard serial device (not HID, not proprietary USB).
Chip: Silicon Labs CP210x USB-to-UART bridge.
VID:PID = 10c4:ea60
macOS device path: /dev/cu.usbserial-1200
USB descriptor identifies it as "Advantage 1200 Scanner" — confirms the "Formerly Advantage" branding printed on the answer sheets refers to this same product line.
Communication requirements — CONFIRMED
The official Windows USB capture configures the CP210x for 38,400 baud, 8N1,
DTR off, and RTS on immediately before sending `V`. Replaying that exact
configuration on macOS produced `ADV 1200OK\r\n`. Earlier passive captures at
9,600 baud were mis-decoded status bytes and must not be used as the online
protocol rate.
Bytesize 8 / parity None / stopbits 1, confirmed by the Windows CP210x line-control transfer.
Packet structure — HYPOTHESIS, partially supported
The first active capture contains 52 bytes that align into 13 groups of four by timing. However, an idle/no-sheet capture also received `63 43 4a aa` about 15 seconds after opening the port. A later clean two-minute idle capture received no bytes, ruling out a simple periodic heartbeat and making delayed/buffered scanner output more likely. Therefore four-byte groups are confirmed observations, but “one group equals one completed sheet” is not established.
Messages seen near sheet feeds are small (~4 bytes) and arrive shortly after the sheet finishes passing through the scanner.
4 bytes is too small to be a full scan record (30-50 question responses + a multi-digit student ID cannot fit in 4 bytes). This strongly suggests the scanner does on-board scoring and transmits only a compact result/status, not raw per-bubble data.
Supporting evidence for on-board scoring: the physical sheets have a printed SCORE box that gets filled in by the scanner itself after a pass — this is a physical, on-paper printout, separate from whatever goes over the serial line.
Observed packets share structural similarities (e.g. recurring 4a byte, tails like aa/ab that differ by exactly 1) but no confirmed meaning has been assigned to any byte position yet.
In a corrected three-pass trial of the same known sheet (student `900011`,
22/30), the scanner emitted `f7 42 4a ab`, then `f7 0c 42 53`, then
`f7 0c 42 53`. Each group arrived 2.7–3.0 seconds after its trial began, so
all three are valid sheet-associated messages. The latter value also occurred
in the original active batch. This proves repeatable protocol values exist but
shows that a sheet's output can depend on pass or scanner state.
One plausible, unconfirmed model is a compact correctness/error bitmap: a
30-question result can fit in 32 bits even though complete answers plus ID
cannot. Controlled scans of different sheets are required before adopting it.
A second three-pass trial (student `900006`, 25/30) emitted `4a 43 4a ab`,
`e7 62 62 e8`, then `4a 43 4a ab`. The scanner printed the same score on
every pass, so visible score printing does not explain the alternate middle
message. The dominant repeatable value differs from student `900011`'s,
showing the protocol is not a single constant success/status message. Byte
arrival spacing is approximately 1.04 ms, consistent with 9600 baud 8N1.
Whether a Key sheet needs to be scanned first (to give the device something to score against) is unconfirmed — this matters because score-shaped packets only make sense if the device has a key loaded.
What is NOT yet known
What any individual byte in the ~4-byte packet actually encodes (score? sheet count? checksum? student ID fragment? some combination?)
Whether packet length is always 4 bytes or varies (e.g. with ID length, with error conditions, with Key vs. Verify vs. Rescore mode)
Whether a Key sheet was scanned before the 15-sheet batch that produced our capture, and if so, in what mode (Key/Verify/Rescore checkbox on the sheet itself controls this, per the sheet's own printed header)
The relationship (if any) between the header checkboxes (Key / Verify / Rescore) and packet content

Web research — 2026-09-15

- The official DataLink 1200 manual explicitly tells developers of customized
  interfaces to contact Apperson for its "communication specifications." This
  confirms a formal protocol document existed, but it is not published in the
  user manual:
  https://www.apperson.com/wp-content/uploads/2017/04/DL1200-Users-Manual.pdf
- The manual describes DataLink Connect as retrieving data from the scanner.
  Official DataLink 3000 documentation also says Connect can enter Data
  Collection mode, disable onboard scoring, and download electronic keys.
  Those operations require host-to-scanner commands rather than passive
  receive-only listening.
- Apperson-related patent US 6,079,624 says normalized sensor read levels are
  transmitted to a scanner serial port. Patent US 6,736,319 describes PC
  software receiving, analyzing, and interpreting scanned-card data while also
  controlling reader operation:
  https://patents.google.com/patent/US6736319B2/en
- Schoolnet documentation lists the Advantage 1200 as supported through a USB
  emulated serial port, corroborating the CP210x transport discovery.
- DataLink Connect saves sessions as `.APXT` and exports ASCII/spreadsheet
  data, but no public APXT or wire-protocol specification was found.

Revised interpretation: four-byte messages observed in standalone/offline mode
are likely status/event messages, not full scan records. DTR/RTS enables serial
transmission but does not establish the application-level online session. Full
mark data probably requires a bidirectional command/response exchange initiated
by DataLink Connect. Future work should prioritize obtaining the communication
specification or capturing/reconstructing that host handshake instead of
assigning score meanings to passive four-byte data.

Installer inspection confirms this revision. DataLink Connect 4.5 contains an
`AppersonScanner` implementation with `InitializeScanner`, `Transact`,
`ProcessPacket`, `SetCurrentScanningMode`, `Key1200Binary`, and
`WriteQuestions`. Its receive path creates `RawFormData` memory blocks and then
uses XML `.apft` templates to interpret channel/row marks. The application also
has a built-in `LogScannerData` preference described as "Log scanner data
(requires restart)," with TX/RX log labels. Capturing that official diagnostic
log is now the preferred protocol-discovery method.

Windows DataLink Connect capture — CONFIRMED 2026-09-16

- Windows enumerated the scanner on `COM7` as a Silicon Labs CP210x USB-to-UART
  bridge, PNP ID `USB\\VID_10C4&PID_EA60\\1200`.
- DataLink Connect's debug trace identifies its driver as
  `\\Device\\Silabser0` and selects `COM7` as the only acceptable serial port.
- Its scanner-discovery transaction is now known exactly: the host sends the
  single ASCII command `V`, and the scanner returns ` ADV 1200OK` (one leading
  space). The trace then reports that the scanner was found.
- DataLink Connect calls `Scanner.InitializeScanner` next and receives at least
  seven `Scanner.DataAvailable` events before reporting `Initialized scanner`.
  The trace does not expose the initialization bytes.
- Connection and initialization did not by themselves place the scanner into
  full-data operation. The operator then clicked **Data Collection** in
  DataLink Connect, which sent a mode-changing command to the scanner. Many
  more `Scanner.DataAvailable` events occurred after this interaction. This
  separates scanner discovery/initialization from the application-level Data
  Collection mode required for full form data.
- The built-in `ScannerLog` was enabled and started but contains only its
  50-byte session header. It did not preserve TX/RX payloads in this run.
- The saved `.APXT` session is 2,482 bytes and the temporary and named copies
  are byte-identical. It appears compressed or encrypted and is not currently
  a substitute for the missing wire capture.

The immediate protocol targets are the command sequence issued by
`InitializeScanner` and, especially, the command issued by
`SetCurrentScanningMode(DataCollection)`. A direct Mac probe should first
reproduce only the safe `V`/` ADV 1200OK` transaction. Reconstructing the Data
Collection mode switch is required before trying to parse full form packets.

USBPcap recovery — CONFIRMED 2026-09-16

- `shark.pcapng` and `shark2.pcapng` contain CP210x bulk transfers for device
  `10c4:ea60`: host writes on endpoint `0x01`, scanner reads on `0x81`.
- Commands have no CR/LF terminator. Normal replies end in CR/LF.
- CP210x control transfers set baud to little-endian `00 96 00 00` (38,400),
  line control to `0x0800` (8N1), disable flow control, leave DTR off, and turn
  RTS on. This configuration was reproduced successfully on macOS.
- Discovery is ASCII `V`; the wire reply is `ADV 1200OK\r\n`.
- The observed initial command sequence is `V`, `R1`, `R5`, `T2`, `N8`, `A8`,
  `M8`, `M0`, `Q1`, `P5`, `X7`, `T4`.
- The transition sequence observed around Data Collection activity is `R1`,
  `R5`, `M6`, `N8`, `A8`, `M8`, `M0`. `M6` is the only command not present in
  the ordinary reinitialization sequence and is the leading Data Collection
  mode candidate. The complete sequence is used until a smaller sequence is
  proven against hardware.
- `shark2.pcapng` contains three complete form records. Each is 371 bytes,
  CRLF-terminated ASCII CSV with exactly 211 fields.
- Zero-based fields 10 through 59 are the 50 question responses. Observed
  values include single letters `A`–`D` and combined letters such as `AC`
  when an erasure leaves two detectable marks. The parser also accepts `E`,
  blank, and `*`. The browser sends combined readings to operator review.
- In the captured Data Collection records, metadata fields outside the answer
  range do not contain the bubbled student ID. The browser therefore prompts
  for the ID after every student sheet and stores it alongside the record.
- Field 0 is the 12-character student-ID slot. This was confirmed by a live
  sheet whose bubbled ID `900014` was transmitted as `900014` in that field.
  The parser exposes a digits-only value from this field as `scanner_id`.
- The direct parser successfully replayed all three captured records and
  emitted three records containing exactly 50 answers each.

Implementation: `scripts/datalink_interface.py` performs the captured exchange,
streams records, validates their structure, and writes privacy-minimal JSONL.
Live scanner writes require `--acknowledge-writes` while Mac hardware validation
remains pending.
Ground truth now available for decoding

We have a real, scored batch to work from: a 16-page scan (5-5-5th.pdf) containing 1 answer key + 15 student sheets, all processed through the Track 1 OMR pipeline:

Page Student ID Correct/30 Blank Multiple
02 900011 22 1 0
03 900006 25 0 0
04 900012 16 0 0
05 900009 18 0 1
06 900008 15 0 0
07 90001? 12 11 1
08 900014 27 0 0
09 900005 16 0 0
10 900003 17 0 0
11 900001\* 15 0 0
12 900004 7 1 0
13 900002 25 0 0
14 900013 21 0 0
15 900010 29 0 0
16 900007 6 5 0

- Page 11's ID was read from handwriting only — the bubbles were never filled in, so treat this one ID as lower-confidence than the rest.

We also have one real serial capture: 13 packets (~4 bytes each) captured while sheets were fed through by hand, roughly every 1.5-2 seconds. The feed order of that capture has not yet been matched to the table above — that match is the single most valuable next step, since it turns 13 opaque byte groups into 13 byte-groups-with-known- answers.

What remains to be done
Determine whether stale output can remain buffered across port sessions. Scan a sheet with the port closed, then open a capture without feeding another sheet and observe whether a message arrives.
Match capture order to known data. Get the exact order sheets were fed during the 13-packet capture (by student ID or page number from the table above). Without this, the packets can't be correlated to anything.
Re-capture cleanly, one sheet at a time, with labels. Feed one sheet, stop, label the capture with that sheet's known ID/score, repeat. This avoids the ambiguity of a continuous multi-sheet capture and gives a clean 1-packet-to-1-sheet mapping.
Test the on-board-scoring hypothesis directly. Feed the exact same sheet through twice in separate captures — if the packet is identical both times, that's consistent with a deterministic score/status encoding (not, say, a random session ID or a running counter).
Vary one known quantity at a time. E.g. feed sheets with the same ID but different scores, or the same score but different IDs, to see which packet bytes move in response to which input — standard technique for isolating what a field encodes.
The next preferred comparison is student `900002` (25/30) against student
`900006` (also 25/30), which holds score constant while changing ID and answer
pattern.
That comparison is now complete. Student `900002` emitted `4a 43 4a aa` on
all three passes, while student `900006`'s dominant value was `4a 43 4a ab`.
Thus two different sheets with the same 25/30 score share the first 31 bits
and differ only in the least-significant bit. This is strong evidence that the
message primarily represents a scored result rather than student ID or the
complete answer pattern. The final bit may be a flag or checksum/parity bit;
its meaning is unconfirmed.
Student `900014` (27/30) subsequently emitted `62 43 4a ab` on all three
passes. Against the stable 25/30 value `4a 43 4a aa`, bytes 2 and 3 are
unchanged, while byte 1 changes with score and the final low bit changes.
This localizes at least part of the score encoding to byte 1. More score points
are needed to derive the encoding rather than constructing an unsafe lookup.
Student `900010` (29/30) then emitted `63 42 4a aa` on all three passes.
Because both bytes 1 and 2 differ from the 27/30 value, score is not a simple
integer isolated to byte 1. The result appears bit-packed, but its
representation is not yet known.
Student `900012` (16/30) emitted `f7 42 4a aa` on all three passes. The same
first 31 bits appeared as `f7 42 4a ab` on one anomalous pass of the 22/30
sheet, so either the low bit distinguishes message context or the scanner can
emit a different result/status than the visibly printed score. A second clean
16/30 sheet is required before assigning this value to score 16.
That cross-check failed: student `900005`, also 16/30 according to the
software OMR report, emitted `62 43 4a ab` on all three passes—the exact value
emitted by student `900014` (software OMR 27/30). Therefore packets do not
encode the software-derived score alone. The scores physically printed by the
DataLink must be recorded because its loaded answer key may differ from the
software OMR key. Treat all current `known_score` labels as software scores,
not yet as hardware ground truth.
Before further packet mapping, transcribe the score physically printed on each
controlled-test sheet and verify which answer key is loaded in the scanner.
Determine whether a Key scan is a precondition. Try capturing with and without a Key sheet scanned first, to see if packet behavior changes (e.g. garbage/error data vs. real score data).
Once a byte mapping is hypothesized, verify by prediction — don't just fit the known captures, predict what a new sheet's packet should look like before scanning it, then check.

Until the above is done, all packet-content claims stay in the HYPOTHESIS category per docs/PROTOCOL.md's confirmed/hypothesis convention — nothing about byte meaning should be treated as settled.

Scanner status messages — HYPOTHESIS 2026-09-18

A live session stopped after the answer key: the scanner asked for the other
side of the sheet and then refused to feed anything until it was taken out of
Data Collection at the device. That prompt is Apperson's own. DataLink
Connect's localized string table pairs each message with a key, and two of
those keys carry a two-character code that no other key has:

    StringsErrors.kD1InsertSide1   "Insert Side 1"
    StringsErrors.kD2InsertSide2   "Insert Side 2"

`D1` and `D2` are therefore the leading candidates for the codes the scanner
sends on its serial line when it is waiting for a side of a two-sided form.
This is a HYPOTHESIS: neither `shark.pcapng` nor `shark2.pcapng` contains a
side-2 event, so the codes are inferred from the key names and not observed on
the wire. `SCANNER_MESSAGES` in `interface.py` translates them, and any line
that is neither a form record nor `OK` is surfaced verbatim as a warning, so a
wrong guess costs nothing and the real code will show itself the next time a
sheet jams.

Confirming this needs one experiment: feed a two-sided form (or any sheet the
scanner treats as one) with the workspace connected, and read the line the
Activity list prints. Record it here either way.

The same string table names two other conditions worth watching for, both
consistent with what was observed:

    kKeyReset       "The key on the scanner was reset.  You must either
                     re-key the scanner ... or clear the session and begin
                     scanning again."
    kKeyRequired    "A key is required to scan this form."

Recovery — CONFIRMED by construction

Re-sending the captured handshake on an already-open port
(`DirectDataLinkScanner.resynchronize`) is byte-identical to what connecting
already sends: `INITIALIZATION_COMMANDS` followed by `DATA_COLLECTION_COMMANDS`.
No new command is written to the device. It is the software equivalent of
taking the scanner out of Data Collection and putting it back, which is what
cleared the jam by hand.
