#!/usr/bin/env bash
set -euo pipefail

# Usage: build_awslc.sh <tag> [commit_sha]
# If commit_sha is provided, the source is checked out at that exact commit
# so the built artifact always corresponds to a recorded, auditable SHA.
VERSION="${1:-v1.73.0}"
COMMIT_SHA="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/src/awslc"
BUILD="$ROOT/ThirdParty/build/awslc_macos15"
INSTALL="$ROOT/ThirdParty"

mkdir -p "$ROOT/ThirdParty/src" "$BUILD" "$INSTALL/lib" "$INSTALL/include"

if [[ ! -d "$SRC" ]]; then
  git clone https://github.com/aws/aws-lc.git "$SRC"
else
  git -C "$SRC" fetch --tags
fi

echo "Checking out AWS-LC version $VERSION..."
if [[ -n "$COMMIT_SHA" ]]; then
  git -C "$SRC" fetch --tags origin >/dev/null 2>&1 || true
  git -C "$SRC" checkout --detach "$COMMIT_SHA"
  ACTUAL_SHA="$(git -C "$SRC" rev-parse HEAD)"
  if [[ "$ACTUAL_SHA" != "$COMMIT_SHA" ]]; then
    echo "ERROR: checkout returned $ACTUAL_SHA, expected $COMMIT_SHA" >&2
    exit 1
  fi
else
  git -C "$SRC" checkout "$VERSION"
fi
git -C "$SRC" submodule update --init --recursive || true

echo "Configuring AWS-LC with CMake..."
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=OFF

echo "Building AWS-LC..."
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"

echo "Installing AWS-LC..."
cmake --install "$BUILD"

echo "AWS-LC installation completed."
