#!/bin/zsh
# Build the Mac App Store edition of the Flutter app.
#
# Separate from build_appstore.sh, which builds the Python edition, and from
# packaging/build_macos.sh. Different output directories, no shared state.
#
# Two modes:
#
#   ./AppStore/build_flutter_appstore.sh
#       The real thing: builds, signs with the store certificates, checks the
#       result, and writes the installer package. Needs the certificates and
#       the provisioning profile, and stops with instructions at the first thing
#       missing.
#
#   DATALINK_APPSTORE_CHECK=1 ./AppStore/build_flutter_appstore.sh
#       Everything that does not need a certificate: builds, assembles the
#       bundle, signs it ad hoc ("-", no identity involved) with the store
#       entitlements, and verifies the bundle, the entitlements and the
#       privacy manifest. Safe to run any time. Produces no package.
#
# Nothing here contains a certificate name, a team id, a profile or an API
# key. Identities are looked up in the keychain or taken from the environment.
set -euo pipefail

APPSTORE_DIR=${0:A:h}
PROJECT_DIR=${APPSTORE_DIR:h}
FLUTTER_APP="$PROJECT_DIR/app"
DIST="$APPSTORE_DIR/flutter-dist"
WORK="$APPSTORE_DIR/flutter-work"
APP_NAME="DataLink Scanner"
APP="$DIST/$APP_NAME.app"
BUILT="$FLUTTER_APP/build/macos/Build/Products/Release/$APP_NAME.app"
ENTITLEMENTS="$FLUTTER_APP/macos/Runner/Release.entitlements"
# The same App ID, and so the same profile, as the Python edition.
PROFILE="$APPSTORE_DIR/embedded.provisionprofile"
BUNDLE_ID="org.davidhohnholt.datalink-scanner"
CHECK_ONLY="${DATALINK_APPSTORE_CHECK:-}"

# pubspec.yaml: "version: 2.0.0+1" is the version and the default build number.
PUBSPEC_VERSION=$(/usr/bin/sed -n 's/^version: *//p' "$FLUTTER_APP/pubspec.yaml" | head -1)
VERSION="${PUBSPEC_VERSION%%+*}"
BUILD_NUMBER="${DATALINK_APPSTORE_BUILD_NUMBER:-${PUBSPEC_VERSION##*+}}"

# The entitlements the store build is allowed to have, and no others. A missing
# one fails quietly at run time; an extra one is something App Review asks about.
EXPECTED_ENTITLEMENTS="app-sandbox device.serial files.user-selected.read-write network.client"
FORBIDDEN_ENTITLEMENTS="get-task-allow cs.allow-jit cs.allow-unsigned-executable-memory cs.disable-library-validation network.server"

say() { print -r -- "$@"; }
stop() { say ""; say "STOPPED: $1"; say ""; say "$2"; exit 1; }
ok() { say "    ok: $1"; }

say "==> DataLink Scanner $VERSION ($BUILD_NUMBER), Flutter, App Store edition${CHECK_ONLY:+ (check only)}"

# ----------------------------------------------------------- prerequisites

command -v flutter >/dev/null || stop "flutter is not on PATH" \
  "Install the Flutter SDK, or add it to PATH, and run this again."
[[ -f "$ENTITLEMENTS" ]] || stop "no entitlements file at $ENTITLEMENTS" "It is part of the app."

APP_IDENTITY=""
INSTALLER_IDENTITY=""
if [[ -z "$CHECK_ONLY" ]]; then
  # "Apple Distribution" is the current unified certificate; "Mac App
  # Distribution" is the older one and installs as "3rd Party Mac Developer
  # Application". Either signs a store app. "Developer ID Application" does
  # not: the store refuses it.
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
  [[ -n "$APP_IDENTITY" ]] || stop "no store signing certificate on this Mac" \
"Create 'Apple Distribution' (or 'Mac App Distribution') at
developer.apple.com -> Certificates and install it, or set
DATALINK_APPSTORE_IDENTITY to its full name."

  INSTALLER_IDENTITY="${DATALINK_APPSTORE_INSTALLER:-$(
    /usr/bin/security find-identity -v 2>/dev/null \
      | /usr/bin/sed -n 's/.*"\(3rd Party Mac Developer Installer:.*\)"/\1/p' | head -1
  )}"
  [[ -n "$INSTALLER_IDENTITY" ]] || stop "no Mac Installer Distribution certificate on this Mac" \
"It signs the .pkg; the application certificate signs the app inside it. Create
one at developer.apple.com -> Certificates -> Mac Installer Distribution, or set
DATALINK_APPSTORE_INSTALLER to its full name."

  [[ -f "$PROFILE" ]] || stop "no provisioning profile at AppStore/embedded.provisionprofile" \
"Create a Mac App Store profile for the App ID $BUNDLE_ID at developer.apple.com
-> Profiles, download it, and save it to that path. It is embedded in the bundle
and the sandbox will not work without it."
fi

# ---------------------------------------------------------------- the build

say "==> Building with Flutter"
(
  cd "$FLUTTER_APP"
  flutter pub get >/dev/null
  # No --dart-define=DATALINK_DIAGNOSTICS: the headless self-tests that read
  # environment variables are compiled out of this build on purpose.
  flutter build macos --release --build-name "$VERSION" --build-number "$BUILD_NUMBER"
)
[[ -d "$BUILT" ]] || stop "the build did not produce $BUILT" "Read the Flutter output above."

/bin/rm -rf "$DIST" "$WORK"
/bin/mkdir -p "$DIST" "$WORK"
/usr/bin/ditto "$BUILT" "$APP"
INFO="$APP/Contents/Info.plist"

# Quarantine survives copies and is refused by App Store processing
# (ITMS-91109) if even one file carries it.
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
if /usr/bin/xattr -lr "$APP" 2>/dev/null | /usr/bin/grep -q 'com.apple.quarantine:'; then
  stop "the bundle still contains quarantined files" "Remove com.apple.quarantine and build again."
fi

# ----------------------------------------------------- the bundle, unsigned

say "==> Checking the bundle"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || true; }
expect_plist() {
  local got; got=$(plist "$1")
  [[ "$got" == "$2" ]] || stop "Info.plist $1 is '$got', not '$2'" "$3"
  ok "$1 = $2"
}
expect_plist CFBundleIdentifier "$BUNDLE_ID" "The bundle id must match the App ID the profile is for."
expect_plist CFBundleShortVersionString "$VERSION" "It comes from pubspec.yaml."
expect_plist CFBundleVersion "$BUILD_NUMBER" "Set DATALINK_APPSTORE_BUILD_NUMBER, or the number after + in pubspec.yaml."
expect_plist LSApplicationCategoryType "public.app-category.education" "The store refuses an upload without a category."
# The owner's export-compliance declaration for this App ID (see the Python
# edition's script). It is a legal statement, not a build setting.
expect_plist ITSAppUsesNonExemptEncryption "false" "Export compliance; see app/macos/Runner/Info.plist."
expect_plist DTPlatformName "macosx" "Xcode writes this; the build did not go through Xcode."
[[ -n "$(plist DTXcode)" && -n "$(plist DTSDKName)" ]] || stop "Info.plist has no Xcode build metadata" \
  "App Store Connect refuses a package without it. Build with Xcode via 'flutter build macos'."
ok "Xcode build metadata present"

MIN_OS=$(plist LSMinimumSystemVersion)
ok "LSMinimumSystemVersion = $MIN_OS"

[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] || stop "the app has no privacy manifest" \
  "app/macos/Runner/PrivacyInfo.xcprivacy must be in the Runner target's resources."
/usr/bin/plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
ok "privacy manifest present"

[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || stop "the app has no icon" "Fill AppIcon.appiconset."
ok "app icon present"

# Every executable file in the bundle, with what it is built for.
MACHO=()
while IFS= read -r -d '' f; do
  /usr/bin/file -b "$f" | /usr/bin/grep -q "Mach-O" && MACHO+=("$f")
done < <(/usr/bin/find "$APP/Contents" -type f -print0)
(( ${#MACHO} > 0 )) || stop "no Mach-O files found in the bundle" "Something is wrong with the build."
ARCHS_MAIN=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$APP_NAME")
for f in "${MACHO[@]}"; do
  archs=$(/usr/bin/lipo -archs "$f" 2>/dev/null || true)
  [[ "$archs" == *arm64* ]] || stop "${f##*/Contents/} has no arm64 code ($archs)" \
    "Every binary must run on Apple silicon."
  if [[ "$ARCHS_MAIN" == *x86_64* && "$archs" != *x86_64* ]]; then
    stop "${f##*/Contents/} is $archs but the app is universal" \
      "Either every binary is universal or none is; Intel Macs would crash on this one."
  fi
done
ok "${#MACHO} binaries, all $ARCHS_MAIN"
if [[ "$ARCHS_MAIN" != *x86_64* && "${MIN_OS%%.*}" -lt 12 ]]; then
  stop "arm64 only, but the deployment target is $MIN_OS" "Apple needs 12.0 or higher for arm64-only (ITMS-90869)."
fi

# Executables other than the app itself would need the sandbox entitlements of
# their own; the Flutter app has none, and one appearing deserves a look.
for f in "${MACHO[@]}"; do
  [[ "$f" == "$APP/Contents/MacOS/$APP_NAME" ]] && continue
  /usr/bin/file -b "$f" | /usr/bin/grep -q "executable" && stop "unexpected executable ${f##*/Contents/}" \
    "A helper tool must be signed with its own sandbox entitlements; decide that deliberately."
done
ok "no helper executables"

# ----------------------------------------------------------------- signing

if [[ -n "$CHECK_ONLY" ]]; then
  SIGN_ID="-"
  TIMESTAMP="--timestamp=none"
  # The hardened runtime makes macOS refuse to load a framework signed by a
  # different team, and an ad hoc signature has no team at all, so the app
  # would not start. The real build signs everything with one certificate and
  # does use it.
  RUNTIME=""
  say "==> Signing ad hoc, to check the entitlements (no certificate involved)"
else
  SIGN_ID="$APP_IDENTITY"
  TIMESTAMP="--timestamp"
  RUNTIME="--options runtime"
  /bin/cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  say "==> Signing as $APP_IDENTITY"
fi

APP_ENTITLEMENTS="$ENTITLEMENTS"
if [[ -z "$CHECK_ONLY" ]]; then
  # The profile names an application identifier and the signature must carry
  # the same one, or the build is not eligible for TestFlight (ITMS-90886).
  # The team prefix is read from the certificate. Written into a scratch copy
  # only, never into the repository.
  #
  # It is an either/or: with the identifier the build validates cleanly but
  # will NOT open on this Mac (a store profile provisions no devices); without
  # it the build opens here but validation warns that TestFlight is
  # unavailable. The default is the one you upload; set
  # DATALINK_APPSTORE_TESTABLE=1 for a copy you can open.
  TEAM_ID=$(print -r -- "$APP_IDENTITY" | /usr/bin/sed -n 's/.*(\(.*\))$/\1/p')
  [[ -n "$TEAM_ID" ]] || stop "could not read the team id from the certificate name" \
    "The name should end with the team id in brackets."
  if [[ -z "${DATALINK_APPSTORE_TESTABLE:-}" ]]; then
    APP_ENTITLEMENTS="$WORK/entitlements-signing.plist"
    /bin/cp "$ENTITLEMENTS" "$APP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$APP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$APP_ENTITLEMENTS"
  else
    say "    TESTABLE build: no application identifier, so it opens on this Mac. Do not upload it."
  fi
fi

sign() { /usr/bin/codesign --force $TIMESTAMP ${=RUNTIME} "$@" --sign "$SIGN_ID" >/dev/null; }

# Inside out: loose libraries, then frameworks, then resource bundles, then the
# app. Nothing nested carries entitlements; only the app is sandboxed.
for f in "${MACHO[@]}"; do
  case "$f" in
    "$APP/Contents/MacOS/$APP_NAME") ;;
    */Frameworks/*.framework/*) ;;
    *) sign "$f" ;;
  esac
done
for framework in "$APP/Contents/Frameworks/"*.framework(N); do
  sign "$framework"
done
for bundle in "$APP/Contents/Resources/"*.bundle(N); do
  sign "$bundle"
done
sign --entitlements "$APP_ENTITLEMENTS" "$APP"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | tail -2

# ---------------------------------------------------------- the entitlements

# `--entitlements :-` writes real XML; without the colon codesign prints a
# human-readable dump nothing can parse.
SIGNED=$(/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null)
ACTUAL=$(print -r -- "$SIGNED" | /usr/bin/python3 -c 'import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
print(" ".join(sorted(k.removeprefix("com.apple.security.") for k, v in d.items() if v is True)))')
if [[ "$ACTUAL" != "$EXPECTED_ENTITLEMENTS" ]]; then
  stop "the signed bundle does not carry the entitlements it should" \
"  expected: $EXPECTED_ENTITLEMENTS
  actual:   $ACTUAL"
fi
ok "entitlements are exactly: $ACTUAL"
for forbidden in ${=FORBIDDEN_ENTITLEMENTS}; do
  print -r -- "$SIGNED" | /usr/bin/grep -q "com.apple.security.$forbidden" \
    && stop "the signed bundle carries $forbidden" "The store build must not."
done
ok "none of: $FORBIDDEN_ENTITLEMENTS"

# The build must not be able to listen. The entitlement is absent, so this is
# belt and braces: no listening socket call in the Dart we wrote.
if /usr/bin/grep -rnE "ServerSocket|HttpServer|RawDatagramSocket" "$FLUTTER_APP/lib" "$PROJECT_DIR/packages"/*/lib >/dev/null 2>&1; then
  stop "the source opens a listening socket" "Find it with grep for ServerSocket and HttpServer."
fi
ok "no listening sockets in the source"

# The headless self-tests are compiled out; their environment variable names
# must not appear in the shipped app.
if /usr/bin/strings -a "$APP/Contents/Frameworks/App.framework/Versions/A/App" | /usr/bin/grep -q "DATALINK_NETWORK_SELFTEST"; then
  stop "the diagnostics are compiled into this build" "Build without --dart-define=DATALINK_DIAGNOSTICS."
fi
ok "diagnostics compiled out"

if [[ -n "$CHECK_ONLY" ]]; then
  # Does it start, sandboxed, with only these entitlements? Run the signed
  # copy for a few seconds (a window appears briefly) and make sure it is
  # still alive.
  say "==> Starting the signed copy"
  "$APP/Contents/MacOS/$APP_NAME" >"$WORK/launch.log" 2>&1 &
  LAUNCHED=$!
  sleep 6
  if kill -0 $LAUNCHED 2>/dev/null; then
    ok "still running after 6 seconds"
    kill $LAUNCHED 2>/dev/null || true
    wait $LAUNCHED 2>/dev/null || true
  else
    stop "the signed app exited within 6 seconds" "$(/usr/bin/tail -5 "$WORK/launch.log")"
  fi
  say ""
  say "Check passed. Nothing was signed with a certificate and no package was made."
  say "Checked bundle: $APP"
  exit 0
fi

# -------------------------------------------------------------- the package

if [[ -n "${DATALINK_APPSTORE_TESTABLE:-}" ]]; then
  PKG="$DIST/DataLink-Scanner-$VERSION-flutter-appstore-TESTABLE-DO-NOT-UPLOAD.pkg"
else
  PKG="$DIST/DataLink-Scanner-$VERSION-flutter-appstore.pkg"
fi
say "==> Building the installer, signed as $INSTALLER_IDENTITY"
/usr/bin/productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null

say ""
say "Built: $PKG"
say "Version: $VERSION ($BUILD_NUMBER)"
say ""
say "DO NOT INSTALL THIS PACKAGE ON THIS MACHINE. It installs to /Applications,"
say "where DataLink Scanner.app may be a symlink into the Homebrew Cellar, and the"
say "installer follows it as root and replaces the everyday app. That happened"
say "once already. Recover with: brew reinstall datalink-scanner"
say ""
say "The upload build will not open here, by design (see the comment above on"
say "the application identifier). For a copy you can open:"
say "  DATALINK_APPSTORE_TESTABLE=1 ./AppStore/build_flutter_appstore.sh"
say ""
say "Not notarized and does not need to be: App Store Connect does that in review."
say "Upload with Transporter or iTMSTransporter and your own App Store Connect API key."
