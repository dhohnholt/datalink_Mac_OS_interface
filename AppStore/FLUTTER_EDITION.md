# The Flutter edition: building and submitting

This is the Mac App Store build of the Flutter app in `app/` (version 2.0 and
later). The Python edition's tooling (`build_appstore.sh`, `PLAN.md`,
`HANDOFF.md`) is untouched and still builds that edition.

## What is different about the store build

Four entitlements, checked by the build script, and nothing else:

| Entitlement | Why |
|---|---|
| `app-sandbox` | Required |
| `device.serial` | The DataLink 1200 |
| `files.user-selected.read-write` | Open and Save panels |
| `network.client` | Optional upload to an address the teacher enters |

Gone, compared with the Python edition: `network.server` (there is no local
web server), `cs.allow-unsigned-executable-memory` (there is no interpreter;
Release is ahead-of-time compiled), and with them OpenCV, NumPy, Pillow,
poppler and every bundled shared library except the app's own four frameworks.

The headless self-tests that read environment variables (`DATALINK_*`) are
compiled out of this build; the script fails if their names appear in it.

## Prerequisites (once)

* An **Apple Distribution** (or Mac App Distribution) certificate and a
  **Mac Installer Distribution** certificate in the login keychain.
* A Mac App Store provisioning profile for `org.davidhohnholt.datalink-scanner`,
  saved as `AppStore/embedded.provisionprofile` (git-ignored; the same file the
  Python edition uses).

No certificate name, team id, profile or API key is stored in this repository.

## Run it

1. **Check, no certificate needed.** Builds, assembles, signs ad hoc, and
   verifies the bundle, the entitlement set, the privacy manifest, that every
   binary is universal, that nothing listens, and that the signed copy starts:

   ```bash
   DATALINK_APPSTORE_CHECK=1 ./AppStore/build_flutter_appstore.sh
   ```

2. **The upload build.** Signs with the store certificates and writes the
   installer package to `AppStore/flutter-dist/`:

   ```bash
   ./AppStore/build_flutter_appstore.sh
   ```

   Version and build number come from `app/pubspec.yaml` (`2.1.0+5`; builds 1–4 are spent, and 2.0.0 build 4 is the one Apple approved). To upload
   a second build of the same version, raise the build number:
   `DATALINK_APPSTORE_BUILD_NUMBER=6`.

3. **A copy you can open** (the upload build will not open on this Mac, because a
   store profile provisions no devices):

   ```bash
   DATALINK_APPSTORE_TESTABLE=1 ./AppStore/build_flutter_appstore.sh
   ```

4. Validate and upload with Transporter, using your own App Store Connect API
   key. **Do not install the package on this Mac**: it installs to
   `/Applications`, where the Homebrew app may be a symlink, and the installer
   follows it as root.

## What the check proved, and what only a real run will

Proved (by `DATALINK_APPSTORE_CHECK=1`, every time):
the signed entitlement set is exactly the four above and contains none of
`get-task-allow`, `allow-jit`, `allow-unsigned-executable-memory`,
`disable-library-validation`, `network.server`; the bundle id, version, build
number, category, deployment target (macOS 12), Xcode build metadata, privacy
manifest and icon are present and right; all five binaries are universal; there
are no helper executables; the source opens no listening socket; the diagnostics
are compiled out; the sandboxed copy starts and stays running.

**Not proved**, because it needs your certificates and Apple's servers:
the hardened-runtime signature with one team on every framework (the check build
is ad hoc, which cannot load frameworks under the hardened runtime, so it skips
it), the profile and application identifier, and App Store Connect's own
validation. The Python edition's first runs surfaced ITMS-90886, 90885, 91109
and 90869; the script is written to avoid each, but the first real run is where
anything left will show.

## Decisions and loose ends for the owner

* **Export compliance.** `ITSAppUsesNonExemptEncryption` is `false`, the same
  declaration made for the Python edition on 2026-09-25. It is a legal
  statement, not a build setting. The facts are not identical: this build has no
  OpenSSL, but HTTPS to the teacher's own site goes through the encryption
  library inside the Flutter/Dart runtime. Please confirm the declaration still
  holds before submitting.
* **Screenshots.** `AppStore/screenshots/mac-2560x1600/` holds nine of this app,
  at the 2560 x 1600 size App Store Connect takes for a Mac. They show only
  invented names, IDs and answers. Each is the app's content area drawn by
  Flutter's test renderer with the macOS system font, so there is no window frame
  or menu bar; if you prefer real window grabs, take them with Shift-Command-4
  then Space. To remake these: `DATALINK_SCREENSHOT_DIR=AppStore/screenshots/mac-2560x1600
  flutter test test/screenshots` in `app/` (the font paths in
  `app/test/screenshots/screenshots_test.dart` are this Mac's). The older
  `mac-1280x800/` set shows the Python edition's web interface and should not be
  used for 2.0.
* **Sample PDF** for App Review: `AppStore/review-sample/DataLink-Sample-Batch.pdf`,
  synthetic, with the result it should give in its README. Attach it in App
  Store Connect. Never a real scan.
* **Updating from the Python store edition.** Same bundle id, same container, the
  same `captures/library.sqlite3` and the same schema, so an update opens the
  existing library and the Keychain token without any import. The Dart reader was
  checked against a copy of a real library by comparing hashes of what it reads,
  never by an in-place update from an installed 1.x build. Page pictures from old paper batches (full
  size PNGs) are shown by the Review sheet viewer.
* **Privacy manifest.** Declares file timestamps and elapsed time; no data
  collected, no tracking. If App Store Connect emails about another required
  reason API, add it to `app/macos/Runner/PrivacyInfo.xcprivacy`.
* **Orientation template.** Cut from a clean key sheet, so it carries no student data
  (an earlier commit on this branch has the first version, which did; see the
  note on history below). Measured against the original in
  `docs/flutter-paper-measurements.md`.
* **Icon.** The existing blue icon is used; the interface is slate and teal.

## Student data in history

The first orientation template, which carried one student's bubbled ID, is gone
from this branch: checked on 2026-10-31 before the first push, every commit
holds only the clean template cut from a key sheet (a blank ID grid), and no
other version of `app/assets/orient_template.gray` exists in the repository.
Keep it that way: never commit a real scan, a capture, or a template cut from a
student's sheet. The Python edition's
`src/datalink_scanner/vendor/omr/reference_page.png` is the whole sheet, with a
student's handwritten name on it, and is already in `main`'s history.
