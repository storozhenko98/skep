#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_ROOT="$REPOSITORY_ROOT/artifacts/Skep.app"
OUTPUT_ROOT="$REPOSITORY_ROOT/artifacts/distribution"
APP_VERSION=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/VERSION")
BUILD_NUMBER=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/BUILD_NUMBER")
DMG_NAME="Skep-$APP_VERSION-$BUILD_NUMBER-macOS-arm64.dmg"
DMG_PATH="$OUTPUT_ROOT/$DMG_NAME"
CODESIGN_IDENTITY=${SKEP_CODESIGN_IDENTITY:--}
NOTARY_PROFILE=${SKEP_NOTARY_PROFILE:-}

if [ ! -d "$APP_ROOT" ]; then
  echo "Package the Skep application before creating its disk image." >&2
  exit 1
fi

install -d -m 0755 "$OUTPUT_ROOT"
STAGING_ROOT=$(mktemp -d -t skep-dmg-staging)
NOTARY_RESULT="$STAGING_ROOT/notary-result.json"
cleanup() { rm -rf "$STAGING_ROOT"; }
trap cleanup EXIT HUP INT TERM

ditto "$APP_ROOT" "$STAGING_ROOT/Skep.app"
ln -s /Applications "$STAGING_ROOT/Applications"
install -m 0644 "$REPOSITORY_ROOT/apps/macos/Resources/Skep.icns" "$STAGING_ROOT/.VolumeIcon.icns"
touch "$STAGING_ROOT/.metadata_never_index"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Skep" \
  -srcfolder "$STAGING_ROOT" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "SKEP_NOTARY_PROFILE requires a Developer ID identity in SKEP_CODESIGN_IDENTITY." >&2
    exit 1
  fi
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$NOTARY_RESULT"
  NOTARY_STATUS=$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)
  if [ "$NOTARY_STATUS" != "Accepted" ]; then
    cat "$NOTARY_RESULT" >&2
    echo "Apple notarization did not accept the disk image." >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

(
  cd "$OUTPUT_ROOT"
  LC_ALL=C LANG=C shasum -a 256 Skep-*-macOS-arm64.dmg >SHA256SUMS
)

echo "Packaged disk image $DMG_PATH"
