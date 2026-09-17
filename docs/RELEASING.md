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

## The DMG

`packaging/build_macos.sh` builds the standalone, Python-bundling `.app` and
`.dmg` for people without Homebrew, and the release script runs it so the
Releases page never goes stale against the formula.

Unlike the Homebrew build it is architecture-specific — it produces a disk
image for whichever Mac builds it — and, being downloaded, it is subject to
Gatekeeper. Homebrew remains the better path for anyone who has it.
