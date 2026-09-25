# Handoff — App Store edition

For whoever picks this up next, with no memory of how it got here.

## The one thing not to break

The app ships **today** as a notarized Developer ID disk image and a `.pkg`.
Teachers use it. `packaging/build_macos.sh` produces both and they are
verified working as of v1.9.0.

Everything for the store lives in `AppStore/` and writes to `AppStore/dist/`.
No file outside `AppStore/` has been changed for this work. When the plan asks
for changes in `src/` — and it does, steps 2 and 5 — they must be conditional
on `edition.sandboxed()` so the shipping build behaves exactly as it does now.

Check before you finish: `packaging/build_macos.sh` still builds, still
notarizes, still staples.

## Where things stand

| | |
| --- | --- |
| Plan | `AppStore/PLAN.md` — read it first, especially Step 0 |
| Build | `AppStore/build_appstore.sh` — runs, stops at the first missing prerequisite |
| Entitlements | `AppStore/entitlements.plist` — written, not yet applied to a real build |
| Screenshots | `AppStore/screenshots/mac-1280x800/` — eight, done in an earlier session |
| Certificates | **none of the three needed exist yet** |
| Code changes | **none made** |

Running the build today gets you:

```
==> DataLink Scanner 1.9.0, App Store edition
STOPPED: no Apple Distribution certificate on this Mac
```

That is correct behaviour, not a bug. Step 1 of the plan clears it.

## What the owner has already

- Apple Developer account, Team ID **6BA6YTBG7Z**
- **Developer ID Application** certificate, installed and working
- App Store Connect API key **KFBHF6LUP5**, with the `.p8` in `~/Downloads`
  and the issuer ID known to the owner
- A notarytool keychain profile called **datalink-notary**, validated and in
  use by the shipping build
- Bundle ID **org.davidhohnholt.datalink-scanner**, registered

## What the owner must do, that you cannot

- Create the Apple Distribution and Mac Installer Distribution certificates
- Create and download the provisioning profile
- Create the app record in App Store Connect
- Any step that needs their Apple ID password or an app-specific password

Do not ask for, handle, or type their credentials. The notarytool profile and
the API key are already stored; reference them by name and path only.

## The two decisions that can end this

**Step 0 — `allow-unsigned-executable-memory`.** CPython needs it. App Review
often refuses it for Python apps. There is no way to ask in advance. If it is
refused, most of the work is wasted. The owner has been told this and chose to
proceed.

**Step 4 — the serial port under the sandbox.** Whether
`com.apple.security.device.serial` actually reaches `/dev/cu.usbserial-1200`
from inside a sandbox is **untested**. If it does not, the store edition
cannot talk to the scanner and becomes a paper-only app. Test it as soon as
there is a signed build — before doing steps 5 and 6.

Neither of these is pessimism. They are the two places where the remaining
work becomes worthless, and both are cheap to check early.

## Facts you will want, that cost an evening to learn

These came from a session with the scanner on the desk. `docs/PROTOCOL.md`
has the evidence.

- **Field 1 of every record is the scanner's own score**, marked against a key
  held in the device. It reads `000` when no key is loaded, which is
  indistinguishable from a sheet that scored nothing.
- **The scanner's mode is set by the Reset button on the device.** Nothing the
  host sends changes it. The button emits nothing on the wire.
- **While the scanner holds a sheet waiting for its other side it sends
  nothing at all** — no record, no status, no error. The app cannot tell that
  apart from an idle feeder.
- **macOS lets two processes open one `/dev/cu.*` and they take each other's
  bytes.** `interface.other_readers()` checks for this before connecting.
- The `Key`/`Verify`/`Rescore` checkboxes on a sheet **do not appear in the
  record**. All 211 fields are byte-identical with and without them.

## Conventions in this repo

- Tests: `.venv/bin/python -m unittest discover -s tests` — 448 at v1.9.0,
  all passing. Add tests with the change, not after.
- `src/datalink_scanner/vendor/` is a verbatim copy of the omr_final reader.
  **Do not edit it.** A drift test guards it. Reimplement in `paper.py` and
  pin the two together with a test, as `page_cache_dir()` does.
- Student data never leaves the Mac and never goes in the repo. Real scans
  under `Scans/` hold real student IDs. `captures/` is gitignored.
- The T-TESS token lives only in the Keychain. Never in the database, a
  preferences file, a log line, or an argument.
- Releases: `packaging/release.sh <version>`. Check whether the app is running
  first — bottling uninstalls and reinstalls the keg out from under it.
- Comments say why, not what.

## Verifying you have not broken the shipping build

```bash
.venv/bin/python -m unittest discover -s tests -q
packaging/build_macos.sh
hdiutil attach -nobrowse -quiet -mountpoint /tmp/dl dist/DataLink-Scanner-macOS-Apple-Silicon.dmg
spctl -a -vvv -t exec "/tmp/dl/DataLink Scanner.app"     # expect: accepted, Notarized Developer ID
xcrun stapler validate "/tmp/dl/DataLink Scanner.app"    # expect: the validate action worked!
hdiutil detach /tmp/dl
```
