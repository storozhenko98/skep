#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

command -v cargo-about >/dev/null 2>&1 || {
  echo "cargo-about 0.9.1 is required; install it with 'cargo install --locked --version 0.9.1 --features cli cargo-about'." >&2
  exit 1
}

cd "$REPOSITORY_ROOT"
cargo about generate --locked --fail \
  -o "$REPOSITORY_ROOT/RUST_THIRD_PARTY_LICENSES.html" \
  "$REPOSITORY_ROOT/about.hbs"
LC_ALL=C LANG=C perl -pi -e 's/[ \t]+$//' \
  "$REPOSITORY_ROOT/RUST_THIRD_PARTY_LICENSES.html"

echo "Generated $REPOSITORY_ROOT/RUST_THIRD_PARTY_LICENSES.html"
