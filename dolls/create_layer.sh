#!/usr/bin/env bash
# Usage: ./create_layer.sh [N]
#   N - source doll number (default: highest existing doll)
# Creates layerN+1 from layerN and updates matryoshka.code-workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS_DIR="${SCRIPT_DIR}"
WORKSPACE_FILE="${SCRIPT_DIR}/../matryoshka.code-workspace"

# Determine source doll number
if [ $# -ge 1 ]; then
    SRC_N="$1"
else
    SRC_N=$(ls -d "${LAYERS_DIR}"/doll*/ 2>/dev/null \
        | grep -oP '(?<=doll)\d+' | sort -n | tail -1)
    if [ -z "${SRC_N}" ]; then
        echo "Error: no dolls found in ${LAYERS_DIR}"
        exit 1
    fi
fi

DST_N=$((SRC_N + 1))
SRC_LAYER="${LAYERS_DIR}/doll${SRC_N}"
DST_LAYER="${LAYERS_DIR}/doll${DST_N}"

echo "Source : doll${SRC_N} (${SRC_LAYER})"
echo "Dest   : doll${DST_N} (${DST_LAYER})"

# Guards
if [ ! -d "${SRC_LAYER}" ]; then
    echo "Error: source doll not found: ${SRC_LAYER}"
    exit 1
fi
if [ -d "${DST_LAYER}" ]; then
    echo "Error: destination already exists: ${DST_LAYER}"
    exit 1
fi

# Copy doll
cp -r "${SRC_LAYER}" "${DST_LAYER}"

# Remove build artifacts from copy
find "${DST_LAYER}" -name "*.a"           -delete
find "${DST_LAYER}" -name "*.o"           -delete
find "${DST_LAYER}" -name "debug_current" -delete

# Update .code-workspace
python3 - <<EOF
import json, sys

with open('${WORKSPACE_FILE}', 'r') as f:
    ws = json.load(f)

new_folder = {"name": "doll${DST_N}", "path": "dolls/doll${DST_N}"}

for folder in ws['folders']:
    if folder.get('path') == new_folder['path']:
        print("doll${DST_N} already in workspace file — skipped")
        sys.exit(0)

ws['folders'].append(new_folder)

with open('${WORKSPACE_FILE}', 'w') as f:
    json.dump(ws, f, indent=4)
    f.write('\n')

print("Updated matryoshka.code-workspace")
EOF

echo "Done. doll${DST_N} is ready."
