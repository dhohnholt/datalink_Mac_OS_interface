# Releasing

Versions live in two files, `pyproject.toml` and
`src/datalink_scanner/__init__.py`, and the Homebrew formula pins a tag tarball
by checksum. `packaging/release.sh` does all of it:

```bash
packaging/release.sh 1.1.0
```

It bumps both version strings, runs the tests, commits, tags `v1.1.0`, pushes,
downloads the GitHub tag tarball to compute its `sha256`, rewrites
`packaging/homebrew/datalink-scanner.rb`, and copies that formula into the tap
checkout and pushes it.

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

`packaging/build_macos.sh` still builds the standalone, Python-bundling `.app`
and `.dmg` for people without Homebrew. It is not part of the release script —
build it and attach it to the GitHub release manually when you want to refresh
it. Unlike the Homebrew build it is architecture-specific and, being
downloaded, is subject to Gatekeeper.
