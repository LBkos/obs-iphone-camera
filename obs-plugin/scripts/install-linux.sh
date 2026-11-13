#!/usr/bin/env bash
# Builds the plugin and installs it for the current user:
#   ~/.config/obs-studio/plugins/obs-iphone-camera/{bin/64bit,data}
set -euo pipefail

cd "$(dirname "$0")/.."
PREFIX="${OBS_PLUGIN_PREFIX:-$HOME/.config/obs-studio/plugins/obs-iphone-camera}"

# Use the OBS dev package if present, otherwise fetch libobs headers.
if ! pkg-config --exists libobs 2>/dev/null && [ ! -d /usr/lib/x86_64-linux-gnu/cmake/libobs ] \
   && [ ! -d /usr/lib64/cmake/libobs ] && [ ! -d /usr/lib/cmake/libobs ]; then
  OBS_VERSION="$(obs --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  ./scripts/fetch-obs-headers.sh "${OBS_VERSION:-33.0.1}"
fi

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build build -j"$(nproc)"
cmake --install build

echo
echo "Installed to $PREFIX"
echo "Restart OBS, then add Sources → + → \"iPhone Camera\"."
