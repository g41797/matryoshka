#!/usr/bin/env bash
set -e

# build_docs.sh
# One-command documentation workflow: build tool, generate HTML, and preview.
# Note: Tested on Linux only.

ROOT_DIR=$(dirname "$(readlink -f "$0")")

# 1. Ensure the odin-doc renderer is built
if [ ! -f "$ROOT_DIR/tools/odin-doc" ]; then
    echo "--- Tool not found. Building odin-doc ---"
    "$ROOT_DIR/tools/get_odin_doc.sh"
fi

# 2. Generate the HTML documentation
echo "--- Generating HTML ---"
"$ROOT_DIR/docs/generate.sh"

# 3. Start local preview
echo "--- Starting Preview ---"
"$ROOT_DIR/tools/preview_docs.sh"
