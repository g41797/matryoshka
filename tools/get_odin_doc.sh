#!/usr/bin/env bash
set -e

# get_odin_doc.sh
# Clones, builds, and installs the official Odin documentation renderer.

TOOLS_DIR=$(dirname "$(readlink -f "$0")")
TEMP_DIR="$TOOLS_DIR/tmp_pkg_repo"
OUT_BIN="$TOOLS_DIR/odin-doc"

echo "--- Building odin-doc ---"

# 1. Clean up old attempts
rm -rf "$TEMP_DIR"

# 2. Clone the renderer source
echo "Cloning pkg.odin-lang.org..."
git clone --depth 1 https://github.com/odin-lang/pkg.odin-lang.org.git "$TEMP_DIR"

# 3. Build the tool
echo "Building binary..."
cd "$TEMP_DIR"
odin build . -out:"$OUT_BIN" -o:speed -extra-linker-flags:"-L$TOOLS_DIR"

# 4. Clean up source
echo "Cleaning up..."
cd "$TOOLS_DIR"
rm -rf "$TEMP_DIR"

echo "--- Done ---"
echo "Binary installed to: $OUT_BIN"
