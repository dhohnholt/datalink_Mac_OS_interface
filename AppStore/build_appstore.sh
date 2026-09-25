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

# Xcode writes a block of build metadata that PyInstaller does not, and
# App Store Connect will not take a package without it. The first symptom is
# blunt and does not name the real problem:
#
#   ERROR: Unable to detect platform from Info.plist. Valid platforms are:
#          appletvos, ios, osx, xros.
#
# and passing --platform osx does not help, because it is the bundle that has
# to say what it is. Every value below is read from the toolchain that is
# actually doing the building rather than written down here, so it cannot
# drift when Xcode is updated.
SDK_VERSION=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(/usr/bin/xcrun --sdk macosx --show-sdk-build-version)
XCODE_VERSION=$(/usr/bin/xcodebuild -version | /usr/bin/sed -n '1s/Xcode //p')
XCODE_BUILD=$(/usr/bin/xcodebuild -version | /usr/bin/sed -n '2s/Build version //p')
MACHINE_BUILD=$(/usr/bin/sw_vers -buildVersion)
# "27.0" becomes "2700", which is the form Xcode writes.
DTXCODE=$(printf '%d%02d' "${XCODE_VERSION%%.*}" "$(print -r -- ${XCODE_VERSION#*.} | cut -d. -f1)")
# What the built executable actually requires, rather than a hopeful guess.
MIN_OS=$(/usr/bin/otool -l "$APP/Contents/MacOS/$APP_NAME" \
  | /usr/bin/awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
[[ -n "$MIN_OS" ]] || stop "could not read the deployment target from the binary" \
  "LSMinimumSystemVersion has to match what the executable was built for."

plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$INFO" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$INFO"
}
# Apple refuses an arm64 only bundle that claims to run on macOS 11:
#
#   ERROR ITMS-90869: ... supports arm64 but not Intel-based Mac computers.
#   ... To support arm64 only, your macOS deployment target must be 12.0 or
#   higher.
#
# Either ship a universal binary or say 12.0. PyInstaller here produces arm64
# only, so the floor goes up. Raising it is honest: the app does run on 12.0
# and up, and no Intel Mac can run this build at all.
if ! /usr/bin/lipo -archs "$APP/Contents/MacOS/$APP_NAME" | /usr/bin/grep -q x86_64; then
  if [[ "${MIN_OS%%.*}" -lt 12 ]]; then
    say "    arm64 only, so the deployment target goes from $MIN_OS to 12.0"
    MIN_OS=12.0
  fi
fi
plist_set LSMinimumSystemVersion "$MIN_OS"
plist_set DTPlatformName macosx
plist_set DTPlatformVersion "$SDK_VERSION"
plist_set DTSDKName "macosx$SDK_VERSION"
plist_set DTSDKBuild "$SDK_BUILD"
plist_set DTPlatformBuild "$XCODE_BUILD"
plist_set DTXcode "$DTXCODE"
plist_set DTXcodeBuild "$XCODE_BUILD"
plist_set DTCompiler com.apple.compilers.llvm.clang.1_0
plist_set BuildMachineOSBuild "$MACHINE_BUILD"
# An array, so PlistBuddy needs telling twice.
/usr/libexec/PlistBuddy -c "Delete :CFBundleSupportedPlatforms" "$INFO" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$INFO"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$INFO"

say "    built for macOS $MIN_OS and up, SDK $SDK_VERSION ($SDK_BUILD), Xcode $XCODE_VERSION"

/bin/cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# The paper pipeline shells out to pdftoppm and pdfinfo, which must travel
# inside the bundle and be signed with it.
if [[ -z "${DATALINK_POPPLER_PREFIX:-}" && -x "$PROJECT_DIR/.poppler-prefix/bin/pdftoppm" ]]; then
  export DATALINK_POPPLER_PREFIX="$PROJECT_DIR/.poppler-prefix"
fi
"$PYTHON_BIN" "$PROJECT_DIR/packaging/bundle_poppler.py" "$APP"

# ---------------------------------------------------------------- signing

# The provisioning profile names an application identifier, and the signature
# has to carry the same one or the build is not eligible for TestFlight:
#
#   WARN ITMS-90886: ... the signature for the bundle is missing an
#   application identifier but has an application identifier in the
#   provisioning profile ...
#
# The team prefix is read from the certificate rather than written down, so
# this cannot go stale if the certificate is replaced.
# This is an either/or, and there is no build that is both.
#
#   with the identifier     validates with zero warnings and is eligible for
#                           TestFlight, but WILL NOT LAUNCH on this Mac: once
#                           the signature carries it, macOS checks the
#                           embedded profile, and a Mac App Store profile
#                           provisions no devices at all. The failure is
#                           "Launchd job spawn failed", which names nothing.
#
#   without it              runs here, so it can be tested, and validates with
#                           one warning saying TestFlight is unavailable.
#
# The default is the one you upload. Set DATALINK_APPSTORE_TESTABLE=1 for a
# copy you can actually open.
TEAM_ID=$(print -r -- "$APP_IDENTITY" | /usr/bin/sed -n 's/.*(\(.*\))$/\1/p')
[[ -n "$TEAM_ID" ]] || stop "could not read the team id from $APP_IDENTITY" \
  "The signing identity should end with the team id in brackets."
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO")
SIGNING_ENTITLEMENTS="$WORK/entitlements-signing.plist"
/bin/cp "$ENTITLEMENTS" "$SIGNING_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
  "$SIGNING_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
  "$SIGNING_ENTITLEMENTS"
# Only the app itself gets the identifier. A nested binary that carries one
# without a provisioning profile of its own is the next warning along:
#
#   WARN ITMS-90885: ... the executable is missing a provisioning profile but
#   has an application identifier in its signature.
#
# so the inner passes below keep using the plain entitlements.
APP_ENTITLEMENTS="$SIGNING_ENTITLEMENTS"

if [[ -n "${DATALINK_APPSTORE_TESTABLE:-}" ]]; then
  APP_ENTITLEMENTS="$ENTITLEMENTS"
  say "==> TESTABLE build: no application identifier, so it opens on this Mac."
  say "    Upload the default build instead, not this one."
fi

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
  --entitlements "$APP_ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | tail -2
# `--entitlements :-` writes real plist XML; without the colon codesign
# prints a human-readable dump that nothing can parse. And plutil is no use
# here whatever the format, because it reads the dots in
# com.apple.security.app-sandbox as a nested key path and finds nothing.
# Check the whole set, not just the sandbox flag. A missing entitlement here
# does not fail the build or the signature: it fails silently at runtime, in a
# way that looks like the app is broken. network.client is the one that cost a
# session -- without it WKWebView cannot reach the app's own server on
# 127.0.0.1, and the window opens blank with nothing logged anywhere.
EXPECTED="app-sandbox cs.allow-unsigned-executable-memory device.serial
files.user-selected.read-write network.client network.server"
ACTUAL=$(/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null \
  | /usr/bin/python3 -c 'import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
keys = sorted(k.removeprefix("com.apple.security.") for k, v in d.items() if v is True)
print(" ".join(keys))' 2>/dev/null || true)
if [[ "$ACTUAL" != "$(print -r -- ${EXPECTED} | tr -s '[:space:]' ' ' | sed 's/ $//')" ]]; then
  stop "the signed bundle does not carry the entitlements it should" \
"  expected: $(print -r -- ${EXPECTED} | tr -s '[:space:]' ' ')
  actual:   $ACTUAL

A missing one will not show up until the app misbehaves at runtime. Note that
plutil will happily lint an entitlements file that codesign then rejects: a
double hyphen inside an XML comment is illegal and AMFI stops on it."
fi

# -------------------------------------------------------------- the package

PKG="$DIST/DataLink-Scanner-$VERSION-appstore.pkg"
say "==> Building the installer, signed as $INSTALLER_IDENTITY"
/usr/bin/productbuild --component "$APP" /Applications \
  --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null

say ""
say "Built: $PKG"
say ""
if [[ -z "${DATALINK_APPSTORE_TESTABLE:-}" ]]; then
  say "This build will NOT open on this Mac, by design: it carries the store"
  say "application identifier, and the Mac App Store profile provisions no"
  say "devices. For a copy you can open and test, build again with:"
  say "  DATALINK_APPSTORE_TESTABLE=1 ./AppStore/build_appstore.sh"
  say ""
fi
say "DO NOT INSTALL THIS PACKAGE ON THIS MACHINE. It installs to /Applications,"
say "where DataLink Scanner.app is a symlink into the Homebrew Cellar, so the"
say "installer follows it as root and replaces the working everyday app with"
say "this sandboxed one. That happened on 2026-09-25. Recover with:"
say "  brew reinstall datalink-scanner"
say ""
say "This package is not notarized and does not need to be: App Store Connect"
say "runs its own notarization during review. notarytool is only for the"
say "Developer ID disk image in packaging/build_macos.sh."
say ""
say "Upload it with:"
say "  /Applications/Transporter.app/Contents/itms/bin/iTMSTransporter \\"
say "    -m upload -assetFile \"$PKG\" \\"
say "    -apiKey KFBHF6LUP5 -apiIssuer <issuer-id>"
say ""
say "Transporter wants AuthKey_KFBHF6LUP5.p8 in ~/.appstoreconnect/private_keys/."
