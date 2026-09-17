#!/bin/sh
# Build "DataLink Scanner.app" — a thin launcher around an already-installed
# datalink-scanner command. The app itself is a real Cocoa application with
# its own window and menu bar; this bundle only gives it a Dock presence and
# somewhere for Finder and Spotlight to point.
#
# The bundle holds no Python of its own. That is the point: `brew upgrade`
# replaces the command the launcher execs, so the app updates with it and
# there is no second copy to keep in step.
#
#   make_app_bundle.sh --cli /opt/homebrew/opt/datalink-scanner/bin/datalink-scanner \
#                      --output /opt/homebrew/Cellar/datalink-scanner/1.0.0 \
#                      --version 1.0.0

set -eu

CLI=""
PYTHON=""
OUTPUT=""
VERSION="0.0.0"
ICON="$(cd "$(dirname "$0")/.." && pwd)/src/datalink_scanner/resources/DataLinkScanner.icns"
BUNDLE_ID="org.davidhohnholt.datalink-scanner"

while [ $# -gt 0 ]; do
  case "$1" in
    --cli) CLI="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$CLI" ] || { echo "--cli is required" >&2; exit 2; }
[ -n "$OUTPUT" ] || { echo "--output is required" >&2; exit 2; }

APP="$OUTPUT/DataLink Scanner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DataLink Scanner</string>
  <key>CFBundleDisplayName</key><string>DataLink Scanner</string>
  <key>CFBundleExecutable</key><string>DataLink Scanner</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>DataLinkScanner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# macOS decides an app's name, Dock tile and icon from the bundle enclosing the
# running executable. Exec'ing the interpreter outside this bundle therefore
# gets us Python's identity: the Dock reads "Python".
#
# A framework build's bin/python3.x is itself a stub that re-execs
# Resources/Python.app/Contents/MacOS/Python, so copying that stub is not
# enough — copy the inner binary, and run it from inside this bundle.
RUNTIME=""
SITE=""
if [ -n "$PYTHON" ] && [ -x "$PYTHON" ]; then
  RUNTIME=$("$PYTHON" -c 'import os,sys; p=os.path.join(sys.base_prefix,"Resources","Python.app","Contents","MacOS","Python"); print(p if os.path.exists(p) else "")')
  SITE=$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
fi

if [ -n "$RUNTIME" ]; then
  cp "$RUNTIME" "$APP/Contents/MacOS/python-runtime"
  chmod +x "$APP/Contents/MacOS/python-runtime"
  cat > "$APP/Contents/MacOS/DataLink Scanner" <<LAUNCHER
#!/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
# Bypassing the virtualenv's own python means its site-packages is not set up
# for us. addsitedir rather than PYTHONPATH, because only the former processes
# the .pth files that editable and namespace installs rely on. The path goes
# through the environment so no quoting in it can break this script.
DATALINK_SITE="$SITE"
export DATALINK_SITE
exec "\$DIR/python-runtime" -c 'import os, site; site.addsitedir(os.environ["DATALINK_SITE"]); from datalink_scanner.cli import main; raise SystemExit(main(["app"]))'
LAUNCHER
else
  # No framework build to borrow: fall back to the installed command. The app
  # still works; it just shows up as Python.
  cat > "$APP/Contents/MacOS/DataLink Scanner" <<LAUNCHER
#!/bin/sh
if [ ! -x "$CLI" ]; then
  /usr/bin/osascript -e 'display alert "DataLink Scanner is not installed" message "The datalink-scanner command is missing. Reinstall with: brew reinstall datalink-scanner" as critical'
  exit 1
fi
exec "$CLI" app "\$@"
LAUNCHER
fi
chmod +x "$APP/Contents/MacOS/DataLink Scanner"

if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/DataLinkScanner.icns"
fi

# Ad-hoc signature. Nothing here is downloaded, so this is not what gets the
# app past Gatekeeper — it just keeps macOS from treating the bundle as
# damaged after the files are written.
/usr/bin/codesign --force --sign - "$APP" 2>/dev/null || true

echo "$APP"
