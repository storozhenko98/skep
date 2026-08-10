#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MACOS_ROOT="$REPOSITORY_ROOT/apps/macos"
APP_ROOT="$REPOSITORY_ROOT/artifacts/Skep.app"
UPDATE_ROOT="$REPOSITORY_ROOT/artifacts/updates"
APP_VERSION=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/VERSION")
BUILD_NUMBER=$(tr -d '[:space:]' <"$REPOSITORY_ROOT/BUILD_NUMBER")
ARCHIVE_NAME="Skep-$APP_VERSION-$BUILD_NUMBER-macOS-arm64.zip"
ARCHIVE_PATH="$UPDATE_ROOT/$ARCHIVE_NAME"
SPARKLE_ROOT="$MACOS_ROOT/.build/artifacts/sparkle/Sparkle"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
GENERATE_KEYS="$SPARKLE_ROOT/bin/generate_keys"
DOWNLOAD_URL=${SKEP_DOWNLOAD_URL:-https://skep-compute.vercel.app/downloads}
PRODUCT_URL=${SKEP_PRODUCT_URL:-https://skep-compute.vercel.app}
CODESIGN_IDENTITY=${SKEP_CODESIGN_IDENTITY:--}
NOTARY_PROFILE=${SKEP_NOTARY_PROFILE:-}
APPCAST_ONLY=${SKEP_APPCAST_ONLY:-0}
REBUILD_APPCAST=${SKEP_REBUILD_APPCAST:-0}

install -d -m 0755 "$UPDATE_ROOT"
if [ "$APPCAST_ONLY" = "1" ]; then
  if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Cannot regenerate the appcast because $ARCHIVE_PATH does not exist." >&2
    exit 1
  fi
else
  "$SCRIPT_DIR/package-macos.sh"
  rm -f "$ARCHIVE_PATH"

  if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$CODESIGN_IDENTITY" = "-" ]; then
      echo "SKEP_NOTARY_PROFILE requires a Developer ID identity in SKEP_CODESIGN_IDENTITY." >&2
      exit 1
    fi
    NOTARY_DIR=$(mktemp -d -t skep-notary)
    NOTARY_ARCHIVE="$NOTARY_DIR/Skep.zip"
    NOTARY_RESULT="$NOTARY_DIR/result.json"
    cleanup_notary() { rm -f "$NOTARY_ARCHIVE" "$NOTARY_RESULT"; rmdir "$NOTARY_DIR"; }
    trap cleanup_notary EXIT HUP INT TERM
    ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$NOTARY_ARCHIVE"
    xcrun notarytool submit "$NOTARY_ARCHIVE" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json >"$NOTARY_RESULT"
    NOTARY_STATUS=$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)
    if [ "$NOTARY_STATUS" != "Accepted" ]; then
      cat "$NOTARY_RESULT" >&2
      echo "Apple notarization did not accept the release." >&2
      exit 1
    fi
    xcrun stapler staple "$APP_ROOT"
    xcrun stapler validate "$APP_ROOT"
    cleanup_notary
    trap - EXIT HUP INT TERM
  fi

  ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$ARCHIVE_PATH"
  "$SCRIPT_DIR/package-dmg.sh"
fi

install -m 0644 "$REPOSITORY_ROOT/docs/releases/$APP_VERSION.md" "$UPDATE_ROOT/$ARCHIVE_NAME.md"

if [ ! -x "$GENERATE_APPCAST" ] || [ ! -x "$GENERATE_KEYS" ]; then
  echo "Sparkle's generate_appcast tool is unavailable; run swift package resolve in apps/macos." >&2
  exit 1
fi

TEMPORARY_KEY_DIR=$(mktemp -d -t skep-sparkle-key)
chmod 0700 "$TEMPORARY_KEY_DIR"
TEMPORARY_KEY="$TEMPORARY_KEY_DIR/private-key"
cleanup_key() { rm -f "$TEMPORARY_KEY"; rmdir "$TEMPORARY_KEY_DIR"; }
trap cleanup_key EXIT HUP INT TERM
"$GENERATE_KEYS" --account com.storozhenko.skep -x "$TEMPORARY_KEY"

if [ "$REBUILD_APPCAST" = "1" ]; then
  rm -f "$UPDATE_ROOT/appcast.xml"
fi

"$GENERATE_APPCAST" \
  --ed-key-file "$TEMPORARY_KEY" \
  --download-url-prefix "$DOWNLOAD_URL/" \
  --release-notes-url-prefix "$DOWNLOAD_URL/" \
  --link "$PRODUCT_URL" \
  --embed-release-notes \
  --maximum-versions 5 \
  --maximum-deltas 0 \
  -o "$UPDATE_ROOT/appcast.xml" \
  "$UPDATE_ROOT"
cleanup_key
trap - EXIT HUP INT TERM

(
  cd "$UPDATE_ROOT"
  LC_ALL=C LANG=C shasum -a 256 Skep-*-macOS-arm64.zip appcast.xml >SHA256SUMS
)

echo "Packaged release $ARCHIVE_PATH"
echo "Packaged installer $REPOSITORY_ROOT/artifacts/distribution/Skep-$APP_VERSION-$BUILD_NUMBER-macOS-arm64.dmg"
echo "Generated Sparkle feed $UPDATE_ROOT/appcast.xml"
