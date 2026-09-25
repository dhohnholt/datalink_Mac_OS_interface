# DataLink Scanner — Mac App Store edition

## What is already true

The app ships today as a notarized Developer ID disk image. That works: a
teacher double-clicks and it opens. **Nothing in this plan may disturb it.**
Everything new lives in `AppStore/` and writes to `AppStore/dist/`.

| | Developer ID (shipping) | App Store (this plan) |
| --- | --- | --- |
| Build | `packaging/build_macos.sh` | `AppStore/build_appstore.sh` |
| Entitlements | `packaging/entitlements.plist` | `AppStore/entitlements.plist` |
| App signed with | Developer ID Application | Apple Distribution |
| Installer signed with | Developer ID Installer | 3rd Party Mac Developer Installer |
| Sandbox | no | **yes, mandatory** |
| Output | `dist/*.dmg`, `dist/*.pkg` | `AppStore/dist/*-appstore.pkg` |

## Read this before starting

The sandbox is the whole problem. Signing is half a day; the sandbox is the
rest. Six things the app does are forbidden inside it, and one entitlement it
needs may be refused whatever else is done.

**Step 0 is a go/no-go.** Do it before any of the work below.

---

## Step 0 — price the risk that sinks everything

CPython builds and runs code objects at runtime, so the bundle needs
`com.apple.security.cs.allow-unsigned-executable-memory`. App Review grants
that with justification and often refuses it for Python applications. If it
is refused, steps 1–7 were wasted.

Cheapest way to find out: do steps 1–6, submit, and let review answer. There
is no way to ask in advance. So decide up front whether the work is worth the
risk, and if it is, keep the Developer ID build shipping throughout so a
refusal costs nothing but time.

---

## Step 1 — certificates and profile

`AppStore/build_appstore.sh` refuses to start without these and names each one.

1. A certificate to sign the **app**. Either of these works and the build
   accepts whichever is present:
   - **Apple Distribution** — the current unified type, one certificate for
     every platform. Recommended, because distribution certificates are
     limited per account and this one is not spent on macOS alone.
   - **Mac App Distribution** — macOS only, and installs under its legacy
     keychain name `3rd Party Mac Developer Application`.

   Not "Developer ID Application", which this Mac already has and which is
   for distribution *outside* the store.
2. **Mac Installer Distribution** certificate — signs the `.pkg`. Installs
   under its legacy keychain name, `3rd Party Mac Developer Installer`.
3. Register the App ID `org.davidhohnholt.datalink-scanner` if it is not
   already, then create a **Mac App Store provisioning profile** for it and
   save it as `AppStore/embedded.provisionprofile`.
4. Create the app record in App Store Connect with that bundle ID.

Nothing in the repo should hold a certificate, a key or a profile's contents.
`.gitignore` already excludes `AppStore/embedded.provisionprofile`.

---

## Step 2 — bundle the reader's libraries instead of installing them

**Why:** `paper.install_packages()` pip-installs OpenCV, NumPy and Pillow into
Application Support on first use and imports them from there. Downloading and
executing code is refused by App Review outright.

**DONE 2026-09-25.** `build_appstore.sh` bundles the three with
`--collect-all`, and the runtime half now asks `edition.sandboxed()`:
`pip_available()` returns False, `install_packages()` raises, and `_pillow()`
no longer falls back to the support directory. The Paper tab's install button
was already hidden by `can_install_packages`, which is now False there.
`disable-library-validation` is gone from the entitlements.

The original note follows. `build_appstore.sh` already passes `--collect-all
cv2 --collect-all numpy --collect-all PIL`. What remains is the runtime half:

- `src/datalink_scanner/paper.py` — `support_dir()`, `install_packages()`,
  `pip_available()` and the `sys.path` insertion in `run_pipeline()` and
  `_environment()` must not run in the store edition.
- The Paper tab's "Install support" button and its `/api/paper/install`
  route must be hidden and refused.

**Bonus:** this also retires
`com.apple.security.cs.disable-library-validation`. Once the libraries are
inside a bundle signed by one team, validation passes. That is one fewer
entitlement to justify.

**Cost:** the bundle grows by roughly 150 MB.

---

## Step 3 — decide how the app knows which edition it is

One codebase, two behaviours. Recommended: detect the sandbox at runtime
rather than baking a flag in, because it cannot be wrong.

```python
# src/datalink_scanner/edition.py
from pathlib import Path

def sandboxed() -> bool:
    """True inside an App Store build: the sandbox relocates HOME."""
    return "/Library/Containers/" in str(Path.home())
```

**DONE 2026-09-25.** `src/datalink_scanner/edition.py`, verified on a signed
sandboxed build. Mind the trap it documents: the sandbox redirects the home
directory that `pwd` reports, which is what `Path.home()` asks, but it leaves
`HOME` in the environment pointing at the real home. Code that reads
`os.environ["HOME"]` escapes the container and is then denied.
`APP_SANDBOX_CONTAINER_ID` is **not set** in this bundle, so it is no use.

The original note follows. `APP_SANDBOX_CONTAINER_ID` in the
environment is the usual alternative; check both and keep whichever proves
reliable.

---

## Step 4 — the scanner, under the sandbox

**Unverified and important.** `com.apple.security.device.serial` is in the
entitlements, but whether it reaches `/dev/cu.usbserial-1200` from inside a
sandbox has not been tested. If it does not, the store edition cannot talk to
the DataLink at all and is a paper-only app — which may still be worth
shipping, but it is a different product and the listing must say so.

Test this immediately after the first signed build. It is the second
go/no-go.

**ANSWERED 2026-09-25: GO.** A signed sandboxed build opened
`/dev/cu.usbserial-1200`, ran the whole captured handshake and the scanner
reported Data Collection active. `lsof` showed that pid holding the device on
fd 15, and `codesign` confirmed the same bundle was sandboxed with
`com.apple.security.device.serial`. Round trips seen on the wire included
`V -> ADV 1200OK`, `T4 -> S32155` and `Q1 -> 4658`, so it is genuinely
bidirectional and not merely an open that happened to succeed.

The store edition can therefore scan. Steps 2, 5 and 6 are worth doing.

### Before testing anything in this bundle

The sandbox breaks things that fail silently. The first one cost a session:
Python's `mimetypes` module reads `/etc/apache2/mime.types`, which exists on
macOS but cannot be opened inside the sandbox, and the `PermissionError`
escaped `guess_type()` and killed every static request — the window came up
blank with nothing logged anywhere. Note the shape of it, because the rest of
this list will look the same: a file that `os.path.isfile()` says is there,
an exception on `open()`, and a dead request.

When something in this bundle misbehaves, run the executable straight from a
terminal rather than double-clicking it. Its stderr is the only place the
traceback appears:

    "AppStore/dist/DataLink Scanner.app/Contents/MacOS/DataLink Scanner"

---

## Step 5 — remove what the sandbox forbids

**DONE 2026-09-25**, with `tests/test_edition.py` asserting each one. Every
entry point in `updates.py` raises `UpdateError`, and `auto_check_enabled()`
returns False so the daily check never starts. `keychain.py` reports "not
answered" and falls through to the in-process path it already had. The page
hides the Updates card and refuses the typed-path fallback, and the app drops
the Check for Updates menu item.

Each of these must be inert when `sandboxed()`:

| Where | What | Why |
| --- | --- | --- |
| `updates.py` | the whole module: `upgrade()`, `sweep()`, `forget_stale_registrations()`, the daily check | A store app updates through the store. Moving other apps to the Trash and editing the LaunchServices database are both forbidden. |
| `keychain.py` | `ensure_helper()`, `_ask_helper()` — read in-process instead | Writing an executable and running it is forbidden. It is also unnecessary: with an Apple Distribution signature the Keychain identifies the app by signature, which is the exact problem the helper exists to work around. |
| `webui/app.js` | the typed-path fallback in `#paperChooseButton` | A sandboxed app reaches only files handed to it by an open panel. The native panel path already works; the `prompt()` fallback must go. |
| `server.py` | `/api/paper/install`, `/api/paper/purge` paths that touch the support dir | Nothing is installed at runtime any more. |
| Settings tab | the update controls | Nothing for them to do. |

---

## Step 6 — data lives somewhere else

Inside the sandbox `~/Library/Application Support/DataLink Scanner/` is
really `~/Library/Containers/org.davidhohnholt.datalink-scanner/Data/...`.
`paths.py` needs no change — `expanduser` does the right thing — but:

- **Decided 2026-09-25: no migration.** A teacher who has been using the
  Developer ID build will not see their old sessions in the store build, and
  the listing must say so. Migrating means reading outside the container
  through an open panel, which is a sandbox-escape-shaped feature to explain
  at review, for the benefit of the few people who have both. Anyone who
  needs their history can export CSV from the old app. The store build is for
  people who do not have the Developer ID one.
- Nothing in `paths.py` changes: `Path.home()` is redirected for us. Verified
  on the signed build, where `capture_root` came back as
  `~/Library/Containers/org.davidhohnholt.datalink-scanner/Data/...`.
- `paths.py` has a `DATALINK_CAPTURE_DIR` override used by tests; leave it.

---

## Step 7 — build, validate, upload

**Validation passes as of 2026-09-25**, with no errors and no warnings. Four
things had to be fixed to get there, none of which the build or the signature
complained about:

1. PyInstaller writes almost no Info.plist. App Store Connect refused it with
   "Unable to detect platform from Info.plist", which is not about the
   platform flag on the command line: the bundle itself has to carry
   `CFBundleSupportedPlatforms`, `LSMinimumSystemVersion` and the `DT*` build
   metadata that Xcode normally writes. The build reads all of it from the
   toolchain now.
2. An arm64 only bundle may not claim macOS 11. Either ship a universal binary
   or set the floor to 12.0; the build raises it automatically and says so.
3. The signature had to carry `com.apple.application-identifier` matching the
   provisioning profile, or the build is not eligible for TestFlight.
4. Only the app may carry it. Nested binaries with an identifier and no
   profile of their own are the same warning again.

### The build you can test is not the build you upload

Once the signature carries the application identifier, macOS checks the
embedded profile before launching, and a Mac App Store profile provisions no
devices. The app then fails to open with "Launchd job spawn failed", which
names nothing. Both forms are built from the same script:

    ./AppStore/build_appstore.sh                              # upload this
    DATALINK_APPSTORE_TESTABLE=1 ./AppStore/build_appstore.sh # open this

The testable one validates with a single warning saying TestFlight is
unavailable, which is true of it and not of the other.

### Credentials

The API key belongs at `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`.
Transporter and altool both look there and neither says so when it is missing.



```bash
./AppStore/build_appstore.sh
```

Then validate before uploading, because a failed validation is quick and a
failed review is not:

```bash
xcrun altool --validate-app -f AppStore/dist/*-appstore.pkg \
  -t macos --apiKey KFBHF6LUP5 --apiIssuer <issuer-id>
```

Upload with Transporter — `xcrun iTMSTransporter` is a stub now, the real
binary is inside Transporter.app from the Mac App Store:

```bash
/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter \
  -m upload -assetFile "AppStore/dist/DataLink-Scanner-<version>-appstore.pkg" \
  -apiKey KFBHF6LUP5 -apiIssuer <issuer-id>
```

Transporter looks for `AuthKey_KFBHF6LUP5.p8` in
`~/.appstoreconnect/private_keys/`. It takes the key **ID**, not a path.

---

## Step 8 — the listing

`AppStore/screenshots/mac-1280x800/` already holds eight screenshots. Review
will also want a privacy declaration: **the app collects nothing and sends
nothing**, except that a teacher may choose to upload a scored result to
their own T-TESS instance. Student data stays on the Mac. Say so plainly;
it is true and it is unusual.

---

## Definition of done

- `AppStore/build_appstore.sh` runs clean and produces a signed `.pkg`
- the signed bundle reports `app-sandbox = true`
- a sandboxed build talks to the scanner, or the decision to ship
  paper-only is taken deliberately
- `altool --validate-app` passes
- the Developer ID disk image still builds, is still notarized, and still
  behaves exactly as it does today
- `python -m unittest discover -s tests` passes for both editions
