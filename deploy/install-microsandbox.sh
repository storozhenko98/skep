#!/bin/sh
set -eu

VERSION=v0.6.8
BUNDLE=microsandbox-linux-x86_64.tar.gz
EXPECTED_SHA256=992be66ce8a61965b3ac7733bce58d6a98a8292a172e85c8751074a2ad16f69d
INSTALL_ROOT=/var/lib/skep/microsandbox
BASE_URL="https://github.com/superradcompany/microsandbox/releases/download/$VERSION"

if [ "$(id -u)" -ne 0 ]; then
  echo "install-microsandbox.sh must run as root" >&2
  exit 1
fi

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "the Skep MVP currently supports the Linux x86_64 Microsandbox bundle" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

TEMP_ROOT=$(mktemp -d /tmp/skep-msb-install.XXXXXX)
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

curl -fsSL "$BASE_URL/$BUNDLE" -o "$TEMP_ROOT/$BUNDLE"
ACTUAL_SHA256=$(sha256sum "$TEMP_ROOT/$BUNDLE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "Microsandbox checksum mismatch for $BUNDLE" >&2
  exit 1
fi

tar -xzf "$TEMP_ROOT/$BUNDLE" -C "$TEMP_ROOT"
install -d -m 0755 "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib"
install -m 0755 "$TEMP_ROOT/msb" "$INSTALL_ROOT/bin/msb"
install -m 0644 "$TEMP_ROOT/libkrunfw.so.5.6.1" "$INSTALL_ROOT/lib/libkrunfw.so.5.6.1"
ln -sfn msb "$INSTALL_ROOT/bin/microsandbox"
ln -sfn libkrunfw.so.5.6.1 "$INSTALL_ROOT/lib/libkrunfw.so.5"
ln -sfn libkrunfw.so.5 "$INSTALL_ROOT/lib/libkrunfw.so"

INSTALLED_VERSION=$(MSB_HOME="$INSTALL_ROOT" "$INSTALL_ROOT/bin/msb" --version)
if [ "$INSTALLED_VERSION" != "msb 0.6.8" ]; then
  echo "unexpected Microsandbox version: $INSTALLED_VERSION" >&2
  exit 1
fi

echo "Installed $INSTALLED_VERSION into $INSTALL_ROOT"
