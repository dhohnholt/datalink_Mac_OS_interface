#!/bin/zsh
# Cut a release and update the Homebrew tap.
#
#   packaging/release.sh 1.1.0
#
# Bumps the version, tags it, pushes, then rewrites the tap's formula with the
# new URL and checksum so `brew upgrade datalink-scanner` picks it up.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: packaging/release.sh <version>   e.g. packaging/release.sh 1.1.0"
  exit 2
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "version must look like 1.2.3"
  exit 2
fi

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

REPO="dhohnholt/datalink_Mac_OS_interface"
TAP_REPO="dhohnholt/homebrew-datalink"
TAP_DIR="${TAP_DIR:-$(brew --repository)/Library/Taps/dhohnholt/homebrew-datalink}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash first."
  exit 1
fi

echo "==> Bumping to $VERSION"
/usr/bin/sed -i '' -E "s/^version = \".*\"/version = \"$VERSION\"/" pyproject.toml
/usr/bin/sed -i '' -E "s/^__version__ = \".*\"/__version__ = \"$VERSION\"/" src/datalink_scanner/__init__.py
grep -q "version = \"$VERSION\"" pyproject.toml
grep -q "__version__ = \"$VERSION\"" src/datalink_scanner/__init__.py

echo "==> Running tests"
if [[ -x .venv/bin/python ]]; then
  .venv/bin/python -m unittest discover -s tests -t tests
else
  python3 -m unittest discover -s tests -t tests
fi

echo "==> Tagging v$VERSION"
git add pyproject.toml src/datalink_scanner/__init__.py
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin HEAD
git push origin "v$VERSION"

TARBALL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
echo "==> Checksumming $TARBALL"
# GitHub generates the tag tarball on demand; give it a moment on a fresh tag.
SHA=""
for attempt in 1 2 3 4 5; do
  SHA=$(curl -sfL "$TARBALL" | shasum -a 256 | cut -d' ' -f1) && [[ -n "$SHA" ]] && break
  echo "   not ready yet, retrying ($attempt/5)"
  sleep 3
done
[[ -n "$SHA" ]] || { echo "Could not download $TARBALL"; exit 1; }
echo "    sha256 $SHA"

echo "==> Updating the formula"
/usr/bin/sed -i '' -E \
  -e "s|^  url \"https://github.com/$REPO/archive.*|  url \"$TARBALL\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  packaging/homebrew/datalink-scanner.rb
git add packaging/homebrew/datalink-scanner.rb
git commit -m "Point the formula at v$VERSION"
git push origin HEAD

if [[ ! -d "$TAP_DIR" ]]; then
  echo "Tap checkout not found at $TAP_DIR"
  echo "Run: brew tap ${TAP_REPO%%/*}/datalink"
  exit 1
fi
echo "==> Publishing to $TAP_REPO"
/bin/cp packaging/homebrew/datalink-scanner.rb "$TAP_DIR/Formula/datalink-scanner.rb"
git -C "$TAP_DIR" add Formula/datalink-scanner.rb
git -C "$TAP_DIR" commit -m "datalink-scanner $VERSION"
git -C "$TAP_DIR" push

echo
echo "Released v$VERSION. Users update with:"
echo "    brew update && brew upgrade datalink-scanner"
