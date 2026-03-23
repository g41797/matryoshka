#!/usr/bin/env bash

set -euo pipefail

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

OPTS=(none)

BUILDS=(
    item
    hooks
    pool
    examples/item
    examples/hooks
    examples/pool
)

TESTS=(
    item
    tests/item
    tests/hooks
    tests/pool
)

DOCS=(
    item
    hooks
    pool
    examples/item
    examples/hooks
    examples/pool
)

echo "${BLUE}Starting doll2 local CI (debug)...${NC}"

if ! command -v odin >/dev/null 2>&1; then
    echo "Error: odin compiler not found in PATH"
    exit 1
fi

for opt in "${OPTS[@]}"; do
    echo
    echo "${BLUE}--- opt: ${opt} ---${NC}"

    for path in "${BUILDS[@]}"; do
        if [ -d "./${path}" ] && [ -n "$(find ./${path} -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
            echo "  build ${path}..."
            if [ "${opt}" = "none" ]; then
                odin build ./${path}/ -build-mode:lib -vet -strict-style -o:none -debug
            else
                odin build ./${path}/ -build-mode:lib -vet -strict-style -o:"${opt}"
            fi
        fi
    done

    for path in "${TESTS[@]}"; do
        if [ -d "./${path}" ] && [ -n "$(find ./${path} -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
            echo "  test ${path}/..."
            if [ "${opt}" = "none" ]; then
                odin test ./${path}/ -vet -strict-style -disallow-do -o:none -debug
            else
                odin test ./${path}/ -vet -strict-style -disallow-do -o:"${opt}"
            fi
        fi
    done

    echo "${GREEN}  pass: ${opt}${NC}"
done

echo
echo "${BLUE}--- doc smoke test ---${NC}"
for path in "${DOCS[@]}"; do
    if [ -d "./${path}" ] && [ -n "$(find ./${path} -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
        odin doc ./${path}/
    fi
done
echo "${GREEN}  docs OK${NC}"

echo
echo "${GREEN}ALL CHECKS PASSED${NC}"
