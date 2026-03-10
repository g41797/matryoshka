#!/usr/bin/env bash
set -e

# preview_docs.sh
# Builds the HTML documentation locally and starts a web server for preview.
# Note: Requires 'odin-doc' binary in tools/ folder.
# Note: Tested on Linux only.

TOOLS_DIR=$(dirname "$(readlink -f "$0")")
ROOT_DIR=$(dirname "$TOOLS_DIR")
DOCS_DIR="$ROOT_DIR/docs"
BUILD_DIR="$DOCS_DIR/build"

if [ ! -f "$TOOLS_DIR/odin-doc" ]; then
    echo "Error: odin-doc binary not found in $TOOLS_DIR"
    echo "Please run ./tools/get_odin_doc.sh first."
    exit 1
fi

# Add tools to PATH so generate.sh can find odin-doc
export PATH="$TOOLS_DIR:$PATH"

echo "--- Generating Docs ---"
"$DOCS_DIR/generate.sh"

echo "--- Starting Local Server ---"
echo "Click to preview: http://localhost:8000"
echo "(Press Ctrl+C to stop)"

cd "$BUILD_DIR"
python3 -m http.server 8000
