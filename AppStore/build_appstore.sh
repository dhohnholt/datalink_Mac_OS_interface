#!/bin/zsh
# Build the Mac App Store edition.
#
# Deliberately separate from packaging/build_macos.sh. That script produces
# the notarized Developer ID disk image people download today, it works, and
# nothing here is allowed to disturb it: different output directory, different
# entitlements, different certificates, no shared state.
#
# This will stop with a clear message at the first thing that is missing. It
# is meant to be run repeatedly while the work in PLAN.md is done.
set -euo pipefail

APPSTORE_DIR=${0:A:h}
PROJECT_DIR=${APPSTORE_DIR:h}
DIST="$APPSTORE_DIR/dist"
WORK="$APPSTORE_DIR/build"
APP_NAME="DataLink Scanner"
APP="$DIST/$APP_NAME.app"
ENTITLEMENTS="$APPSTORE_DIR/entitlements.plist"
PROFILE="$APPSTORE_DIR/embedded.provisionprofile"

VERSION=$(/usr/bin/sed -n 's/^__version__ = "\(.*\)"/\1/p' \
  "$PROJECT_DIR/src/datalink_scanner/__init__.py")

say() { print -r -- "$@"; }
stop() { say ""; say "STOPPED: $1"; say ""; say "$2"; exit 1; }

say "==> DataLink Scanner $VERSION, App Store edition"

# ------------------------------------------------------------ prerequisites

# Two certificates can sign a Mac app for the store and they are equivalent
# here. "Apple Distribution" is the current unified type, one certificate for
# every platform. "Mac App Distribution" is the older macOS-only one and
# installs under its legacy keychain name, "3rd Party Mac Developer
# Application". Either is accepted; whichever is present is used.
APP_IDENTITY="${DATALINK_APPSTORE_IDENTITY:-$(
  /usr/bin/security find-identity -v 2>/dev/null \
    | /usr/bin/sed -n 's/.*"\(Apple Distribution:.*\)"/\1/p' | head -1
)}"
if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY="$(
    /usr/bin/security find-identity -v 2>/dev/null \
      | /usr/bin/sed -n 's/.*"\(3rd Party Mac Developer Application:.*\)"/\1/p' | head -1
  )"
fi
[[ -n "$APP_IDENTITY" ]] || stop \
  "no store signing certificate on this Mac" \
  "Create either at developer.apple.com -> Certificates, download it and
double-click to install:

  Apple Distribution      one certificate for every platform (recommended)
  Mac App Distribution    macOS only; installs as '3rd Party Mac Developer
                          Application'

Both are accepted here. 'Developer ID Application', which this Mac does have,
signs apps for distribution OUTSIDE the store and the store will refuse it."

INSTALLER_IDENTITY="${DATALINK_APPSTORE_INSTALLER:-$(
  /usr/bin/security find-identity -v 2>/dev/null \
    | /usr/bin/sed -n 's/.*"\(3rd Party Mac Developer Installer:.*\)"/\1/p' | head -1
)}"
[[ -n "$INSTALLER_IDENTITY" ]] || stop \
  "no Mac Installer Distribution certificate on this Mac" \
  "Create one at developer.apple.com -> Certificates -> Mac Installer
Distribution. It signs the .pkg; the Apple Distribution certificate signs
the app inside it. Both are needed."

[[ -f "$PROFILE" ]] || stop \
  "no provisioning profile at AppStore/embedded.provisionprofile" \
  "Create a Mac App Store provisioning profile for the App ID
org.davidhohnholt.datalink-scanner at developer.apple.com -> Profiles,
download it, and save it to that exact path. It is embedded in the bundle
and the sandbox will not work without it."

# --------------------------------------------------------------- the bundle

PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv-dmg/bin/python}"
[[ -x "$PYTHON_BIN" ]] || stop \
  "no Python to build with at $PYTHON_BIN" \
  "See docs/RELEASING.md. The store edition uses the same python.org build as
the disk image, so the deployment target stays low."

# The store edition may not install anything at runtime, so OpenCV, NumPy and
# Pillow are collected into the bundle instead. This is what makes
# disable-library-validation unnecessary: they become part of a bundle signed
# by one team. See PLAN.md step 2.
"$PYTHON_BIN" -c "import cv2, numpy, PIL" 2>/dev/null || stop \
  "the reader's libraries are not importable by $PYTHON_BIN" \
  "The store edition bundles them rather than installing them at runtime:
  $PYTHON_BIN -m pip install opencv-python-headless numpy Pillow"

/bin/rm -rf "$WORK" "$APP"
/bin/mkdir -p "$DIST" "$WORK"

say "==> Building the bundle"
"$PYTHON_BIN" -m PyInstaller \
  --noconfirm --clean --windowed \
  --name "$APP_NAME" \
  --icon "$PROJECT_DIR/src/datalink_scanner/resources/DataLinkScanner.icns" \
  --osx-bundle-identifier "org.davidhohnholt.datalink-scanner" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/webui:web" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/resources:datalink_scanner/resources" \
  --paths "$PROJECT_DIR/src" \
  --paths "$PROJECT_DIR/src/datalink_scanner/vendor" \
  --paths "$PROJECT_DIR/src/datalink_scanner/vendor/omr" \
  --add-data "$PROJECT_DIR/src/datalink_scanner/vendor/omr/reference_page.png:." \
  --hidden-import serial --hidden-import WebKit \
  --collect-all cv2 --collect-all numpy --collect-all PIL \
  --hidden-import analyze_exam --hidden-import calibrate_page \
  --hidden-import extract_template_a --hidden-import page_selection \
  --hidden-import analysis_core --hidden-import result_schema \
  --distpath "$DIST" --workpath "$WORK" --specpath "$WORK" \
  "$PROJECT_DIR/packaging/pyinstaller_entry.py"

INFO="$APP/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $VERSION" "$INFO" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $VERSION" "$INFO"
done
# The store requires a category; without it the upload is refused.
/usr/libexec/PlistBuddy -c "Set :LSApplicationCategoryType public.app-category.education" "$INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.education" "$INFO"

/bin/cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# The paper pipeline shells out to pdftoppm and pdfinfo, which must travel
# inside the bundle and be signed with it.
if [[ -z "${DATALINK_POPPLER_PREFIX:-}" && -x "$PROJECT_DIR/.poppler-prefix/bin/pdftoppm" ]]; then
  export DATALINK_POPPLER_PREFIX="$PROJECT_DIR/.poppler-prefix"
fi
"$PYTHON_BIN" "$PROJECT_DIR/packaging/bundle_poppler.py" "$APP"

# ---------------------------------------------------------------- signing

say "==> Signing as $APP_IDENTITY"
# Inner-out, as in packaging/build_macos.sh, and for the same reasons.
/usr/bin/find "$APP/Contents" -type f \
    \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 2>/dev/null \
  | while IFS= read -r -d '' inner; do
      /usr/bin/file -b "$inner" | grep -q "Mach-O" || continue
      /usr/bin/codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$inner" \
        >/dev/null 2>&1 || { say "could not sign ${inner##*/Contents/}"; exit 1; }
    done || exit 1

for framework in "$APP/Contents/Frameworks/"*.framework; do
  [[ -d "$framework" ]] || continue
  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$framework"
done

/usr/bin/codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | tail -2
SANDBOXED=$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | /usr/bin/plutil -extract com.apple.security.app-sandbox raw -o - - 2>/dev/null || true)
[[ "$SANDBOXED" == "true" ]] || stop \
  "the signed bundle is not sandboxed" \
  "The store will refuse it. Check AppStore/entitlements.plist was applied."

# -------------------------------------------------------------- the package

PKG="$DIST/DataLink-Scanner-$VERSION-appstore.pkg"
say "==> Building the installer, signed as $INSTALLER_IDENTITY"
/usr/bin/productbuild --component "$APP" /Applications \
  --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null

say ""
say "Built: $PKG"
say ""
say "Validate and upload with the credentials already in the keychain:"
say "  xcrun notarytool history --keychain-profile datalink-notary   # same key"
say "  /Applications/Transporter.app/Contents/itms/bin/iTMSTransporter \\"
say "    -m upload -assetFile \"$PKG\" \\"
say "    -apiKey KFBHF6LUP5 -apiIssuer <issuer-id>"
say ""
say "Transporter wants AuthKey_KFBHF6LUP5.p8 in ~/.appstoreconnect/private_keys/."
