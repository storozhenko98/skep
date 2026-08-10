#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MACOS_ROOT="$REPOSITORY_ROOT/apps/macos"
APP_ROOT="$REPOSITORY_ROOT/artifacts/Skep.app"
CONTENTS="$APP_ROOT/Contents"
BUILD_ROOT="$MACOS_ROOT/.build/arm64-apple-macosx/release"
APP_VERSION=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/VERSION")
BUILD_NUMBER=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/BUILD_NUMBER")
ICON_NAME="Skep-$BUILD_NUMBER.icns"
UPDATE_FEED_URL=${SKEP_UPDATE_FEED_URL:-https://skep-compute.vercel.app/updates/appcast.xml}
CODESIGN_IDENTITY=${SKEP_CODESIGN_IDENTITY:--}

"$SCRIPT_DIR/build-icon-assets.sh"

if [ ! -d "$MACOS_ROOT/Frameworks/GhosttyKit.xcframework" ]; then
  "$SCRIPT_DIR/build-ghostty-framework.sh"
fi

"$SCRIPT_DIR/build-linux-host-payload.sh"
"$SCRIPT_DIR/build-local-host-payload.sh"

(
  cd "$MACOS_ROOT"
  swift test
  swift build -c release
)

rm -rf "$APP_ROOT"
install -d -m 0755 "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
install -m 0755 "$BUILD_ROOT/Skep" "$CONTENTS/MacOS/Skep"
install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/Skep"
install -m 0644 "$MACOS_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 0644 "$MACOS_ROOT/Resources/Skep.icns" "$CONTENTS/Resources/$ICON_NAME"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName ${ICON_NAME%.icns}" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $UPDATE_FEED_URL" "$CONTENTS/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
install -m 0644 "$REPOSITORY_ROOT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
install -m 0644 "$REPOSITORY_ROOT/RUST_THIRD_PARTY_LICENSES.html" "$CONTENTS/Resources/RUST_THIRD_PARTY_LICENSES.html"
ditto "$REPOSITORY_ROOT/artifacts/host-installer" "$CONTENTS/Resources/HostInstaller"
ditto "$REPOSITORY_ROOT/artifacts/local-host-installer" "$CONTENTS/Resources/LocalHostInstaller"
ditto "$BUILD_ROOT/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$CONTENTS/Resources/LocalHostInstaller/skepctl"
  codesign --force --sign - "$CONTENTS/Resources/LocalHostInstaller/skepd"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$CONTENTS/Resources/LocalHostInstaller/skepctl"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$CONTENTS/Resources/LocalHostInstaller/skepd"
fi
(
  cd "$CONTENTS/Resources/LocalHostInstaller"
  LC_ALL=C LANG=C shasum -a 256 skepd skepctl >SHA256SUMS
)
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$CONTENTS/Frameworks/Sparkle.framework"
  codesign --force --sign - "$APP_ROOT"
else
  codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$CONTENTS/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_ROOT"
fi
codesign --verify --deep --strict "$APP_ROOT"

echo "Packaged $APP_ROOT"
