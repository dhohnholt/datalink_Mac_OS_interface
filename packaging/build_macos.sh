#!/bin/zsh
# Build a standalone .app and a drag-to-Applications .dmg.
#
# This is the no-Homebrew path — everything, including Python, is bundled.
# Prefer `brew install dhohnholt/datalink/datalink-scanner`, which needs no
# build step and updates with `brew upgrade`.
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
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
  --hidden-import serial \
  --hidden-import WebKit \
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
