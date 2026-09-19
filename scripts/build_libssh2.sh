#!/usr/bin/env bash
set -euo pipefail

# Usage: build_libssh2.sh [tag] [commit_sha]
# If tag is provided, that tag is cloned/checked out (the caller no longer
# needs to sed-patch this script). If commit_sha is also provided, the source
# is checked out at that exact commit for auditable, reproducible builds.
TAG="${1:-}"
COMMIT_SHA="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/src/libssh2"
BUILD="$ROOT/ThirdParty/build/libssh2_macos15"
INSTALL="$ROOT/ThirdParty"

mkdir -p "$ROOT/ThirdParty/src" "$BUILD" "$INSTALL"

if [[ ! -d "$SRC" ]]; then
  if [[ -n "$TAG" ]]; then
    git clone --branch "$TAG" https://github.com/libssh2/libssh2.git "$SRC"
  else
    git clone https://github.com/libssh2/libssh2.git "$SRC"
  fi
else
  git -C "$SRC" fetch --tags origin >/dev/null 2>&1 || true
fi

if [[ -n "$COMMIT_SHA" ]]; then
  git -C "$SRC" checkout --detach "$COMMIT_SHA"
  ACTUAL_SHA="$(git -C "$SRC" rev-parse HEAD)"
  if [[ "$ACTUAL_SHA" != "$COMMIT_SHA" ]]; then
    echo "ERROR: checkout returned $ACTUAL_SHA, expected $COMMIT_SHA" >&2
    exit 1
  fi
fi

cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCRYPTO_BACKEND=OpenSSL \
  -DOPENSSL_ROOT_DIR="$INSTALL" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON

cmake --build "$BUILD" --config Release -j"$(sysctl -n hw.ncpu)"
cmake --install "$BUILD"

echo "libssh2 installed to $INSTALL"
