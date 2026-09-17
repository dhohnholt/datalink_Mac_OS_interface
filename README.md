# DataLink Scanner

A native macOS application for the **Apperson DataLink 1200** optical mark
scanner — the bubble-sheet reader sitting in a lot of school supply closets.

Plug the scanner in, pick your class, and feed sheets. The app puts the scanner
into Data Collection mode and reads a complete record for every sheet — the
bubbled student ID and every response — matching each one to a student as it
goes. Sessions are saved locally and can be reviewed and exported to CSV
whenever you need them.

Because every answer is captured per question and not just a total score, the
app can score the session and write a full **item analysis** — which questions
the class missed, which distractors pulled them away, and how well each item
discriminated. That is the part worth having: it turns a stack of graded sheets
into a short list of concepts to reteach, backed by where the learning gaps
actually are.

## Why this exists

The DataLink 1200 is still a perfectly good scanner. What it lost was its
software: Apperson's DataLink Connect download no longer offers a supported
macOS build. So a working piece of classroom hardware became unusable on a Mac,
with no way to get results off it short of keeping a Windows machine around for
that one task.

The scanner itself never stopped working. It presents as an ordinary USB serial
device, and it still speaks its protocol perfectly well — there was simply
nothing left on macOS to speak it to.

So this project recovered the protocol from USBPcap captures of DataLink
Connect driving the scanner on Windows, and reimplemented the useful half of it
natively for macOS. No vendor software is used or redistributed; see
[docs/PROTOCOL.md](docs/PROTOCOL.md) for what is confirmed on the wire versus
still inferred, and [docs/TESTING.md](docs/TESTING.md) for the experiment log
that got there.

> **Privacy:** everything runs locally. No student ID, response, key, or score
> is ever sent to a network service. The server binds to loopback only, and the
> data stays in a folder on your Mac that you control.

## Install

```bash
brew install dhohnholt/datalink/datalink-scanner
```

Then link the app once so it appears in the Dock and Spotlight:

```bash
datalink-scanner install-app
```

If you previously drag-installed the app from a `.dmg`, that copy is moved to
the Trash and replaced with the link — otherwise you would keep launching the
old build, which Homebrew cannot update. A different application that happens
to share the name is left alone.

Updating later, including the app:

```bash
brew upgrade datalink-scanner
```

Or from inside the app: **DataLink Scanner → Check for Updates…**. It asks
GitHub what the newest release is and, when there is one, runs the Homebrew
upgrade for you, then closes and reopens itself on the new version. Copies of
the app left over from an earlier disk image or a local build are moved to the
Trash in the same pass, so only the current one is left to launch. Nothing is
deleted, and Homebrew's own storage is left to `brew cleanup`.

A copy installed from the `.dmg` cannot replace itself, so there the same menu
item offers the download page instead.

The app also checks once a day when it opens, and says nothing unless there is
a newer version — not when it is current, not when the network is down, and
never while sheets are going through the feeder. Turn it off under
**Settings → Updates**, which also shows the running version and when it last
checked. The only thing sent to GitHub is a request for the latest release
number.

The `.app` is a thin launcher around the `datalink-scanner` command, so an
upgrade takes effect immediately with nothing to rebuild or re-download. It is
built on your machine rather than downloaded, so macOS does not quarantine it
and there is no "unidentified developer" prompt.

<details>
<summary>Without Homebrew</summary>

Download the `.dmg` from
[Releases](https://github.com/dhohnholt/datalink_Mac_OS_interface/releases)
and drag the app to Applications. That build bundles its own Python and is
ad-hoc signed rather than Apple notarized, so the first launch needs a
Control-click → **Open**. Updates are manual.

Or install from source:

```bash
git clone https://github.com/dhohnholt/datalink_Mac_OS_interface.git
cd datalink_Mac_OS_interface
python3 -m venv .venv && .venv/bin/pip install -e .
.venv/bin/datalink-scanner
```
</details>

### Driver

The DataLink 1200 is a Silicon Labs CP210x USB serial device
(VID:PID `10c4:ea60`). Check that macOS sees it:

```bash
datalink-scanner ports
```

If nothing is listed, install the Silicon Labs CP210x VCP driver and reconnect
the scanner.

## Use

Open **DataLink Scanner** from the Dock, Spotlight or Applications — or run
`datalink-scanner`. It opens its own window with a normal macOS menu bar. No
browser window, no terminal window.

The window has four pages, on the tab bar and under the **View** menu:
**Scan** (⌘1), **Classes** (⌘2), **Sessions** (⌘3) and **Analysis** (⌘4).

1. Enter a **test name** — it becomes the exported CSV's filename.
2. Pick the **class** from the same row, and type the **questions per form**
   (1–100, default 50).
   Set the real form length: the count decides how many answer slots are read,
   so questions a student left blank at the end stay blank instead of being
   trimmed away.
3. Select **Connect and enter Data Collection**, and wait for *Ready to scan*.
4. Feed the **answer key first**, then the student sheets, one at a time.
5. **Export CSV** when you're done — it opens a normal Save panel. ⌘Q quits.

The test name, class and form length are remembered between launches.

### Sessions

Every sheet is written to a local SQLite database as it is scanned, so a
session is never only on screen. The **Sessions** page lists them newest first
and lets you open one to see every response, export it to CSV, rename it, or
delete it. Sessions that were opened but never received a sheet are discarded
on disconnect.

Sheets are also appended live to a timestamped `browser_session_*.jsonl` file
as a plain-text belt-and-braces log. Both live in
`~/Library/Application Support/DataLink Scanner/captures`.

### Paper batches, without the DataLink

If the scanner is not to hand, scan the sheets on any document scanner — a
ScanSnap, a copier — and read the PDF on the **Paper** page (⌘2). Choose the
file, say which page holds the marked answer key, and the sheets are read and
filed as an ordinary session. From there nothing knows the difference:
Sessions, Review, Answer key, Item analysis and Send to T-TESS all work on it,
and the scoring is the same code that scores a DataLink capture.

The reading itself is the pipeline from the
[omr_final](https://github.com/dhohnholt) project, vendored unchanged in
`src/datalink_scanner/vendor/omr/`, so a sheet read this way and a sheet read
by that project produce the same numbers. It handles the green Apperson
"AccuScan" A–E form it was calibrated against; other layouts are skipped and
counted rather than guessed at.

It needs OpenCV, NumPy and Pillow — about 51 MB to download, 154 MB on disk —
which are **not** part of the normal install, because most people only ever use
the device. **Install support** on that page fetches them in the background
into `~/Library/Application Support/DataLink Scanner/paper-support`, outside
the app, so updating the app does not download them again. Rendering also needs
poppler (`brew install poppler`). A copy installed from the `.dmg` cannot
install packages for itself; use the Homebrew install for paper scanning.

Pages are rendered at 400 dpi and cached so a batch can be re-read without
scanning again, which costs roughly **100 MB per 16-page batch**. The Paper
page reports the cache and empties it on request, and once it passes 500 MB the
app offers to empty it after a run. Only the page images go — sessions, scores
and item analyses are kept, and nothing needs the PDF again once a batch has
been read.

### Item analysis

The **Analysis** page scores a scanned test and shows where the class actually
struggled. Pick a test and you get the headline numbers — students, class
average, KR-20, how many sheets need review — then every question sorted into
**Priority** (below 60% correct), **Developing** (60–69.9%) and **Secure**
(70% and above), with a callout naming the items to reteach first. Filter to
any of those buckets, or to items the analyzer flagged, and open **Full
statistical diagnostics** when you want difficulty, point-biserial,
upper/lower discrimination and the whole answer distribution. Student scores
sit underneath, highest first, with each student's missed questions.

Those cut points are the same ones the omr_final results page uses, so an item
that reads as Priority there reads as Priority here.

Four sections sit under the test picker:

- **Item analysis** — the buckets, the filters and the diagnostics above
- **Student scores** — highest first, with each student's missed questions
- **Review** — every sheet the scanner could not read cleanly: a missing
  student ID, or a question where an erasure left two marks. Type the ID or
  pick the intended answer and **Apply corrections**; the saved session is
  updated and the analysis follows. The tab carries a count when anything is
  waiting.
- **Answer key** — the whole key as a grid. Click a letter to change it,
  **Save answer key**, and every sheet is rescored against the new key.
  Changed rows are highlighted until saved, and **Undo changes** puts them
  back.

The DataLink reads far more reliably than a document scanner, so Review should
usually be empty — but a smudged ID or a half-erased answer still happens, and
an answer key can simply be bubbled wrong.

**Download JSON** on that page — or **Export item analysis** (⇧⌘E) from a
session — writes the full report for upload.

### Sending to T-TESS

The **Send to T-TESS** section uploads a scored run straight to the Reteach
Center, so there is no file to export and re-upload by hand.

Connect once, under **Settings** (⌘5): on the T-TESS website go to
**Reteaching → Connect DataLink**, generate a connection token, and paste it
in. **Open T-TESS** on that card opens the Reteach Center in your normal
browser, which is where that token is generated and where the uploaded reports
are read. The token is held in this Mac's **Keychain** and nowhere else — not in the
app database, not in a preferences file, not in any log. It travels only as an
`Authorization: Bearer` header. No password, email, or other account
credential is ever requested; the server works out the teacher from the token.

Then pick **Course → Section → Unit → Test** and upload. The list of available
tests is refreshed when you connect, when the app opens, and before an upload
once it is more than fifteen minutes old.

**Uploading does not finalize anything.** It creates a run for review; you
check the warnings, student-ID matches, blanks and multiple marks on the
website and finalize there. The success panel links straight to that review.

Each upload is an audit record. Re-uploading the same scored run is refused by
the server as a duplicate, and a retry after a network failure reuses the same
run so it cannot become a second record. Correcting a student ID, a response
or the answer key re-scores the session and produces a genuinely new run.

The scoring is not reimplemented here. `src/datalink_scanner/vendor/` holds
verbatim copies of `analysis_core.py` and `result_schema.py` from the
**omr_final** project, which scores the same sheets when they are read on a
document scanner instead. Feeding those same functions means a sheet read
either way produces the same report against one schema, which is what the
upload endpoint expects.

Do not edit the vendored copies. Change them in omr_final and copy them across;
`tests/test_analysis.py` fails if they drift, and separately scores a session
both ways — directly, and by handing the exported CSV to omr_final — and
asserts the two JSON documents are identical.

From a terminal:

```bash
datalink-scanner analyze --list          # saved sessions and their ids
datalink-scanner analyze 12              # writes "<session name>.json"
```

Scoring needs exactly one answer key and at least one student sheet, and the
key itself must have no blank or double-marked questions. The export is greyed
out with the reason when a session cannot be scored.

### Storage

Everything is kept in that one folder. It is user data, not a cache, so macOS
does not purge it and Time Machine backs it up — but nothing else prunes it
either, so the app does not delete anything on its own.

Growth is slight: about 360 bytes per sheet. A year of six classes of thirty
students sitting a fifty-question test every week — around 6,700 sheets — comes
to roughly 2.5 MB.

Paper batches are the exception, because their rendered pages are images:
around 100 MB per 16-page batch. Those are a cache rather than data — see
**Paper batches** above — and the app offers to empty them once they pass
500 MB.

The **Sessions** page shows exactly what is stored and where, and
**Delete sessions older than…** removes old sessions, their scans and their log
files in one step, then compacts the database. Deleting a single session from
the list does the same for that one.

### Classes

Classes are picked on the Scan page and managed on the **Classes** page. There,
choose **New class**, name it, and paste one student
per line as `student ID, name`. Rosters are stored in the app's database on
that Mac and reused every time you scan. The Scan page names the next student
and offers **Skip absent** and **Start at first student**; progress is tracked
per class.

When the scanner reads a valid ID belonging to the selected class, the sheet is
saved immediately with no prompt. A dialog appears only when the ID is missing,
the ID is not in the selected class, or an answer needs review — for example
when an erasure leaves two marks and the scanner reports `AC`. You can then
pick the intended answer, mark it blank, or keep both marks.

### Command line

```bash
datalink-scanner                 # open the app window (same as `app`)
datalink-scanner serve           # serve the same workspace to a web browser
datalink-scanner ports           # list USB serial ports
datalink-scanner scan --acknowledge-writes   # capture to JSONL, no window
datalink-scanner replay raw.bin  # parse a saved byte stream offline
datalink-scanner install-app     # symlink the app into /Applications
```

`serve` is the fallback: same workspace, opened in your browser. Useful if the
window misbehaves, or over SSH.

`scan` and `serve` both send commands that change the scanner's mode, so
`scan` requires `--acknowledge-writes` to confirm a scanner is actually
attached.

Sessions go to `--capture-dir`, `$DATALINK_CAPTURE_DIR`, or the default above —
in that order. In a source checkout the default is `./captures` instead.

## How it works

```
DirectDataLinkScanner   serial I/O: 38400 8N1, DTR off, RTS on
        ↓
DataLinkStreamParser    CRLF framing; separates control replies from records
        ↓
DataLinkFormRecord      one 211-field ASCII CSV record per sheet
        ↓
ScannerController       session state, review queue, JSONL + CSV output
        ↓
Store                   SQLite: classes, settings, sessions and every scan
        ↓
local HTTP workspace    loopback only; the UI and its API
        ↓
Cocoa shell             NSWindow + menu bar + WKWebView  (or a browser tab)
```

The Cocoa shell in `app.py` owns the window, the menu bar, the Save panel and
the alert panels; it hosts the same server in-process on an OS-assigned port.
Menu items drive the very same controls the UI exposes, so there is one code
path per action rather than two.

The scanner emits one CRLF-terminated, 211-field CSV record per sheet. Field 0
is the bubbled student ID; fields 10 onward are the responses. Everything above
the transport layer operates on saved records, so it is unit tested without a
scanner attached.

## Project status

| Phase | | |
|---|---|---|
| 1 | Hardware discovery | ✅ CP210x USB serial, `10c4:ea60` |
| 2 | Communication method | ✅ 38400 8N1, DTR off / RTS on |
| 3 | Protocol discovery | ✅ command sequence + record framing |
| 4 | Direct interface | ✅ working against real hardware |
| 5 | Test scoring | 🔨 scores in the exported report, not yet on screen |
| 6 | Item analysis | ✅ JSON report, shared with omr_final |
| 7 | Native macOS app | ✅ Cocoa window and menu bar, no browser or terminal |

Item analysis is done, sharing its implementation with the omr_final project.
Per-student scoring inside the app's own UI is still to come; the JSON report
already carries every student's score and missed questions.

An early SwiftUI model layer is parked on the
[`swiftui-frontend`](https://github.com/dhohnholt/datalink_Mac_OS_interface/tree/swiftui-frontend)
branch. It predates the protocol discovery and is not part of the build.

## Repository layout

```
src/datalink_scanner/   the application: transport, parser, store, server,
                        Cocoa shell, CLI and web UI
  └── vendor/           verbatim scoring modules from omr_final — do not edit
tests/                  offline tests; no scanner needed
scripts/                phase 1–3 discovery tools (see below)
packaging/              app bundle builder, DMG build, Homebrew formula
docs/                   protocol notes, experiment log, installer analysis
windows_capture_kit/    portable collector for a Windows DataLink Connect PC
captures/               local scan data and library.sqlite3 — gitignored
```

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -e .
.venv/bin/python -m unittest discover -s tests -t tests -v
```

The discovery tools in `scripts/` are what produced `docs/PROTOCOL.md`:

- `01_baseline_unplugged.sh` / `02_connected.sh` — run unplugged, then plugged
  in; the second diffs against the first to identify the device.
- `serial_sniffer.py` — read-only capture. Never writes data bytes; it only
  asserts the DTR/RTS modem lines, without which the scanner sends nothing.
  Writes `raw.bin`, `hexdump.txt`, and `meta.txt` per labeled run.
- `controlled_capture.py` — one-sheet-at-a-time trial runner that ends a trial
  on line silence rather than assuming a packet length, so repeats of the same
  sheet can be compared byte for byte.
- `list_serial_ports.py` — port listing, superseded by `datalink-scanner ports`.

Releasing a new version: [docs/RELEASING.md](docs/RELEASING.md).

## License

[MIT](LICENSE). "Apperson," "DataLink," and "DataLink Connect" are trademarks
of their respective owners; this project is independent and unaffiliated, and
redistributes no vendor software.
