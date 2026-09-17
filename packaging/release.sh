#!/bin/zsh
# Cut a release and update the Homebrew tap.
#
#   packaging/release.sh 1.1.0
#
# Bumps the version, tags it, pushes, then rewrites the tap's formula with the
# new URL and checksum so `brew upgrade datalink-scanner` picks it up.
#
# It then builds a bottle — a prebuilt keg — and attaches it to the release,
# so an upgrade unpacks a binary instead of spending ~47 seconds recompiling
# PyObjC. Bottling reinstalls the formula, so the app is briefly absent.
#   --skip-bottle   publish without one; users build from source as before
#   --bottle-only   just build and attach the bottle for a release already cut
set -euo pipefail

VERSION=""
SKIP_DMG=0
SKIP_BOTTLE=0
BOTTLE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-dmg) SKIP_DMG=1; shift ;;
    --skip-bottle) SKIP_BOTTLE=1; shift ;;
    --bottle-only) BOTTLE_ONLY=1; shift ;;
    -*) echo "unknown option: $1"; exit 2 ;;
    *) VERSION="$1"; shift ;;
  esac
done
if [[ -z "$VERSION" ]]; then
  echo "usage: packaging/release.sh [--skip-dmg] [--skip-bottle|--bottle-only] <version>"
  echo "   e.g. packaging/release.sh 1.1.0"
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
if ! command -v gh >/dev/null; then
  echo "The GitHub CLI (gh) is required to publish the release."
  exit 1
fi
if [[ $SKIP_DMG -eq 0 ]] && [[ $BOTTLE_ONLY -eq 0 ]] && ! "${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}" -c "import PyInstaller" 2>/dev/null; then
  echo "PyInstaller is missing, so the .dmg cannot be built."
  echo "Install it with: .venv/bin/pip install pyinstaller"
  echo "Or re-run with --skip-dmg to publish without refreshing the disk image."
  exit 1
fi

# A bottle is a prebuilt keg. Without one every `brew upgrade` recompiles
# PyObjC on the user's machine, which is about 47 of the 50 seconds an
# update takes. Building it has to happen after the release exists, because
# that is where the file is hosted, and after the tap has the new formula,
# because that is what gets installed.
build_bottle() {
  echo "==> Building the bottle"
  BOTTLE_DIR="$PROJECT_DIR/dist/bottle"
  BOTTLE_ROOT="https://github.com/$REPO/releases/download/v$VERSION"
  FORMULA_REF="${TAP_REPO%%/*}/datalink/datalink-scanner"
  rm -rf "$BOTTLE_DIR"
  mkdir -p "$BOTTLE_DIR"

  # `brew bottle` only accepts a keg installed with --build-bottle, and
  # `brew reinstall` has no such flag, so the old keg goes first. This does
  # briefly remove the installed app.
  brew uninstall --ignore-dependencies "$FORMULA_REF" >/dev/null 2>&1 || true
  if ! brew install --build-bottle "$FORMULA_REF"; then
    echo "The bottle build failed; the release itself is fine and users will"
    echo "build from source. Re-run: packaging/release.sh --bottle-only $VERSION"
    exit 1
  fi

  ( cd "$BOTTLE_DIR" && brew bottle --json --no-rebuild --root-url="$BOTTLE_ROOT" "$FORMULA_REF" )
  JSON=$(/bin/ls "$BOTTLE_DIR"/*.bottle.json 2>/dev/null | head -1)
  BUILT=$(/bin/ls "$BOTTLE_DIR"/*.bottle.tar.gz 2>/dev/null | head -1)
  if [[ -z "$JSON" || -z "$BUILT" ]]; then
    echo "brew bottle produced nothing in $BOTTLE_DIR"
    exit 1
  fi

  # Writes the bottle block into the tap's copy of the formula, which is the
  # one Homebrew reads. --no-commit because this script owns the commits.
  brew bottle --merge --write --no-commit "$JSON"

  # Homebrew names the local file with a double dash and downloads it with a
  # single one, so ask it for the URL it will actually request rather than
  # guessing at the convention.
  BOTTLE_URL=$(brew info --json=v2 "$FORMULA_REF" \
    | /usr/bin/python3 -c 'import json,sys
files = json.load(sys.stdin)["formulae"][0]["bottle"]["stable"]["files"]
print(next(iter(files.values()))["url"])')
  UPLOAD="$BOTTLE_DIR/$(/usr/bin/basename "$BOTTLE_URL")"
  [[ "$BUILT" == "$UPLOAD" ]] || /bin/mv "$BUILT" "$UPLOAD"
  echo "    $(/usr/bin/basename "$UPLOAD")"

  gh release upload "v$VERSION" "$UPLOAD" --clobber

  echo "==> Recording the bottle in the formula"
  /bin/cp "$TAP_DIR/Formula/datalink-scanner.rb" packaging/homebrew/datalink-scanner.rb
  git add packaging/homebrew/datalink-scanner.rb
  git commit -m "Add the v$VERSION bottle"
  git push origin HEAD
  git -C "$TAP_DIR" add Formula/datalink-scanner.rb
  git -C "$TAP_DIR" commit -m "datalink-scanner $VERSION bottle"
  git -C "$TAP_DIR" push
}

if [[ $BOTTLE_ONLY -eq 1 ]]; then
  build_bottle
  echo
  echo "Bottled v$VERSION."
  exit 0
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
# The tap checkout is whatever `brew tap` last fetched, so it is routinely
# behind the remote.
git -C "$TAP_DIR" pull --rebase --quiet
/bin/cp packaging/homebrew/datalink-scanner.rb "$TAP_DIR/Formula/datalink-scanner.rb"
git -C "$TAP_DIR" add Formula/datalink-scanner.rb
git -C "$TAP_DIR" commit -m "datalink-scanner $VERSION"
git -C "$TAP_DIR" push

ASSETS=()
if [[ $SKIP_DMG -eq 0 ]]; then
  echo "==> Building the disk image"
  packaging/build_macos.sh >/dev/null
  for image in "$PROJECT_DIR"/dist/DataLink-Scanner-macOS-*.dmg; do
    [[ -f "$image" ]] && ASSETS+=("$image")
  done
  if [[ ${#ASSETS[@]} -eq 0 ]]; then
    echo "The build reported success but produced no .dmg."
    exit 1
  fi
fi

echo "==> Publishing the GitHub release"
gh release create "v$VERSION" "${ASSETS[@]}" \
  --title "v$VERSION" \
  --generate-notes \
  --notes "## Install

\`\`\`bash
brew install dhohnholt/datalink/datalink-scanner
datalink-scanner install-app
\`\`\`

Already installed? \`brew update && brew upgrade datalink-scanner\` updates the
command and the app together.

Without Homebrew, download the disk image below and drag the app to
Applications. That build bundles its own Python, is built for $(/usr/bin/uname -m)
only, and is ad-hoc signed rather than Apple notarized, so its first launch
needs a Control-click → **Open**."


if [[ $SKIP_BOTTLE -eq 0 ]]; then
  build_bottle
fi

echo
echo "Released v$VERSION."
echo "  https://github.com/$REPO/releases/tag/v$VERSION"
echo "Users update with:"
echo "    brew update && brew upgrade datalink-scanner"
