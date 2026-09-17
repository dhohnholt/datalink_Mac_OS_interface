# Testing / Experiment Log

> Student IDs in this document are synthetic. The real IDs from the capture
> sessions were replaced one-for-one, so every comparison between sheets
> still holds.


Every controlled experiment run against the DataLink 1200 gets an entry
here: what was scanned, what was expected to change, what actually
changed, and what capture file(s) it produced.

---

## Phase 1 — Hardware discovery

### Experiment 1.1 — Baseline (scanner unplugged)
- **Date:**
- **Script:** `scripts/01_baseline_unplugged.sh`
- **Output:** `~/Desktop/datalink-captures/baseline.txt`
- **Result:**

### Experiment 1.2 — Connected snapshot + diff
- **Date:**
- **Script:** `scripts/02_connected.sh`
- **Output:** `~/Desktop/datalink-captures/connected.txt`, `diff.txt`
- **Result:**

---

## Phase 2 — Communication method

### Experiment 2.1 — Passive serial receive observed
- **Date:** 2026-09-15
- **Device:** CP210x, VID:PID `10c4:ea60`, `/dev/cu.usbserial-1200`
- **Settings:** initially interpreted at 9600 baud, 8N1, DTR and RTS asserted
- **Result:** Four-byte passive messages were observed, but the subsequent
  USBPcap capture proved this was not the official online-session configuration.

---

## Phase 3 — Protocol discovery

### Experiment 3.1 — First active batch
- **Date:** 2026-09-15
- **Capture:** `captures/first_real_capture_20260915_133840/`
- **Result:** 52 bytes in 13 timing-separated groups of four. Feed order was not
  recorded, so byte meanings cannot be correlated to known sheets.

### Experiment 3.2 — Idle/no-sheet capture
- **Date:** 2026-09-15
- **Capture:** `captures/idle_no_sheet_20260915_134236/`
- **Result:** Received `63 43 4a aa` about 15.4 seconds after opening the port.
  This weakens the hypothesis that every four-byte group is necessarily a
  completed-sheet result. Repeat with a longer idle observation.

### Experiment 3.3 — Two-minute idle capture
- **Date:** 2026-09-15
- **Capture:** `captures/idle_2min_20260915_140028/`
- **Result:** Zero bytes in 120 seconds with DTR/RTS asserted. The earlier idle
  message is not a simple heartbeat repeating at 15-second intervals. A delayed
  or buffered result from activity before that capture remains plausible.

### Experiment 3.4 — First repeated-sheet attempt (invalid trial boundaries)
- **Date:** 2026-09-15
- **Sheet:** Student ID `900011`, known score 22/30, fed three times
- **Capture:** `captures/controlled_repeat_900011_20260915_140447/`
- **Observed:** `63 43 4a aa`, `4a 62 62 e8`, `42 42 4a aa`
- **Result:** Inconclusive. Trial 1 arrived 4.67 seconds after the trial began,
  but trials 2 and 3 were read just 62 microseconds after Enter. They were
  already buffered while the operator prompt was waiting and cannot be safely
  associated with those sheet feeds. `controlled_capture.py` was corrected to
  clear and report pending bytes after Enter, immediately before each trial.

### Experiment 3.5 — Corrected repeated-sheet trial
- **Date:** 2026-09-15
- **Sheet:** Student ID `900011`, known score 22/30, fed three times
- **Capture:** `captures/controlled_repeat_900011_fixed_20260915_140613/`
- **Observed:** `f7 42 4a ab`, `f7 0c 42 53`, `f7 0c 42 53`
- **Timing:** Messages began 2.735, 3.041, and 2.811 seconds after their
  respective trials; all are valid sheet-associated observations.
- **Result:** Passes 2 and 3 are deterministic. Their value exactly matches the
  second four-byte group in the original active capture. Pass 1 differs, so
  output may depend on scanner state, sheet mode, or a physical change made by
  the first pass. Byte meaning remains unconfirmed.

### Experiment 3.6 — Second repeated sheet
- **Date:** 2026-09-15
- **Sheet:** Student ID `900006`, known score 25/30, fed three times
- **Capture:** `captures/controlled_repeat_900006_20260915_140930/`
- **Observed:** `4a 43 4a ab`, `e7 62 62 e8`, `4a 43 4a ab`
- **Timing:** Messages began 2.200, 2.312, and 2.412 seconds after their trials.
  Bytes within each message were spaced approximately 1.04 ms apart.
- **Result:** Passes 1 and 3 are deterministic; pass 2 is an alternate despite
  the scanner printing the same score each time. The repeatable value differs
  from the prior sheet's repeatable value, so these are not constant success
  messages. Test another 25/30 sheet next to separate score from sheet content.

### Experiment 3.7 — Same-score comparison
- **Date:** 2026-09-15
- **Sheet:** Student ID `900002`, known score 25/30, fed three times
- **Capture:** `captures/controlled_repeat_900002_20260915_141121/`
- **Observed:** `4a 43 4a aa` on all three passes
- **Result:** Fully deterministic. Student `900006`, also 25/30, predominantly
  emitted `4a 43 4a ab`. The two values share their first 31 bits and differ
  only in the least-significant bit. This strongly supports score/result data
  with a one-bit sheet-specific flag or checksum, rather than an encoded ID or
  full answer pattern. Test a clean sheet with another score next.

### Experiment 3.8 — Different clean score (27/30)
- **Date:** 2026-09-15
- **Sheet:** Student ID `900014`, known score 27/30, fed three times
- **Capture:** `captures/controlled_repeat_900014_20260915_141230/`
- **Observed:** `62 43 4a ab` on all three passes
- **Result:** Fully deterministic. Relative to the stable 25/30 value
  `4a 43 4a aa`, bytes 2 and 3 remain fixed, byte 1 changes, and the low bit of
  byte 4 changes. This strongly localizes score information to byte 1, with a
  possible flag/check bit in byte 4.

### Experiment 3.9 — Different clean score (29/30)
- **Date:** 2026-09-15
- **Sheet:** Student ID `900010`, known score 29/30, fed three times
- **Capture:** `captures/controlled_repeat_900010_20260915_141330/`
- **Observed:** `63 42 4a aa` on all three passes
- **Result:** Fully deterministic. Bytes 1 and 2 differ from the 27/30 value,
  disproving the provisional idea that score changes only byte 1. The result
  appears bit-packed. Next test two clean sheets with the same lower score to
  validate that matching packets follow score rather than answer pattern.

### Experiment 3.10 — First clean 16/30 sheet
- **Date:** 2026-09-15
- **Sheet:** Student ID `900012`, known score 16/30, fed three times
- **Capture:** `captures/controlled_repeat_900012_20260915_141513/`
- **Observed:** `f7 42 4a aa` on all three passes
- **Result:** Fully deterministic. The first 31 bits match one anomalous pass
  previously seen from the 22/30 sheet. Do not assign this code to score 16
  until the second clean 16/30 sheet reproduces it.

### Experiment 3.11 — Second OMR 16/30 sheet; score hypothesis contradicted
- **Date:** 2026-09-15
- **Sheet:** Student ID `900005`, software OMR score 16/30, fed three times
- **Capture:** `captures/controlled_repeat_900005_20260915_141621/`
- **Observed:** `62 43 4a ab` on all three passes
- **Result:** Fully deterministic, but exactly matches student `900014`, whose
  software OMR score is 27/30. Packets therefore do not encode the software OMR
  score alone. Record the score physically printed by the scanner for every
  tested sheet and confirm the scanner's loaded key before further inference.

### Test A — Sheet: 1=A 2=B 3=C 4=D 5=E, rest blank
- **Date:**
- **Capture file:**
- **Notes:**

### Experiment 3.12 — Windows DataLink Connect controlled capture
- **Date:** 2026-09-16
- **Evidence:** `Capture Results/DataLinkCapture_20260916_101342/` and
  `Capture Results/Apperson Education Products/DataLink/`
- **Hardware:** scanner detected on `COM7`, CP210x PNP ID
  `USB\\VID_10C4&PID_EA60\\1200`
- **Discovery exchange:** DataLink Connect sent ASCII `V`; scanner returned
  ` ADV 1200OK` with one leading space.
- **Initialization:** the application called `Scanner.InitializeScanner`, saw
  at least seven receive events, and reported `Initialized scanner`.
- **Mode transition:** after connection, the operator clicked **Data
  Collection**. DataLink Connect then sent a command that placed the scanner in
  Data Collection mode. This is distinct from discovery and initialization.
- **During scan:** numerous additional `Scanner.DataAvailable` events were
  logged after the mode transition, but their byte payloads were not included
  in the debug trace.
- **ScannerLog result:** logging preference was enabled and the logging thread
  started, but `ScannerLog-1.log` contains only the 50-byte session header.
- **Saved session:** temporary and named `.APXT` files are identical, 2,482
  bytes each, and appear compressed or encrypted.
- **Conclusion:** the Windows run proves an application-level handshake and an
  explicit Data Collection mode command are required, and supplies the first
  exact host command. It does not yet expose the initialization sequence, the
  mode command bytes, or a full form packet.

### Experiment 3.13 — USBPcap protocol recovery
- **Date:** 2026-09-16
- **Evidence:** `/Volumes/SANDISK/shark.pcapng` and `shark2.pcapng`
- **Transport:** CP210x bulk OUT endpoint `0x01`; bulk IN endpoint `0x81`
- **Commands recovered:** `V`, `R1`, `R5`, `T2`, `N8`, `A8`, `M8`, `M0`,
  `Q1`, `P5`, `X7`, `T4`, and mode-transition candidate `M6`
- **Form records:** three 371-byte, CRLF-terminated ASCII CSV records with 211
  fields each
- **Answers:** zero-based fields 10–59 contain 50 response values
- **Replay result:** `scripts/datalink_interface.py` parsed all three real
  records into three JSONL objects, each with 50 responses and no raw metadata
  exported by default.
- **Conclusion:** sufficient protocol data now exists for a direct macOS serial
  proof of concept. The next hardware test should run the live CLI, confirm the
  command replies, and scan one synthetic sheet.

### Experiment 4.1 — Local browser interface verification
- **Date:** 2026-09-16
- **Server:** `scripts/datalink_web.py`, bound to `127.0.0.1:8765`
- **Verified:** status API, demo-record insertion, 50-response table, CSV
  export, static HTML/CSS/JavaScript assets, and local JSONL session path
- **Variable forms:** parser and browser controls support explicit 30-, 33-,
  50-, and 75-question sessions; the 75-question fragmented-record test passes.
- **Automated tests:** all 12 Python tests pass
- **Visual QA:** desktop browser layout inspected with a populated 50-answer
  demo row; the table scrolls within its card without widening the page.
- **Pending:** connect the physical scanner on macOS and validate the captured
  initialization/Data Collection transition end to end.

### Experiment 4.2 — Exact CP210x configuration recovered
- **Date:** 2026-09-16
- **Evidence:** CP210x control transfers immediately before packet 79 (`V`) in
  `captures/shark.pcapng`
- **Configuration:** 38,400 baud, 8N1, flow control disabled, DTR off, RTS on
- **macOS replay:** scanner returned `ADV 1200OK\r\n` to the un-terminated ASCII
  command `V`.
- **Conclusion:** the prior 9,600-baud assumption was wrong. The browser and
  CLI must use the captured 38,400-baud configuration.

### Experiment 4.3 — Full macOS handshake succeeds
- **Date:** 2026-09-16
- **Initialization replies:** `V → ADV 1200OK`, `R1 → OK`, `R5 → OK`,
  `T2 → 5.5`, `N8/A8/M8/M0 → OK`, `Q1 → 4658`, `P5 → calibration values`,
  `X7 → 11/22/11 Standard`, and `T4 → S32155`
- **Data Collection transition:** `R1`, `R5`, `M6`, `N8`, `A8`, `M8`, and
  `M0` all returned `OK`.
- **Timing:** a 60 ms pause between transactions prevents the scanner from
  occasionally dropping the `X7` query.
- **Conclusion:** direct macOS initialization and Data Collection mode are now
  confirmed end to end. The next test is a real sheet through the browser UI.

### Experiment 4.2 — First live browser batch

- **Result:** the first sheet was captured. A later sheet contained an erased
  mark transmitted as `AC`; the original parser rejected that combined value
  and stopped the live session.
- **Correction:** combined A–E readings are now retained and sent to a modal
  review. The operator selects the intended choice, blank, or original combined
  reading. The read loop remains active.
- **Student IDs:** the 211-field records captured so far do not populate a
  student-ID field. The modal now requires manual ID entry after every student
  sheet, and the value is included in JSONL and CSV output.
- **Roster workflow:** a reusable browser-local roster maps roster numbers to
  names. The next student's name is shown before scanning, the number is
  prefilled during review, and absent students can be skipped without creating
  a record.
- **Automatic ID confirmed:** a live bubbled sheet transmitted student ID
  `900014` in zero-based field 0. Clean records with detected IDs are now saved
  automatically and matched to the browser roster; review is reserved for
  missing IDs and ambiguous marks.

### Test B — Same as A except 1=B
- **Date:**
- **Capture file:**
- **Diff vs Test A:**

### Test C — Same as A except 2=C
- **Date:**
- **Capture file:**
- **Diff vs Test A:**

### Test D — Sheet with known student ID
- **Date:**
- **Capture file:**
- **Notes:**
