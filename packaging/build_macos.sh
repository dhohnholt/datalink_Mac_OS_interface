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
# The oldest macOS this build may require. Used both to compile the Keychain
# helper and, below, to refuse a bundle that asks for something newer.
OLDEST_SUPPORTED="${DATALINK_MIN_MACOS:-13.0}"

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
# Read from the source rather than by importing: .venv-dmg holds a
# non-editable install, so importing reported whatever version it was built
# from and stamped the disk image with a stale number.
VERSION=$(/usr/bin/sed -n 's/^__version__ = "\(.*\)"/\1/p' \
  "$PROJECT_DIR/src/datalink_scanner/__init__.py")
INFO_PLIST="$DIST_DIR/$APP_NAME.app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $VERSION" "$INFO_PLIST"
done

# The Keychain records which program may read an item by file path, and
# notices when the bytes there change — so the .app itself can never stay
# trusted across an update. This little program is copied out to a fixed path
# on first use and trusted once. See packaging/keychain_helper.c.
KEYCHAIN_HELPER="$DIST_DIR/$APP_NAME.app/Contents/Helpers/keychain-helper"
/bin/mkdir -p "$(/usr/bin/dirname "$KEYCHAIN_HELPER")"
/usr/bin/clang -arch "$ARCH" -mmacosx-version-min="$OLDEST_SUPPORTED" -O2   -Wall -Wno-deprecated-declarations   -framework Security -framework CoreFoundation   -o "$KEYCHAIN_HELPER" "$PACKAGING_DIR/keychain_helper.c"
/usr/bin/codesign --force --sign - "$KEYCHAIN_HELPER"

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

# ---------------------------------------------------------------- signing
#
# With a Developer ID certificate the app is signed for real and notarized,
# and it opens by double-clicking like anything else. Without one it falls
# back to an ad-hoc signature, which still runs but makes macOS demand a
# Control-click on the first launch — see packaging/INSTALL.md.
#
# DATALINK_SIGN_IDENTITY names the certificate; the default is whatever
# Developer ID Application certificate this Mac holds.
APP="$DIST_DIR/$APP_NAME.app"
ENTITLEMENTS="$PACKAGING_DIR/entitlements.plist"
SIGN_IDENTITY="${DATALINK_SIGN_IDENTITY:-$(
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null     | /usr/bin/sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1
)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing as $SIGN_IDENTITY"
  # Inner-out. --deep is deprecated and, more to the point, wrong here: it
  # applies one set of entitlements to everything it touches and signs
  # nested code in an order Apple does not guarantee. Every Mach-O gets its
  # own signature first, then the bundle that contains them.
  #
  # --timestamp contacts Apple's timestamp server, so signing needs the
  # network. Without it the signature expires with the certificate.
  /usr/bin/find "$APP/Contents" -type f \
      \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 2>/dev/null \
    | while IFS= read -r -d '' inner; do
        # Skip anything that is not Mach-O: scripts, data, the odd text file
        # that happens to carry the executable bit.
        /usr/bin/file -b "$inner" | grep -q "Mach-O" || continue
        /usr/bin/codesign --force --timestamp --options runtime \
          --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$inner" \
          >/dev/null 2>&1 || {
            echo "Could not sign ${inner##*/Contents/}"; exit 1; }
      done || exit 1

  # The framework is a bundle in its own right and is signed as one.
  for framework in "$APP/Contents/Frameworks/"*.framework; do
    [[ -d "$framework" ]] || continue
    /usr/bin/codesign --force --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$framework"
  done

  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"

  # Verify before anything is packed: a bundle that fails here will fail
  # notarization too, and finding out now costs seconds rather than minutes.
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | tail -2
  # Read into a variable rather than piping: `grep -q` stops at the first
  # match and closes the pipe, codesign takes SIGPIPE, and `pipefail` turns
  # that into a failure — so the check reported a problem it had caused.
  SIGNED_FLAGS=$(/usr/bin/codesign -dvv "$APP" 2>&1 || true)
  if [[ "$SIGNED_FLAGS" != *"(runtime)"* ]]; then
    echo "The bundle is signed but not with the hardened runtime, which"
    echo "notarization requires. Signing must have partly failed."
    exit 1
  fi
  echo "    $(printf '%s\n' "$SIGNED_FLAGS" | /usr/bin/grep '^TeamIdentifier')"
else
  echo "==> No Developer ID certificate found; signing ad-hoc"
  echo "    macOS will ask the user to Control-click on first launch."
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

# The ticket has to be on the .app, not only on the image. Stapling the image
# covers downloading it; it does not cover the app after it has been dragged
# to /Applications on a Mac that has never seen it and has no network to ask
# Apple. That is a school Mac, and this app is for school Macs — so the app
# is notarized and stapled first, and then packed.
NOTARY_PROFILE="${DATALINK_NOTARY_PROFILE:-datalink-notary}"
HAVE_NOTARY=0
if [[ -n "$SIGN_IDENTITY" ]] && /usr/bin/xcrun notarytool history \
     --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  HAVE_NOTARY=1
  echo "==> Notarizing the app — Apple usually answers within a few minutes"
  APP_ZIP="$DIST_DIR/$APP_NAME.zip"
  /bin/rm -f "$APP_ZIP"
  # ditto, not zip: it preserves the symlinks and extended attributes a
  # bundle is made of, and a zip that loses them is refused.
  /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
  if /usr/bin/xcrun notarytool submit "$APP_ZIP" \
       --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m; then
    /usr/bin/xcrun stapler staple "$APP"
  else
    echo "The app was not notarized; the image will still be signed."
  fi
  /bin/rm -f "$APP_ZIP"
fi

# ------------------------------------------------------- the .pkg installer
#
# A disk image is what a person downloads and drags. A .pkg is what a district
# deploys without anybody dragging anything, and it is the only shape the App
# Store accepts. Built from the same signed, stapled bundle so the two cannot
# drift apart.
#
# Which certificate signs it decides where it can go:
#
#   Developer ID Installer          deployable by MDM, notarized, no sandbox
#   3rd Party Mac Developer Installer   App Store, and the app must be signed
#                                       Apple Distribution with a profile
#
# With neither, an unsigned .pkg is still built. It installs, it is useful for
# testing the layout, and no one else can be asked to trust it.
PKG_PATH="$DIST_DIR/DataLink-Scanner-$VERSION.pkg"
PKG_WORK="$PROJECT_DIR/build/pkg"
/bin/rm -rf "$PKG_WORK"; /bin/mkdir -p "$PKG_WORK"

INSTALLER_IDENTITY="${DATALINK_INSTALLER_IDENTITY:-$(
  /usr/bin/security find-identity -v 2>/dev/null \
    | /usr/bin/sed -n 's/.*"\(3rd Party Mac Developer Installer:.*\)"/\1/p' | head -1
)}"
if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY="$(
    /usr/bin/security find-identity -v 2>/dev/null \
      | /usr/bin/sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p' | head -1
  )"
fi

/usr/bin/pkgbuild \
  --component "$DIST_DIR/$APP_NAME.app" \
  --install-location /Applications \
  --identifier "org.davidhohnholt.datalink-scanner" \
  --version "$VERSION" \
  "$PKG_WORK/component.pkg" >/dev/null

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  echo "==> Building the installer, signed as $INSTALLER_IDENTITY"
  /usr/bin/productbuild --package "$PKG_WORK/component.pkg" \
    --sign "$INSTALLER_IDENTITY" "$PKG_PATH" >/dev/null
else
  echo "==> Building the installer (unsigned — no installer certificate here)"
  echo "    A .pkg nobody has signed cannot be asked of anybody else."
  echo "    Create one at developer.apple.com → Certificates:"
  echo "      Developer ID Installer            for deploying it yourself"
  echo "      Mac Installer Distribution        for the App Store"
  /usr/bin/productbuild --package "$PKG_WORK/component.pkg" "$PKG_PATH" >/dev/null
fi
/bin/rm -rf "$PKG_WORK"

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

# The loose .app existed only to be copied into the disk image, and leaving it
# behind is not free: macOS registers every bundle it finds, so the build
# output showed up beside the installed app in Launchpad and the Dock as a
# second, identical DataLink Scanner. Worse, it is re-signed ad-hoc on every
# build, so launching that copy asks for the Keychain password every time.
# The .dmg is the artefact worth keeping; unpack it if the bundle is wanted.
# "$DIST_DIR/$APP_NAME" is PyInstaller's intermediate COLLECT folder — 179 MB
# that is already inside the bundle, and inside the image after that.
#
# Deleting the bundle is not quite enough: macOS notices it during the seconds
# it exists and keeps the registration after the file is gone, which is a
# ghost in Launchpad. Tell LaunchServices explicitly.
# Both copies: the one PyInstaller writes and the one staged for the image.
# Missing the staging copy left build/dmg registered after a release.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$DIST_DIR/$APP_NAME.app" 2>/dev/null || true
  "$LSREGISTER" -u "$DMG_ROOT/$APP_NAME.app" 2>/dev/null || true
fi
/bin/rm -rf "$DIST_DIR/$APP_NAME.app" "$DIST_DIR/$APP_NAME" "$DMG_ROOT"

# ----------------------------------------------------------- notarization
#
# Signing says who built it. Notarization is Apple confirming they have seen
# it and found no malware, and it is what lets the app open by double-click
# instead of demanding a Control-click. Stapling attaches that result to the
# file so it works on a Mac with no network — a school Mac, often enough.
#
# The credentials live in a keychain profile the owner stores themselves with
# `xcrun notarytool store-credentials`; nothing secret is kept in this repo
# or passed on a command line. Without the profile the disk image is still
# signed and still works, it just asks for the Control-click.
if [[ $HAVE_NOTARY -eq 1 ]]; then
  echo "==> Signing the disk image"
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

  echo "==> Notarizing — Apple usually answers within a few minutes"
  if /usr/bin/xcrun notarytool submit "$DMG_PATH" \
       --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m; then
    /usr/bin/xcrun stapler staple "$DMG_PATH"
    echo "==> Notarized and stapled, both the app and the image"
    # A signed installer is worth notarizing too; an unsigned one cannot be.
    if [[ -n "$INSTALLER_IDENTITY" && -f "$PKG_PATH" ]]; then
      echo "==> Notarizing the installer"
      if /usr/bin/xcrun notarytool submit "$PKG_PATH" \
           --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m; then
        /usr/bin/xcrun stapler staple "$PKG_PATH"
      fi
    fi
    /usr/sbin/spctl -a -vvv -t install "$DMG_PATH" 2>&1 | tail -2
  else
    echo
    echo "Notarization was refused. The disk image is signed and will still"
    echo "run, but macOS will ask for a Control-click on first launch."
    echo "Ask Apple why with:"
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
  fi
elif [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing the disk image"
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  echo
  echo "No notarization profile called '$NOTARY_PROFILE', so this build is"
  echo "signed but not notarized: macOS will ask for a Control-click on the"
  echo "first launch. Store credentials once with:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "    --apple-id <your-apple-id> --team-id <team> --password <app-specific>"
  echo "See docs/RELEASING.md."
fi

echo "Built disk image: $DMG_PATH"
[[ -f "$PKG_PATH" ]] && echo "Built installer:  $PKG_PATH"
