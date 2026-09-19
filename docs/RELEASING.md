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
