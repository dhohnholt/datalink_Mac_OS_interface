# Flutter port — Phase 0 audit and plan

Branch `flutter-frontend`, written 2026-09-30 against `main` at 34cef98
(Python 1.9.11). **Nothing has been built.** This is the audit the brief asked
for, and it stops here for review.

## 0. Read this first: findings that change the brief

These are the places where what I found disagrees with the brief or with a
prior note. Each needs a decision before Phase 1.

1. **The UI kit path was never filled in.** The brief says `<PATH TO KIT>`
   literally. I found no kit on disk (searched `~/school_projects`,
   `~/Downloads`, `~/Desktop` by name). So its license is **unread**, and I
   cannot say whether it permits redistribution in an App Store binary. Phase 3
   is blocked on this; Phases 1–2 are not.
2. **Serial in the sandbox is not "UNVERIFIED" any more.** `AppStore/PLAN.md`
   step 4 was answered on 2026-09-25: *GO*. A signed sandboxed Python build
   opened `/dev/cu.usbserial-1200`, ran the full handshake, and showed
   bidirectional traffic (`V -> ADV 1200OK`, `T4 -> S32155`, `Q1 -> 4658`,
   `lsof` showing the pid on the fd). The brief still treats it as open, and
   only the `AppStore/entitlements.plist` comment is stale. **What is
   unproven is the Dart path**: the same `open()`/`termios` calls made through
   `dart:ffi` in a Flutter-built sandboxed binary. Phase 1 still has to prove
   that on hardware. The scanner is **not attached now** (`/dev/cu.usbserial*`
   does not exist), so hardware steps need you.
3. **The Python line count leaves out the hardest module.**
   `src/datalink_scanner/vendor/omr/` (about 42 KB: `analyze_exam.py`,
   `calibrate_page.py`, `extract_template_a.py`, `page_selection.py`, plus
   `reference_page.png`, 3.5 MB) is OpenCV/NumPy image processing, and
   `vendor/analysis_core.py` + `result_schema.py` are the scoring maths. There
   is no `cv2` for Dart. Section 4 covers how I'd port it.
4. **`network.client` is needed by more than updates.** The brief expects it
   "only if something actually needs it (updates)". Updates will not need it
   (see §3, updates.py), but **Send to T-TESS** does: it is an HTTPS POST
   from `ttess.py`. So the honest final list is either four entitlements
   (with upload) or three (upload dropped). That is a product decision, §7.
5. **Captures are real student data and are gitignored.** `.gitignore` says
   `captures/*` and `Capture Results/` must never be committed ("Raw scanner
   captures contain real student IDs and responses"). The brief says to
   commit goldens generated from the captures. Those two instructions
   conflict. My proposal is in §6. I need your yes before committing any
   golden derived from a capture.
6. **Version numbers do not line up with "1.9.4".** The source is at
   **1.9.11**, `AppStore/dist` holds a **1.9.10** `.pkg`, and `CHANGELOG.md`
   starts at 1.9.5. Nothing in the repo mentions 1.9.4. I can't tell which
   builds were actually uploaded to App Store Connect. §9 proposes a number
   that is safe regardless.
7. **There are no App Store users to migrate.** Nothing has been accepted in
   the store, so the only installed base is Developer ID / Homebrew
   (unsandboxed `~/Library/Application Support/DataLink Scanner/`).
   `AppStore/PLAN.md` step 6 already decided *no migration*. The brief asks
   for compatibility or a one-way migration; §6 proposes keeping the SQLite
   schema identical so a migration is a file copy. Whether that copy can be
   offered at all inside the sandbox is the open question.

## 1. Why the SwiftUI attempt stopped

From `macos-app/README.md` on `swiftui-frontend` (commit 851ad84):

- It was a model layer only: `Models.swift`, a transport protocol with a demo
  implementation, and an observable workspace model. No UI, no `@main`.
- **It predated the protocol discovery.** It assumed 9600 baud and no
  data-mode command. The real link is 38400 8N1, DTR off, RTS on, with a known
  command sequence. It was never updated.
- The stated reason for parking it: the Python app had become a real Cocoa app,
  so a parallel SwiftUI front end would have to re-derive the protocol in Swift
  and distributing a Swift binary needed either Xcode on every Mac or a
  notarized cask.

What not to repeat: (a) starting from a guessed protocol — this port starts
from `interface.py` and PROTOCOL.md, with goldens from Python; (b) building a
UI before the core is proven. The distribution objection does not apply: the
Flutter build is a normal signed `.app`.

## 2. Module map

Sizes are lines in `src/datalink_scanner/`. "Kind" is what the brief asked for.

| Python module | Lines | What it does | Kind | Dart equivalent |
|---|---:|---|---|---|
| `interface.py` | 439 | Constants, handshake command lists, `DataLinkFormRecord.from_line` (211-field CSV parse/validate), `DataLinkStreamParser` (CRLF framing, stale-fragment timeout), `describe_message`, `discover_port`, `other_readers` (lsof), `DirectDataLinkScanner` (open/transact/version-retry/initialize/resync) | **protocol/serial** | `datalink_core`: `record.dart`, `stream_parser.dart`, `messages.dart`, `scanner_session.dart` over an abstract `SerialTransport`. The real transport (`PosixSerial`, FFI to libc) lives in a small separate package |
| `server.py` — `ScannerController` | ~520 | Connection state machine, reader thread, sheet numbering (sheet 1 = key), review queue, JSONL log, session start/end, reset, CSV export | **domain** | `ScannerController` in `datalink_core` (pure Dart, `Stream`-based, takes a `SerialTransport` and a `Store`) |
| `server.py` — `DataLinkRequestHandler` | ~700 | The HTTP layer: 15 GET + 26 POST routes | **UI handlers** | Deleted. Replaced by view-models calling the controller/store directly. Contract in §5 |
| `server.py` — `scored_session`, `records_to_csv`, `safe_export_filename`, `_paper_run` | ~150 | Score caching by fingerprint, CSV shape, filename sanitizing | **domain** | `datalink_core` |
| `analysis.py` | 367 | Scan → analysis structures, fingerprint, faint-mark and disagreement review logic, `AnalysisError` | **domain** | `datalink_core/analysis.dart` |
| `vendor/analysis_core.py` | 129 | `validate_answer_key`, `score_student`, `item_analysis` (point-biserial, discrimination), `class_statistics` (KR-20) | **domain (maths)** | `datalink_core/scoring.dart`. Needs Python-compatible rounding and `statistics.stdev`/`variance` |
| `vendor/result_schema.py` | 115 | The versioned JSON contract sent to T-TESS | **domain** | `datalink_core/result_schema.dart` |
| `store.py` | 666 | SQLite: settings, classes, students, sessions, scans, review_dismissals; migrations; storage report; pruning | **persistence** | `datalink_core/store.dart` on `package:sqlite3`, **same schema** |
| `paper.py` | 846 | PDF batch driver: finds poppler, spawns the OMR subprocess, progress parsing, page cache, page image resize, `Job`, session filing, pip install (dead in store edition) | **domain + platform glue** | `paper/` : `PaperJob`, cache, `session_from_report` in core; render + image work behind interfaces (§4). `install_packages`, `pip_available`, `support_dir`, `environment`, `frozen` are dropped |
| `vendor/omr/*` | ~42 KB | Orientation (4 rotations × `matchTemplate`), per-page calibration, ink-ratio sampling, answer/ID decision rules, page-spec parser | **domain (image)** | `datalink_core/omr/` (pure Dart) with a pluggable matcher; `page_selection.dart` is trivial |
| `ttess.py` | 330 | HTTPS client: destinations cache, upload with retry, error mapping, token in Keychain | **network + domain** | `datalink_core/ttess.dart` over an injected `HttpClient`/`SecretStore` |
| `keychain.py` | 486 | `Sec*` legacy-keychain calls via ctypes; a copied-interpreter / compiled helper to keep a stable ACL path (Developer ID only) | **platform glue** | `SecretStore` interface + one implementation (§5). The whole helper mechanism (`ensure_helper`, `_pin_to_stable_framework`, `_resign`, `_ask_helper`) is **not ported**: it is inert in the sandbox already |
| `updates.py` | 696 | GitHub release check, `brew upgrade`, find/trash duplicate bundles, LaunchServices and Dock surgery, relaunch | **platform glue** | **Not ported.** See §3 |
| `app.py` | 1091 | Cocoa shell: window, menu bar, WKWebView, JS bridge for open/save panels, update sheets, About | **platform glue / UI** | Flutter `PlatformMenuBar`, `file_selector`, about dialog. Menu items listed in §8 checklist |
| `cli.py` | 415 | `app`, `serve`, `ports`, `scan`, `replay`, `analyze`, `install-app` | **glue** | Not ported as a CLI (the Python app stays as reference). `replay` and `analyze` become test tools in `datalink_core/tool/` |
| `paths.py` | 63 | Application Support / captures paths, source-checkout detection | **glue** | `path_provider` (`getApplicationSupportDirectory`), which resolves to the container in the sandbox |
| `edition.py` | 35 | `sandboxed()` by looking for `/Library/Containers/` | **glue** | **Deleted.** There is one edition; no runtime branch |
| `webui/{index.html,app.js,styles.css}` | 802 / 2436 / 576 | The whole UI | **UI** | Flutter screens (Phase 3) |

Tests to port rather than invent (counts of `def test_`): `test_interface` 41,
`test_analysis` 48, `test_grading_regressions` 8, `test_store` 53,
`test_ttess` 30, the portable part of `test_paper` (of 47; the subprocess,
pip and poppler-path tests are not portable), and `test_serial_sniffer` 6
(formatting of a *script*, not the app — not ported). **Not ported** because
the code under test disappears: `test_server` 63, `test_app` 85,
`test_updates` 63, `test_keychain` 28 (helper mechanism), `test_edition` 15.
Their behaviours that survive (e.g. "store edition refuses updates") become
"the feature does not exist", checked by grep (§7).

## 3. The hard parts

### Serial in the sandbox

What Python does, and so what Dart must reproduce (`DirectDataLinkScanner`):

- open the device at **38400 8N1**, timeout 50 ms, write timeout 1 s
- set **DTR off**, **RTS off**, sleep 150 ms, flush input, then **DTR off, RTS
  on**, sleep 250 ms
- commands are **bare ASCII with no terminator**; replies end `\r\n`
- `V` is retried up to 4 times with 0.25 s × n back-off (the first replies after
  open are unreliable, per PROTOCOL.md)
- 60 ms between init commands ("back-to-back diagnostic queries can make the
  scanner drop X7")

Evidence from `PLAN.md` says the entitlement reaches the CP210x node. Dart
makes the same syscalls, so I expect it to work, but **I will not claim it
until it runs on hardware in a signed sandboxed Flutter build.**

Two behaviours will not port as-is:

- `other_readers()` shells out to `/usr/sbin/lsof`. Inside the sandbox `lsof`
  can only see the app's own descriptors, so it would silently report nothing
  and the check would be dead. Proposal: open with `TIOCEXCL` so *our*
  process excludes others, and report `EBUSY` ("another program has the
  scanner open") when someone else already holds it exclusively. That catches
  a cooperating holder but **not** a non-exclusive one, which is the case the
  check was written for. This is a real, small regression and I'll test it on
  hardware rather than assume it.
- `discover_port()` globs `/dev/cu.usbserial*`. Directory listing of `/dev` from
  the sandbox worked in the Python build, so a Dart `Directory('/dev').list()`
  should too. Phase 1 confirms.

### PDF handling (`paper.py`)

Today: `pdfinfo` for the page count, `pdftoppm -r 400` to render, then OpenCV
on the PNGs; Pillow to shrink pages to 1100 px JPEG for the Review dialog.
The store build *bundles* poppler as helper binaries. Nothing runs at
runtime that isn't in the bundle, so this is currently allowed. The port
removes the subprocesses, the Python interpreter and OpenCV/NumPy together.

Two facts to keep in mind:

- The calibration constants (`REF_ROW0_Y = 1150`, spacing 109.3, bubble
  centres, the orientation template crop `[380:1000, 60:900]` of
  `reference_page.png`) were **measured on poppler output at 400 dpi**. A
  different renderer resamples the embedded scan differently and will not
  give the same pixels. The thresholds (`DARK_PIXEL_THRESH` 170, blank 0.05,
  multi 0.85) are robust to small changes, but **how robust is unmeasured**.
- There are real batches on this machine to measure it with
  (`../Scans/Econ/*.pdf`, four PDFs, plus `omr_final/output/` for earlier
  results). They contain real students' names and IDs, so they stay local and
  are never committed.

### Keychain (`keychain.py`)

- What is stored: the T-TESS bearer token (`dlk_live_…`), service
  `org.tmechs.datalink`, account `scantron-upload-token`, in the **legacy
  file-based login keychain** via `SecKeychain*Generic*` calls.
- The compiled-helper dance exists only to give an ad-hoc-signed app a
  stable path for the keychain ACL. A properly signed store app is identified
  by its signature, which is the problem the helper worked around. In the
  sandbox the helper is already disabled (`_through_helper` returns
  "not answered").
- A sandboxed app cannot read another app's keychain item, so **an existing
  Developer ID user's token will not carry over**; they paste it again.
- Dart side: §5 picks a package and says what I haven't verified.

### Auto-update (`updates.py`)

Today (non-store builds): once a day (opt-out) asks GitHub releases for the
latest tag; if newer and Homebrew-managed, runs `brew upgrade` with a progress
sheet, then relaunches; also finds duplicate `.app` copies via Spotlight,
moves extras to the Trash, edits LaunchServices registrations, and repoints
Dock tiles. Every entry point already raises `UpdateError` when sandboxed.

What should happen in the Flutter App Store build: **nothing.** The store
delivers updates; Apple forbids self-update; all of it depends on `brew`,
`mdfind`, Dock prefs and moving other apps. **Delete it rather than port it.**
That removes the only reason the brief anticipated for `network.client`. The
Settings "Updates" card and the "Check for Updates" menu item go with it.

### Anything that shells out or depends on CPython at runtime

Everything below is removed in the port:

| Where | What |
|---|---|
| `paper.py` | `pdfinfo`, `pdftoppm`, re-entry via `--run-omr`, `pip install`, `-c` probe |
| `interface.py` | `/usr/sbin/lsof` |
| `keychain.py` | `codesign`, `otool`, `install_name_tool`, copying an interpreter, helper subprocess |
| `updates.py` | `brew`, `mdfind`, `defaults`/Dock plist, `osascript`/Trash, relaunch via `open` |
| `app.py` | `objc`/PyObjC, `webbrowser`, JS bridge |
| `server.py` | `ThreadingHTTPServer` — the listening socket that caused the rejection |

## 4. Porting the paper (OMR) path — the largest real risk

The OMR code is short, but it leans on three OpenCV behaviours:

1. `cv2.imread(..., IMREAD_GRAYSCALE)` — PNG decode + luma conversion.
2. `cv2.matchTemplate(..., TM_CCOEFF_NORMED)` — used **four times per page**
   (one per rotation) with a 620×840 template over a ~2384×4384 image, then
   once more in `calibrate_page`. OpenCV does this with an FFT. A naive
   sliding window in Dart is ~10¹² operations per page: unusable.
3. `cv2.rotate` — trivial.

Plan: implement normalized cross-correlation with a **coarse-to-fine search**
(downsample by 8 for a full search, then exact NCC in a small window around
the best candidates at full resolution). Only the *location* of the best
match and its score feed anything downstream, and the exact NCC at the
chosen location is cheap. If that proves too slow or misses peaks, the
fallback is FFT correlation through Accelerate (vDSP) via FFI — a system
framework, no entitlement, no native code of ours.

I will measure speed and agreement on the real batches before choosing. To
**decouple the two risks**, OMR parity tests run on poppler-rendered PNGs
(Python's `paper-cache` already holds page PNGs for 13 paper sessions), so
OMR maths is judged against Python independently of the PDF renderer. The
renderer is then judged separately, end to end: same PDF, Python answers vs
Dart answers.

Python-compat details that will bite if ignored: `round()` is half-to-even on
the exact binary value; `statistics.stdev`/`variance` formulas; `json.dumps`
float formatting and key ordering (the score fingerprint is a SHA-256 over
`json.dumps(..., sort_keys=True)`, and `run_id` reuse depends on it); `int()`
truncation in `sample_ink_ratio`'s ROI bounds.

## 5. HTTP endpoints → direct Dart calls

Every route in `server.py`. Unless noted, a successful POST returns the
controller **snapshot** (below) and any exception returns HTTP 400
`{"error": "<message>"}`. The contract is what the view-models must provide;
none of it survives as HTTP.

**Snapshot** (`ScannerController.snapshot()` + `ports` on GET `/api/status` and
`/api/session/end`): `state` (`disconnected|connecting|connected|error`),
`port`, `error`, `record_count`, `records[]`, `pending_review` (first pending or
null), `activity[]` (≤30, newest first, each `{time, message, kind}`),
`output_path`, `capture_root`, `session_id`, `session_name`, `scanning`,
`question_count`, `min_question_count`(1), `max_question_count`(100), `ports[]`.
→ Dart: `Stream<ControllerState>` + immutable `ControllerState`.

### GET

| Route | Returns | Dart replacement |
|---|---|---|
| `/api/status` | snapshot + `ports` | `controller.state` stream; `SerialTransport.listPorts()` |
| `/api/classes` | `{classes:[{name, students:[{id,name}]}]}` | `store.listClasses()` |
| `/api/settings` | `{test_name, selected_class, question_count, student_matching (default "id"), auto_update_check, sandboxed, last_update_check, app_version}` | `settings` repo. **Drop** `auto_update_check`, `sandboxed`, `last_update_check` |
| `/api/sessions` | `{sessions:[{id,name,class_name,question_count,started_at,ended_at,source,scan_count}]}` newest first | `store.listSessions()` |
| `/api/sessions/<id>` | session row (no `page_cache`) + `scans[]`, `has_pages`, `analysis_available`, `analysis_error`; 404 `{error}` | `store.session` + `scans` + try `buildSessionAnalysis` |
| `/api/sessions/<id>/analysis` | analysis report + `has_pages`, `class_name`, `dismissed_count`; 400 `{error}` on `AnalysisError` | `scoredSession()` |
| `/api/sessions/<id>/analysis.json` | same report, pretty-printed, as a download named by `analysis_filename` | save panel + write |
| `/api/sessions/<id>/export.csv` | CSV (`Scan,Role,Class,Student ID,Student Name,Received At,Answered,Q1…Qn`) | `recordsToCsv` + save panel |
| `/api/sessions/<id>/page/<n>` | one cached page, JPEG ≤1100 px (or PNG) | `PageCache.image(session, n)` |
| `/api/export.csv?class=&name=` | live on-screen session as CSV | `controller.exportCsv` |
| `/api/connection` | `{connected, api_url, site_url, sandboxed, destinations[], error}` | `TtessRepository` |
| `/api/destinations` | `{destinations[], error}` (forced refresh) | `ttess.refreshDestinations()` |
| `/api/storage` | store report (`sessions, scans, classes, oldest, database_bytes, log_bytes, log_files, total_bytes, directory`) + `paper` cache report | `store.storageReport()` + `PageCache.report()` |
| `/api/paper` | `{support, storage, job, max_questions(50)}` | `PaperJob` state. **Drop** `support` (nothing to install) |
| `/api/paper/job` | `{job, storage}` — polled for progress | `PaperJob` as a `ValueListenable` |
| `/api/paper/page?path=&page=` | a cached page before any session exists (key-review) | `PageCache.imageForPdf` |
| static files | `index.html`, `app.js`, `styles.css` | the Flutter app itself |

### POST

| Route | Body | Does | Notes |
|---|---|---|---|
| `/api/connect` | `{acknowledge_writes:true, port?, question_count}` | open, handshake, enter Data Collection, start reader | The `acknowledge_writes` gate is a CLI-era safety; the UI always sends true. Keep a single confirmation in the UI, not a parameter |
| `/api/session/start` | `{question_count?}` | re-send handshake, create session | `reset_scanner=True` always from the UI |
| `/api/session/end` | — | end session; returns snapshot + `summary{session_id, sheets, discarded, pending_review, message}` | |
| `/api/scanner/reset` | — | re-send handshake | |
| `/api/disconnect`, `/api/clear` | — | | `clear` refused while a session runs |
| `/api/quit` | — | disconnect + stop server | **Drop**: quitting is the app's own |
| `/api/resolve-review` | `{id, resolutions{q:letter}, student_id, student_name}` | finish a pending sheet | ID digits-only; students must have an ID |
| `/api/classes/save` | `{name, students[{id,name}], original_name?}` → `{classes}` | create/rename/replace | validation messages are user-facing text, keep verbatim |
| `/api/classes/delete` | `{name}` → `{classes}` | also clears `selected_class` | |
| `/api/classes/import` | `{classes[]}` → `{imported[], classes}` | adopt a browser's localStorage classes | **Drop**: migration from the pre-SQLite web UI |
| `/api/settings` | any of `test_name, selected_class, question_count, student_matching, auto_update_check, ttess_api_url, ttess_site_url` → `{ok:true}` | writes settings; renames the open session; URLs must be https | **Drop** `auto_update_check` |
| `/api/paper/install` | — | pip install | **Drop** |
| `/api/paper/pages` | `{path}` → `{pages}` | page count | |
| `/api/paper/run` | `{path, key_page, question_count, pages, skip_pages, name, class_name, key_overrides{q:letter}}` → `{job}` | start a batch | `409` if busy; job `failed` carries `key_review{key_page, unresolved{q:seen}, pages}` |
| `/api/paper/purge` | → `{freed_bytes, removed, …report}` | empty page cache | |
| `/api/paper/dismiss` | → `{job}` | reset a finished job | |
| `/api/sessions/review/dismiss` | `{session_id, items[]}` → `{dismissed}` | | items are `page:field:question:reason` keys |
| `/api/sessions/review/restore` | `{session_id}` → `{restored}` | | |
| `/api/sessions/correct` | `{session_id, corrections[{number, student_id?, student_name?, responses?[]}], dismiss[]}` → `{applied, dismissed, analysis|null, analysis_error?}` | validated batch | `BLANK`/`MULTIPLE` map to `""`/`*`; length must equal `question_count` |
| `/api/connection/connect` | `{token}` → `{connected, destinations}` | save token, fetch tests | `400 {error, code}`; bad token is forgotten |
| `/api/connection/disconnect` | → `{connected:false, destinations:[]}` | forget token | |
| `/api/sessions/upload` | `{session_id, exam_id, replace_run_id?}` → `{run_id, status, replaced_run_id, review_url, exam_title, local_run_id}` | score, upload | `400 {error, code}`; retryable errors retried twice with 1 s, 2 s back-off, same `run_id` |
| `/api/sessions/delete` | `{id}` → `{sessions}` | also deletes the JSONL log | |
| `/api/sessions/rename` | `{id, name}` → `{sessions}` | | |
| `/api/storage/prune` | `{days, preview?}` → `{count, days}` or `{sessions, logs, storage, sessions_list}` | | |

## 6. Persistence and fixtures

- **Schema stays byte-compatible**: same tables, same columns, same `PRAGMA
  journal_mode = WAL`, same `ALTER TABLE` migrations. Then "migrate" means
  "copy `library.sqlite3` into the new container", and the Dart store can open
  either. `sessions.log_path` and `sessions.page_cache` hold **absolute
  paths** that will be wrong after a move; migration must null or rewrite
  them (a missing page cache already degrades gracefully: `has_pages` is
  false).
- I inspected a **copy** of the real data directory (schema and counts only,
  no contents): 18 sessions (13 paper, 5 DataLink), 250 scans, 4 classes.
  That's the dataset Phase 2 verifies against, on a copy.
- **Golden files.** Python side: a script under `tools/` (not `src/`, so the
  Python app stays unmodified) runs the real modules and writes JSON. Dart
  side: `dart test` loads the same files. Inputs, in priority order:
  1. the synthetic builders in `tests/support.py` (no student data; safe to
     commit);
  2. records from `captures/shark*.pcapng` and the `browser_session_*.jsonl`
     logs — **real IDs**. Proposal: commit only goldens whose field 0
     (student ID) has been replaced by a deterministic synthetic value, with
     the unsanitised run kept local and gitignored; or commit nothing derived
     from captures. **Your call.**
  3. OMR pages from `paper-cache` and `../Scans`: local only, never committed;
     the committed OMR fixture is a synthetic sheet rendered from
     `reference_page.png` with known marks.
- Extracting the bytes from `.pcapng` needs a USBPcap reader (CP210x bulk
  endpoints `0x01` out, `0x81` in). Nothing in the repo does that; the
  protocol notes were derived by hand. I'd write a small one under `tools/`.

## 7. Package choices

| Need | Choice | Why | Maintained? | Sandbox-safe? |
|---|---|---|---|---|
| Serial | **Own thin `dart:ffi` layer over libc** (`open`, `tcgetattr/tcsetattr`, `cfsetspeed`, `ioctl` TIOCMBIS/TIOCMBIC/TIOCEXCL, `read`, `write`, `poll`, `tcflush`, `close`), inside a small package | Rejected: `libserialport` / `flutter_libserialport` (0.6.0, MIT wrapper) bundles the **LGPL-3** libserialport C library; LGPL relinking is a poor fit for a signed App Store binary and I don't want that licence question on this app. Others (`flserial`, `universal_serial`, `libserialport_plus`) are low-adoption wrappers over the same C library or unproven on macOS. The protocol needs ~8 syscalls; owning them also lets me copy `pyserial`'s exact `termios` sequence | Nothing to maintain beyond our own ~300 lines | Yes: libc only, no native build. `device.serial` governs `open()` of the node |
| PDF render | **`pdfrx_engine`** (PDFium via FFI, MIT; 0.6.1) behind a `PageRenderer` interface | The `pdfrx` family is actively published and widely used. Alternative if its bundled PDFium binary is a problem: a ~60-line Swift plugin over PDFKit/CoreGraphics via platform channel (system framework, zero dependencies). **I'd decide by measuring fidelity against poppler, not by preference** | Yes (frequent releases) | Reads a user-selected file; no network at runtime. *Unverified:* how its macOS build fetches the PDFium binary (build-time download must not be needed on a clean CI machine) |
| Image I/O and gray | **`image`** (pure Dart) for PNG/JPEG encode-decode and resize; my own code for the gray conversion, so luma weights and rounding match OpenCV exactly | No native dependency; isolates for speed | Yes | Yes |
| Persistence | **`sqlite3`** 3.7.0 (Simon Binder; MIT; FFI, bundles SQLite via a build hook) | Keeps the existing schema and WAL format, so the Python database opens unchanged. Not `drift`: an ORM adds nothing to a port whose schema is fixed | Yes (150/160 pub points, 2.5 M downloads) | Yes. *Unverified:* the build hook compiles SQLite with Xcode's toolchain; will confirm on the first build |
| Keychain | **`flutter_secure_storage`** 11.2.0 (BSD-3) configured for the **legacy keychain** (`useDataProtectionKeyChain: false`), behind a `SecretStore` interface | Its default on macOS is the *data-protection* keychain, which needs a `keychain-access-groups` entitlement — an extra entitlement I'd rather not ask for. Whether the legacy mode works in a sandboxed, store-signed build is **unverified**; Phase 2 spikes it. Fallback: ~150 lines of FFI straight to `SecItem*`, no package | Yes (4.4 M downloads) | To be proven |
| File panels | **`file_selector`** (flutter.dev) | NSOpenPanel / NSSavePanel; covers `files.user-selected.read-write` | Yes | Yes |
| Paths | **`path_provider`** (flutter.dev) | `getApplicationSupportDirectory()` resolves inside the container | Yes | Yes |
| HTTPS (T-TESS) | `dart:io` `HttpClient` (no package) | Exactly the existing `urllib` behaviour; needs `network.client` | SDK | Needs `network.client` |
| Hashing | `package:crypto` (dart.dev) | SHA-256 for the scan fingerprint and page-cache key | Yes | Yes |

**If the serial approach fails** (I don't expect it to): the fallback is a
small Swift plugin over IOKit/termios behind a platform channel, same
`SerialTransport` interface, so nothing above it changes.

### Entitlements

Target `AppStore/entitlements-flutter.plist` (Phase 4):

- `com.apple.security.app-sandbox`
- `com.apple.security.device.serial`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.network.client` **only if T-TESS upload ships**

Not present by construction: `network.server` (no listening socket exists),
`cs.allow-unsigned-executable-memory` (Flutter release is AOT; no embedded
interpreter), `cs.disable-library-validation` (already gone).

Pitfall: Flutter's macOS template puts `network.server` and
`cs.allow-jit` in **`DebugProfile.entitlements`** (for the VM service). The
store build must use `Release.entitlements` only, and the Phase 4 check
(`codesign -d --entitlements :-`) plus a `grep -r` for `bind(`/`listen(`/
`ServerSocket`/`HttpServer` runs on the built product.

The provisioning profile also injects `com.apple.application-identifier` and
`com.apple.developer.team-identifier`; those come from the profile and are not
something I write.

## 8. UI checklist (to be ticked in Phase 3)

Built from `webui/index.html`. I have read its structure and control list; I
have **not** yet read `app.js` (2,436 lines) line by line, which Phase 3 will.
Tabs: Scan, Paper, Sessions, Analysis, Classes, Settings.

- [ ] **Scan**: connect/start session, End session, Reset scanner, Disconnect;
  test name, class picker, student matching, questions per form (1–100) with
  help popovers; metrics row; workflow card (key needed → next student; Skip
  absent; Start at first student); Live scans table; Clear view; Activity log
  with protocol-details toggle; review dialog for erased answers and missing
  student IDs
- [ ] **Paper**: Choose PDF, page count, key page, question count (1–50),
  pages/skip-pages, Read the sheets, progress; answer-key-needs-a-hand flow
  (view key sheet, per-question picker, retry, start over); Open item
  analysis; Read another batch; page cache size + Empty cache
- [ ] **Sessions**: list, refresh, detail view, rename, delete, export CSV,
  storage summary, "Delete sessions older than N", Show in Finder
- [ ] **Analysis**: test picker; metrics; panes Item analysis (filters All/
  Priority/Developing/Secure/Flagged, diagnostics toggle), Student scores,
  Review (per-row check, Mark all checked, Apply corrections, Show them
  again, sheet image dialog), Answer key (edit, Undo, Save), Send to T-TESS
  (Course/Section/Unit/Test pickers, Refresh tests, Upload, replace run)
- [ ] **Classes**: list, New/Edit/Delete class, roster editor with validation
- [ ] **Settings**: T-TESS connection (token, Connect/Disconnect, address and
  site fields, Save address, Copy specification, Refresh tests), "What is
  sent"; ~~Updates card~~ (removed on purpose)
- [ ] **Menu bar / window** (`app.py`): Connect, End session, Reset scanner,
  Disconnect, Clear view, Skip student, Start at first student, protocol
  toggle, tab navigation, Read paper batch, New/Edit class, Reload, Export
  CSV, Export analysis, Open session folder, Help, Protocol notes, Report an
  issue, About; Cmd-Q disconnects cleanly; ~~Check for Updates~~, ~~Open in
  Browser~~ (removed on purpose: there is no server)
- [ ] Accessibility: VoiceOver labels on every control and table cell,
  full keyboard path (the tab strip, dialogs, tables), contrast checked in
  light and dark

## 9. Version number

The source is **1.9.11**; the last store package built locally is **1.9.10**; the
brief says the rejected submission was 1.9.4. Apple requires each upload's
`CFBundleVersion` to exceed every earlier upload of that app, and I can't see
App Store Connect. The Flutter port is also a rewrite.

**Proposal: marketing version `2.0.0`, build `2.0.0`**, which is above every
number in the repo and above 1.9.4 under any reading. If you'd rather stay on
the 1.9 line, `1.10.0` also beats everything seen here, but **I would not go
lower than that**. Please confirm the highest build you've actually uploaded.

## 10. Phases, revised

Unchanged in intent; adjusted for the findings above.

1. **Phase 1 — core.** `packages/datalink_core` (pure Dart: record parser,
   stream parser, messages, handshake driver over `SerialTransport`,
   controller, scoring, analysis, result schema, store), `packages/
   datalink_serial_posix` (FFI transport, Flutter-free but macOS-only). Goldens
   from Python via `tools/`. Hardware proof needs you: I'll give exact steps
   and what to report.
2. **Phase 2 — persistence, settings, secrets.** Store parity against a copy of
   your real database; keychain spike (legacy mode under a sandboxed signed
   build).
3. **Phase 2.5 — paper (new).** PDF render + OMR in Dart, measured against
   Python on your real batches. I'm adding this as its own step because it is
   the largest risk and does not fit under "domain" comfortably.
4. **Phase 3 — UI.** Blocked on the kit.
5. **Phase 4 — packaging.** `AppStore/build_flutter_appstore.sh`,
   `entitlements-flutter.plist`, `REVIEW_NOTES.md` rewrite. I will not sign,
   notarize or upload; no identity, team ID or profile goes into any committed
   file.

## 11. Decisions I need from you

1. **The UI kit path** (and I'll report its license).
2. **Ship T-TESS upload in the store build?** Yes → keep `network.client`
   (and explain it honestly in review notes). No → three entitlements.
3. **Goldens from captures:** sanitised (field 0 replaced) and committed, or
   nothing derived from captures committed?
4. **Version:** 2.0.0, or tell me the highest build already uploaded.
5. **Serial package:** OK to own the FFI layer rather than depend on an LGPL
   library?
6. **Existing-user migration:** keep "no migration" (PLAN step 6), or add an
   import-from-file action (an open panel on the old `library.sqlite3`)?
7. **Hardware:** when you're at the scanner, I'll have the Phase 1 steps ready.

## 12. What I did not do

- No code, no Flutter project, no `flutter create`, no commits other than this
  document.
- I did not read `app.js`, the body of `updates.py` past its structure, the
  body of `cli.py`/`app.py` past their structure, or the test files beyond a
  sample. The map above is from structure plus the modules I did read in full
  (`interface`, `server`, `paper`, `store`, `keychain`, `ttess`, `analysis`,
  `paths`, `edition`, all of `vendor/`). Phase 3 and Phase 2 will read the rest
  before relying on it.
- I did not touch `main`, `origin`, tags, `gh-pages`, `dist/`, the Homebrew
  formula, or `backup/python-webview-v1.9.11`. No push.
- The real-data check used a copy in a scratch directory (since deleted).
