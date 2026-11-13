#!/usr/bin/env bash
# Fetches libobs headers (sparse checkout) when no OBS development package is
# installed. Usage: ./scripts/fetch-obs-headers.sh [obs-version]
set -euo pipefail

VERSION="${1:-33.0.1}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/.deps/obs-studio"

if [ -f "$DEST/libobs/obs-module.h" ]; then
  echo "libobs headers already present in $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
git clone -q --depth 1 --branch "$VERSION" --filter=blob:none --sparse \
  https://github.com/obsproject/obs-studio.git "$DEST"
git -C "$DEST" sparse-checkout set libobs
echo "libobs $VERSION headers fetched into $DEST"
