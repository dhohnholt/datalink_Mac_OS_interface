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
builds the `.dmg`, and creates the GitHub release with the disk image attached.

It refuses to start on a dirty working tree, and if the tests fail it stops
before tagging, so nothing is published. Pass `--skip-dmg` to publish the
release without spending the ~40 seconds on a fresh disk image.

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
