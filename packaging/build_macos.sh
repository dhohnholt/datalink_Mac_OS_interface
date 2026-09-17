#!/bin/zsh
# Build a standalone .app and a drag-to-Applications .dmg.
#
# This is the no-Homebrew path — everything, including Python, is bundled.
# Prefer `brew install dhohnholt/datalink/datalink-scanner`, which needs no
# build step and updates with `brew upgrade`.
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
# Whatever Python builds this gets bundled, and its framework carries a
# minimum-macOS stamp. A Homebrew Python is stamped for the macOS it was
# bottled for — 26.0 on Tahoe — so a .dmg built with it will not launch on
# Sonoma. A python.org framework build targets macOS 11, so .venv-dmg is
# preferred when it exists. docs/RELEASING.md says how to make one.
if [[ -z "${PYTHON_BIN:-}" && -x "$PROJECT_DIR/.venv-dmg/bin/python" ]]; then
  PYTHON_BIN="$PROJECT_DIR/.venv-dmg/bin/python"
fi
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"
PACKAGING_DIR="$PROJECT_DIR/packaging"
ICON_FILE="$PROJECT_DIR/src/datalink_scanner/resources/DataLinkScanner.icns"
DIST_DIR="$PROJECT_DIR/dist"
DMG_ROOT="$PROJECT_DIR/build/dmg"
export PYINSTALLER_CONFIG_DIR="$PROJECT_DIR/build/pyinstaller-config"
APP_NAME="DataLink Scanner"
ARCH=$(/usr/bin/uname -m)
case "$ARCH" in
  arm64) ARCH_LABEL="Apple-Silicon" ;;
  x86_64) ARCH_LABEL="Intel" ;;
  *) ARCH_LABEL="$ARCH" ;;
esac
DMG_PATH="$DIST_DIR/DataLink-Scanner-macOS-$ARCH_LABEL.dmg"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Missing Python environment: $PYTHON_BIN"
  echo "Create one with: python3 -m venv .venv && .venv/bin/pip install -e . pyinstaller"
  exit 1
fi
if [[ ! -f "$ICON_FILE" ]]; then
  echo "Missing icon: $ICON_FILE"
  exit 1
fi

rm -rf "$PROJECT_DIR/build/pyinstaller" "$DMG_ROOT"
mkdir -p "$DIST_DIR" "$DMG_ROOT"

"$PYTHON_BIN" -m PyInstaller \
  --noconfirm \
  --clean \
  --windowed \
  --name "$APP_NAME" \
  --icon "$ICON_FILE" \
  --osx-bundle-identifier "org.davidhohnholt.datalink-scanner" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/webui:web" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/resources:datalink_scanner/resources" \
  --paths "$PROJECT_DIR/src" \
  --paths "$PROJECT_DIR/src/datalink_scanner/vendor" \
  --paths "$PROJECT_DIR/src/datalink_scanner/vendor/omr" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/vendor/omr/reference_page.png:." \
  --hidden-import serial \
  --hidden-import WebKit \
  --hidden-import cv2 \
  --hidden-import numpy \
  --hidden-import PIL \
  --collect-all cv2 \
  --hidden-import analyze_exam \
  --hidden-import calibrate_page \
  --hidden-import extract_template_a \
  --hidden-import page_selection \
  --hidden-import analysis_core \
  --hidden-import result_schema \
  --distpath "$DIST_DIR" \
  --workpath "$PROJECT_DIR/build/pyinstaller" \
  --specpath "$PACKAGING_DIR" \
  "$PACKAGING_DIR/pyinstaller_entry.py"

# PyInstaller stamps every bundle 0.0.0, which leaves Finder's Get Info and the
# app's own Check for Updates unable to tell one copy from another. Must happen
# before the signature, which covers Info.plist.
VERSION=$("$PYTHON_BIN" -c 'import datalink_scanner; print(datalink_scanner.__version__)')
INFO_PLIST="$DIST_DIR/$APP_NAME.app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $VERSION" "$INFO_PLIST"
done

# The paper pipeline shells out to pdftoppm and pdfinfo. A Mac that cannot
# install Homebrew has neither, so they travel inside the bundle — and they
# have to come from a build that runs on more than the newest macOS, which
# Homebrew's does not. docs/RELEASING.md says how to make the prefix.
if [[ -z "${DATALINK_POPPLER_PREFIX:-}" && -x "$PROJECT_DIR/.poppler-prefix/bin/pdftoppm" ]]; then
  export DATALINK_POPPLER_PREFIX="$PROJECT_DIR/.poppler-prefix"
fi
"$PYTHON_BIN" "$PACKAGING_DIR/bundle_poppler.py" "$DIST_DIR/$APP_NAME.app"

# Every Mach-O in the bundle says the oldest macOS it will load on, and the
# bundle is only as portable as its least portable piece. Checking here is the
# difference between finding out now and a teacher finding out on launch.
# OpenCV's wheel is built for macOS 13, which sets the floor for the whole
# bundle now that paper scanning ships inside it.
OLDEST_SUPPORTED="${DATALINK_MIN_MACOS:-13.0}"
HIGHEST=$(/usr/bin/find "$DIST_DIR/$APP_NAME.app/Contents" -type f \
    \( -name "*.so" -o -name "*.dylib" -o -name "Python" \) \
    -exec /usr/bin/otool -l {} \; 2>/dev/null \
  | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}' | sort -V | tail -1)
if [[ -n "$HIGHEST" && "$HIGHEST" != "$OLDEST_SUPPORTED" ]] \
   && [[ "$(printf '%s\n%s\n' "$OLDEST_SUPPORTED" "$HIGHEST" | sort -V | tail -1)" == "$HIGHEST" ]]; then
  echo
  echo "This build needs macOS $HIGHEST or newer, which is too new to ship."
  echo "Built by whatever this Mac had rather than for the oldest macOS we"
  echo "support. The files asking for it:"
  /usr/bin/find "$DIST_DIR/$APP_NAME.app/Contents" -type f \
      \( -name "*.so" -o -name "*.dylib" -o -name "Python" \) 2>/dev/null \
    | while read -r found; do
        got=$(/usr/bin/otool -l "$found" 2>/dev/null | grep -A4 LC_BUILD_VERSION \
              | grep minos | tr -s ' ' | awk '{print $2}' | head -1)
        [[ "$got" == "$HIGHEST" ]] && echo "    ${found##*/Contents/}"
      done | head -5
  echo
  echo "  the Python      — build with .venv-dmg, made from python.org"
  echo "  poppler         — set DATALINK_POPPLER_PREFIX to a conda-forge prefix"
  echo "  a wheel         — install the macosx_11_0 build of it explicitly"
  echo
  echo "See docs/RELEASING.md. DATALINK_MIN_MACOS raises the floor deliberately."
  exit 1
fi

# Ad-hoc signature: this build is not Apple notarized, so macOS still asks the
# user to confirm the first launch. See packaging/INSTALL.md.
/usr/bin/codesign --force --deep --sign - "$DIST_DIR/$APP_NAME.app"

/bin/cp -R "$DIST_DIR/$APP_NAME.app" "$DMG_ROOT/"
/bin/ln -s /Applications "$DMG_ROOT/Applications"
/bin/cp "$PACKAGING_DIR/INSTALL.md" "$DMG_ROOT/Read Me.md"
/bin/rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Built app: $DIST_DIR/$APP_NAME.app"
echo "Built installer: $DMG_PATH"
