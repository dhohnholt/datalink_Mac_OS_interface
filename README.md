# DataLink Scanner

A macOS replacement for Apperson's "DataLink Connect," built for the
**DataLink 1200** optical mark scanner. It puts the scanner into Data
Collection mode, reads a complete record for every sheet — student ID and all
responses — and keeps the whole session on your Mac.

The protocol was recovered by reverse engineering; see
[docs/PROTOCOL.md](docs/PROTOCOL.md) for what is confirmed versus inferred.

> **Privacy:** everything runs locally. No student ID, response, key, or score
> is ever sent to a network service. The server binds to loopback only.

## Install

```bash
brew install dhohnholt/datalink/datalink-scanner
```

Then link the app once so it appears in the Dock and Spotlight:

```bash
datalink-scanner install-app
```

Updating later, including the app:

```bash
brew upgrade datalink-scanner
```

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

The window has three pages, on the tab bar and under the **View** menu:
**Scan** (⌘1), **Classes** (⌘2) and **Sessions** (⌘3).

1. Enter a **test name** — it becomes the exported CSV's filename.
2. Pick the **class** and type the **questions per form** (1–100, default 50).
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

### Classes

On the **Classes** page choose **New class**, name it, and paste one student
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
| 5 | Test scoring | ⬜ answer key + per-student scoring |
| 6 | Item analysis | ⬜ per-question stats across a class |
| 7 | Native macOS app | ✅ Cocoa window and menu bar, no browser or terminal |

Scoring and item analysis are not built yet — export the CSV and score
elsewhere for now.

An early SwiftUI model layer is parked on the
[`swiftui-frontend`](https://github.com/dhohnholt/datalink_Mac_OS_interface/tree/swiftui-frontend)
branch. It predates the protocol discovery and is not part of the build.

## Repository layout

```
src/datalink_scanner/   the application: transport, parser, store, server,
                        Cocoa shell, CLI and web UI
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
