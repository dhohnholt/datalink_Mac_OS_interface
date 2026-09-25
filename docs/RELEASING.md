# Releasing

Versions live in two files, `pyproject.toml` and
`src/datalink_scanner/__init__.py`, and the Homebrew formula pins a tag tarball
by checksum. `packaging/release.sh` does all of it:

```bash
packaging/release.sh 1.1.0
```

In order it: bumps both version strings, runs the tests, commits, tags `v1.1.0`
and pushes, downloads the GitHub tag tarball to compute its `sha256`, rewrites
`packaging/homebrew/datalink-scanner.rb`, publishes that formula to the tap,
builds the `.dmg`, creates the GitHub release with the disk image attached, and
finally builds and attaches the bottle.

It refuses to start on a dirty working tree, and if the tests fail it stops
before tagging, so nothing is published. Pass `--skip-dmg` to publish the
release without spending the ~40 seconds on a fresh disk image.

## Bottles

Homebrew builds a formula's resources from source. For this one that means
recompiling PyObjC on every install — about 47 of the 50 seconds an upgrade
takes, even for a release that only changed some text. A **bottle** is a
prebuilt keg: `brew upgrade` downloads it and unpacks it instead.

The script builds one at the end of a release and attaches it to the GitHub
release, then records it in the formula:

```ruby
bottle do
  root_url "https://github.com/dhohnholt/datalink_Mac_OS_interface/releases/download/v1.1.0"
  sha256 cellar: :any_skip_relocation, arm64_tahoe: "…"
end
```

Three things about it are worth knowing:

* **It reinstalls the formula.** `brew bottle` only accepts a keg installed
  with `--build-bottle`, and `brew reinstall` has no such flag, so the old keg
  is removed first. Quit the app before releasing, or expect to relaunch it.
* **A bottle is tagged for one macOS and architecture.** Anyone whose Mac does
  not match builds from source exactly as they do today — nothing becomes less
  compatible, some installs simply become faster.
* **It costs two formula commits per release**, because the bottle can only be
  built once the tap already carries the new formula, and can only be uploaded
  once the release exists.

`--skip-bottle` publishes without one. `--bottle-only <version>` builds and
attaches a bottle for a release that is already cut, which is also how to
recover if the bottle step fails partway.

Users then get the new version — command and app together — with:

```bash
brew update && brew upgrade datalink-scanner
```

## One-time setup

The tap is a separate repository, `dhohnholt/homebrew-datalink`, because
Homebrew requires the `homebrew-` prefix. Get a local checkout with:

```bash
brew tap dhohnholt/datalink
```

The release script expects it at
`$(brew --repository)/Library/Taps/dhohnholt/homebrew-datalink`, or wherever
`$TAP_DIR` points.

## Verifying a release

```bash
brew uninstall datalink-scanner || true
brew install --build-from-source dhohnholt/datalink/datalink-scanner
brew test datalink-scanner
brew audit --strict --online dhohnholt/datalink/datalink-scanner
```

`brew test` starts the workspace on a free port and checks that it serves its
own UI, so a broken package data path or a missing dependency fails there
rather than on a teacher's Mac.

## What the formula installs

- `bin/datalink-scanner` — a virtualenv with `pyserial` vendored as a resource
- `DataLink Scanner.app` — a launcher bundle that `exec`s
  `opt/datalink-scanner/bin/datalink-scanner`

Because the bundle only references the stable `opt` path, an upgrade updates
the app without rebuilding it, and the `/Applications` symlink created by
`datalink-scanner install-app` keeps working across versions.

## Updating the pyserial resource

```bash
brew update-python-resources datalink-scanner
```

## Signing and notarization

The disk image is signed with a Developer ID Application certificate and
notarized, which is what lets a teacher open it by double-clicking instead of
Control-clicking and confirming a warning about an unidentified developer.

The build finds the certificate on its own. `DATALINK_SIGN_IDENTITY` names a
different one. With no certificate at all it falls back to an ad-hoc signature
and says so, and the app still runs.

Signing happens inner-out — every Mach-O, then each framework, then the
bundle — rather than with `--deep`, which is deprecated and applies one set of
entitlements to everything it touches. `packaging/entitlements.plist` carries
only two: unsigned executable memory, which CPython needs, and disabled
library validation, because the paper reader loads OpenCV, NumPy and Pillow
from Application Support and those are not signed by this team.

`--timestamp` contacts Apple, so signing needs the network.

### Notarization credentials

Stored once, by the owner, in a keychain profile. Nothing secret goes in this
repo or on a command line in it:

```bash
xcrun notarytool store-credentials datalink-notary   --apple-id <apple-id> --team-id 6BA6YTBG7Z --password <app-specific-password>
```

The app-specific password comes from appleid.apple.com → Sign-In and Security
→ App-Specific Passwords. An App Store Connect API key works too, with
`--key`, `--key-id` and `--issuer`, and avoids a password entirely.

`DATALINK_NOTARY_PROFILE` names a different profile. Without one the build
still signs, says the image is not notarized, and prints the command above.

Notarization happens twice, and both are needed. The app is submitted and
stapled before the image is built, and then the image is submitted and
stapled in turn. Stapling only the image covers downloading it; it does not
cover the app once it has been dragged to /Applications on a Mac that has
never seen it and has no network to ask Apple. That is a school Mac, which is
what this app is for. Each pass takes a few minutes.

`ditto`, not `zip`, makes the archive for the app's submission: a bundle is
made of symlinks and extended attributes, and an archive that loses them is
refused.

If it is refused:

```bash
xcrun notarytool log <submission-id> --keychain-profile datalink-notary
```

## The .pkg installer

Built from the same signed, stapled bundle as the disk image, so the two
cannot drift. A disk image is what a person downloads and drags; a `.pkg` is
what a district deploys without anybody dragging anything, and it is the only
shape the App Store accepts.

Which certificate signs it decides where it can go:

| Certificate | Where the installer can go |
| --- | --- |
| `Developer ID Installer` | deployed by MDM, notarized, no sandbox |
| `3rd Party Mac Developer Installer` | the App Store, and only with the app signed `Apple Distribution` and a provisioning profile embedded |

With neither, an unsigned `.pkg` is still built. It installs and is useful for
checking the layout, but nobody else can be asked to trust it.
`DATALINK_INSTALLER_IDENTITY` names one explicitly.

### What the App Store would additionally require

Signing is the small part. The Mac App Store requires the sandbox, and the
app does several things the sandbox forbids:

- It installs OpenCV, NumPy and Pillow at runtime and imports them.
  Downloading and running code is refused outright. They would have to be
  bundled instead — which would also retire
  `com.apple.security.cs.disable-library-validation`.
- It copies a binary to a fixed path and re-signs it, for the Keychain. A
  sandboxed app may not write an executable and run it. With an Apple
  Distribution signature the helper is unnecessary anyway, because the
  Keychain can then identify the app by its signature.
- It updates itself through Homebrew. App Store apps update through the
  store.
- It moves other copies of itself to the Trash and edits the LaunchServices
  database. Neither is permitted.
- It accepts a typed path to a PDF. A sandboxed app reaches only files the
  user chose in an open panel.
- Its data would move into a container, so existing sessions would not be
  found.

And one that may be fatal however much of the above is done: CPython needs
`com.apple.security.cs.allow-unsigned-executable-memory`, which App Review
grants only with justification and often refuses. That risk is worth pricing
before any of the rest is attempted.

## The Keychain helper

`packaging/keychain_helper.c` is compiled and signed into
`Contents/Helpers/keychain-helper` by the build. It exists because macOS
records which program may read a Keychain item by file path and notices when
the bytes there change, so a bundle that is re-signed every build can never
stay trusted. The app copies it once to
`~/Library/Application Support/DataLink Scanner/runtime/keychain-helper-native`
and leaves it alone after that, so an update does not cost a password prompt.

It needs no toolchain beyond the command line tools. If `clang` is missing the
build fails loudly rather than shipping an app without it.

## The DMG and which macOS it runs on

Whatever Python builds the disk image is bundled into it, and a framework
carries the oldest macOS it will load on. Homebrew's Python is stamped for the
macOS it was bottled for — 26.0 on Tahoe — so a `.dmg` built with it refuses to
launch on anything older, with no useful error. A python.org framework build
targets macOS 11.

So the build prefers `.venv-dmg`, made once from a python.org install:

```bash
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -m venv .venv-dmg
.venv-dmg/bin/pip install . pyinstaller
```

`packaging/build_macos.sh` uses it automatically when it exists, and refuses to
build a bundle that needs anything newer than macOS 12 — naming the version it
found, because the failure is otherwise invisible until someone on an older Mac
tries to open it. `DATALINK_MIN_MACOS` raises that floor deliberately.

### poppler for the disk image

The paper pipeline shells out to `pdftoppm` and `pdfinfo`, so the disk image
carries its own — a Mac that cannot reach GitHub cannot install Homebrew to get
them. Homebrew's poppler is no help: it is only bottled for the macOS it was
built on, so bundling it moves the "too new" problem rather than solving it.
conda-forge ships the same poppler version built for macOS 11.

Make a prefix once:

```bash
curl -sfL https://micro.mamba.pm/api/micromamba/osx-arm64/latest | tar -xj bin/micromamba
bin/micromamba create -y -p .poppler-prefix -c conda-forge poppler
```

`.poppler-prefix` in the project root is picked up automatically and is
gitignored; `DATALINK_POPPLER_PREFIX` overrides it. Without either, the build
falls back to Homebrew's copy and the deployment-target check stops it — after
the release has already been tagged, so make the prefix first.

Bundling the *same poppler version* matters: rendering the same batch with a
different engine changed 2 of 450 responses. With conda-forge's build the disk
image scored a real batch identically to the Homebrew install — 0 of 450
responses different, same scores, same item statistics.

Check a finished build by mounting the disk image — the loose `.app` is
deleted once the `.dmg` is written, because macOS registers every bundle it
finds and a copy sitting in `dist/` shows up in Launchpad beside the installed
app:

```bash
hdiutil attach -nobrowse -mountpoint /tmp/dl "dist/DataLink-Scanner-macOS-Apple-Silicon.dmg"
otool -l "/tmp/dl/DataLink Scanner.app/Contents/Frameworks/Python.framework/Versions/"*/Python | grep minos
hdiutil detach /tmp/dl
```

## The DMG

`packaging/build_macos.sh` builds the standalone, Python-bundling `.app` and
`.dmg` for people without Homebrew, and the release script runs it so the
Releases page never goes stale against the formula.

Unlike the Homebrew build it is architecture-specific — it produces a disk
image for whichever Mac builds it — and, being downloaded, it is subject to
Gatekeeper. Homebrew remains the better path for anyone who has it.
