#!/bin/bash
# Builds MicBridge.app (and the MicBridge Microphone driver inside it) with
# plain swiftc and clang; there is no Xcode project.
#
# Usage: ./build.sh [--adhoc] [--package] [--notarize]
#   --adhoc     sign ad-hoc; no keychain lookup at all (same as MICBRIDGE_SIGN_IDENTITY=-)
#   --package   also write build/MicBridge-<version>-macOS-arm64.{zip,dmg} and their .sha256
#   --notarize  notarize and staple the app and the disk image (needs Developer ID); implies --package
#
# Environment:
#   MICBRIDGE_SIGN_IDENTITY  codesign identity. Unset: the Developer ID Application
#                            identity of MICBRIDGE_TEAM_ID if this Mac has one, else ad-hoc.
#   MICBRIDGE_TEAM_ID        team whose Developer ID is looked for (default CQ4STM9Q69)
#   MICBRIDGE_NOTARY_PROFILE notarytool keychain profile (default shocrot-notary)
#   MICBRIDGE_PREVIEW=1      build "MicBridge Preview.app" (UI preview, never opens audio)
#
# Developer ID builds use the hardened runtime and a secure timestamp, for
# the app and the driver. A build whose binaries contain a /Users/ path is
# refused before signing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

ADHOC=0; PACKAGE=0; NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --adhoc) ADHOC=1 ;;
    --package) PACKAGE=1 ;;
    --notarize) NOTARIZE=1; PACKAGE=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
PREVIEW="${MICBRIDGE_PREVIEW:-0}"
if (( ADHOC && NOTARIZE )); then
  echo "--adhoc and --notarize can't be combined: notarization needs a Developer ID signature." >&2; exit 2
fi
if [ "$PREVIEW" = 1 ] && (( PACKAGE )); then
  echo "The preview build is not packaged." >&2; exit 2
fi

APP="$ROOT/MicBridge.app"
if [ "$PREVIEW" = 1 ]; then APP="$ROOT/MicBridge Preview.app"; fi
VERSION="$(grep -rh '^let bridgeVersion = ' "$ROOT/Source" | sed 's/.*"\(.*\)".*/\1/' | head -1)"
[ -n "$VERSION" ] || { echo "bridgeVersion not found" >&2; exit 1; }
# A fourth part marks a patch release ("0.7.0.1"). The marketing version
# keeps three parts; the build number stays monotonic (0.7.0 -> 70000).
SHORT_VERSION="$(echo "$VERSION" | cut -d. -f1-3)"
BUILD_NUMBER="$(echo "$VERSION" | awk -F. '{ print $1 * 1000000 + $2 * 10000 + $3 * 100 + $4 }')"

rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Every Swift file under Source/, in a stable order (subfolders allowed).
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Source" -name '*.swift' | LC_ALL=C sort)

# Source paths are written relative to the repository, so no binary carries
# the folder it was built in.
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -file-prefix-map "$ROOT=." -debug-prefix-map "$ROOT=." "${SOURCES[@]}" \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Cocoa -framework Network \
  -framework SwiftUI -framework CryptoKit -framework SystemConfiguration -framework UserNotifications -framework Security -framework ServiceManagement \
  -o "$APP/Contents/MacOS/MicBridge"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.weaveneuron.MicBridge</string>
<key>CFBundleName</key><string>MicBridge</string>
<key>CFBundleDisplayName</key><string>MicBridge</string>
<key>CFBundleExecutable</key><string>MicBridge</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSBonjourServices</key><array><string>_micbridge2._tcp</string><string>_micbridge2-pair._tcp</string></array>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>MicBridge connects your two Macs over an encrypted local network link.</string>
<key>NSMicrophoneUsageDescription</key><string>MicBridge turns on the microphone only while an app on your other Mac is listening, and turns it off right after. Nothing is recorded or saved.</string>
</dict></plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The driver's installer; the app runs it only after the user confirms.
install -m 0755 "$ROOT/Driver/install-driver.sh" "$APP/Contents/Resources/install-driver.sh"
# Localized resources: Resources/<lang>.lproj/*.strings are copied as-is,
# and Resources/*.xcstrings are compiled into every language they contain.
for lproj in "$ROOT"/Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  for strings in "$lproj"/*.strings; do plutil -lint -s "$strings"; done
  cp -R "$lproj" "$APP/Contents/Resources/"
done
for catalog in "$ROOT"/Resources/*.xcstrings; do
  [ -f "$catalog" ] || continue
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done

# The MicBridge Microphone driver (an AudioServerPlugIn, Driver/), carried
# inside the app for its installer. Building it installs nothing: only the
# user, from the app, puts it in /Library/Audio/Plug-Ins/HAL.
DRIVER="$APP/Contents/PlugIns/MicBridgeMicrophone.driver"
rm -rf "$APP/Contents/PlugIns"
mkdir -p "$DRIVER/Contents/MacOS"
xcrun clang -bundle -target arm64-apple-macos15.0 -O2 -fvisibility=hidden "-ffile-prefix-map=$ROOT=." \
  -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework CoreAudio -framework CoreFoundation \
  "$ROOT/Driver/MicBridgeMicrophone.c" -o "$DRIVER/Contents/MacOS/MicBridgeMicrophone"
# The driver has its own version (bundledDriverVersion), raised only when
# Driver/ changes, so app updates don't ask for a reinstall.
DRIVER_VERSION="$(grep -rh '^let bundledDriverVersion = ' "$ROOT/Source" | sed 's/.*"\(.*\)".*/\1/' | head -1)"
[ -n "$DRIVER_VERSION" ] || { echo "bundledDriverVersion not found" >&2; exit 1; }
DRIVER_BUILD="$(echo "$DRIVER_VERSION" | awk -F. '{ print $1 * 1000000 + $2 * 10000 + $3 * 100 + $4 }')"
sed -e "s/__SHORT_VERSION__/$(echo "$DRIVER_VERSION" | cut -d. -f1-3)/" -e "s/__BUILD_NUMBER__/$DRIVER_BUILD/" "$ROOT/Driver/Info.plist" > "$DRIVER/Contents/Info.plist"
plutil -lint -s "$DRIVER/Contents/Info.plist"
nm -gU "$DRIVER/Contents/MacOS/MicBridgeMicrophone" | grep -q ' _MicBridge_Create$' \
  || { echo "driver factory MicBridge_Create is not exported" >&2; exit 1; }

if [ "$PREVIEW" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.weaveneuron.MicBridge.Preview" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :MicBridgePreview bool true" "$APP/Contents/Info.plist"
fi
# No binary may name a home folder.
assert_no_user_paths() {
  local leaked=0 f
  while IFS= read -r -d '' f; do
    lipo -info "$f" >/dev/null 2>&1 || continue
    if strings -a "$f" | grep -qF '/Users/'; then echo "Embedded /Users/ path in $f" >&2; leaked=1; fi
  done < <(find "$1" -type f -print0)
  if (( leaked )); then echo "Refusing to sign or package: $1 contains /Users/ paths." >&2; exit 1; fi
}
assert_no_user_paths "$APP"

# Signing identity: --adhoc / MICBRIDGE_SIGN_IDENTITY, else this team's
# Developer ID Application identity if the keychain has one (read-only
# lookup), else ad-hoc.
TEAM_ID="${MICBRIDGE_TEAM_ID:-CQ4STM9Q69}"
SIGN="${MICBRIDGE_SIGN_IDENTITY:-}"
(( ADHOC )) && SIGN="-"
if [ -z "$SIGN" ]; then
  SIGN="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"\(Developer ID Application: .* (${TEAM_ID})\)\".*/\1/p" | head -1)"
fi
SIGN="${SIGN:--}"
if [[ "$SIGN" == "Developer ID Application:"* ]]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  RELEASE=1
  SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN")
else
  RELEASE=0
  SIGN_FLAGS=(--force --sign "$SIGN")
fi
# Nested code first, then the app that seals it.
codesign "${SIGN_FLAGS[@]}" "$DRIVER"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/Resources/MicBridge.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
# The bundle folder's own date is how LaunchServices, the icon cache and
# Notification Center notice a new version. Rebuilding only its contents
# left it unchanged, so they kept showing the old icon. (Not sealed by
# the signature.)
touch "$APP"
if [ "$SIGN" = "-" ]; then echo "Signed ad-hoc"; else echo "Signed with: ${SIGN%% (*}"; fi
echo "Built: $APP ($VERSION, build $BUILD_NUMBER)"

if (( NOTARIZE )) && (( ! RELEASE )); then
  echo "Notarization needs a Developer ID Application identity for team $TEAM_ID; none was used." >&2; exit 1
fi
PROFILE="${MICBRIDGE_NOTARY_PROFILE:-shocrot-notary}"
OUT="$ROOT/build"
# Submits one file and waits; stops unless Apple accepts it.
notarize() {
  local file="$1" result
  result="$(mktemp)"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$result" || true
  local id status
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo "?")"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo "no answer")"
  rm -f "$result"
  echo "Notarization of $(basename "$file"): $status (submission $id)"
  if [ "$status" != "Accepted" ]; then
    echo "See: xcrun notarytool log $id --keychain-profile $PROFILE" >&2; exit 1
  fi
}

if (( NOTARIZE )); then
  mkdir -p "$OUT"
  UPLOAD="$OUT/MicBridge-$VERSION-notarize.zip"
  rm -f "$UPLOAD"
  ditto -c -k --keepParent "$APP" "$UPLOAD"
  notarize "$UPLOAD"
  rm -f "$UPLOAD"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

if (( PACKAGE )); then
  mkdir -p "$OUT"
  ZIP="$OUT/MicBridge-$VERSION-macOS-arm64.zip"
  DMG="$OUT/MicBridge-$VERSION-macOS-arm64.dmg"
  rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
  # The signature and stapled ticket live inside the bundle; local extended
  # attributes are left out so the archive has no ._ files.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  (cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  STAGE="$(mktemp -d)"
  ditto "$APP" "$STAGE/MicBridge.app"
  ln -s /Applications "$STAGE/Applications"
  # `diskutil image` replaces `hdiutil create` from macOS 26 on.
  if diskutil image create from --help >/dev/null 2>&1; then
    if ! made="$(diskutil image create from --format UDZO --volumeName "MicBridge $VERSION" "$STAGE" "$DMG" 2>&1)"; then
      echo "$made" >&2; exit 1
    fi
  else
    hdiutil create -volname "MicBridge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  fi
  rm -rf "$STAGE"
  if (( RELEASE )); then codesign --force --timestamp --sign "$SIGN" "$DMG"; fi
  if (( NOTARIZE )); then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  fi
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
  # Check what users download: no /Users/ paths in the unpacked app.
  CHECK="$(mktemp -d)"
  ditto -xk "$ZIP" "$CHECK"
  assert_no_user_paths "$CHECK/MicBridge.app"
  rm -rf "$CHECK"
  echo "Packaged: $ZIP"
  echo "Packaged: $DMG"
  if (( ! NOTARIZE )); then
    echo "Note: not notarized; Gatekeeper blocks these on other Macs. Releases use --notarize." >&2
  fi
fi
