#!/usr/bin/env bash

set -euo pipefail

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

OPTS=(none minimal size speed aggressive)

echo "${BLUE}Starting layer1 local CI...${NC}"

if ! command -v odin >/dev/null 2>&1; then
    echo "Error: odin compiler not found in PATH"
    exit 1
fi

for opt in "${OPTS[@]}"; do
    echo
    echo "${BLUE}--- opt: ${opt} ---${NC}"

    echo "  build item lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./item/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./item/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test item/..."
    if [ "${opt}" = "none" ]; then
        odin test ./item/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./item/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    if [ -d "./examples/item" ] && [ -n "$(find ./examples/item -name '*.odin' 2>/dev/null | head -1)" ]; then
        echo "  build examples/item lib..."
        if [ "${opt}" = "none" ]; then
            odin build ./examples/item/ -build-mode:lib -vet -strict-style -o:none -debug
        else
            odin build ./examples/item/ -build-mode:lib -vet -strict-style -o:"${opt}"
        fi
    fi

    if [ -d "./tests/item" ] && [ -n "$(find ./tests/item -name '*.odin' 2>/dev/null | head -1)" ]; then
        echo "  test tests/item/..."
        if [ "${opt}" = "none" ]; then
            odin test ./tests/item/ -vet -strict-style -disallow-do -o:none -debug
        else
            odin test ./tests/item/ -vet -strict-style -disallow-do -o:"${opt}"
        fi
    fi

    if [ -d "./hooks" ] && [ -n "$(find ./hooks -name '*.odin' 2>/dev/null | head -1)" ]; then
        echo "  build hooks lib..."
        if [ "${opt}" = "none" ]; then
            odin build ./hooks/ -build-mode:lib -vet -strict-style -o:none -debug
        else
            odin build ./hooks/ -build-mode:lib -vet -strict-style -o:"${opt}"
        fi
    fi

    if [ -d "./examples/hooks" ] && [ -n "$(find ./examples/hooks -name '*.odin' 2>/dev/null | head -1)" ]; then
        echo "  build examples/hooks lib..."
        if [ "${opt}" = "none" ]; then
            odin build ./examples/hooks/ -build-mode:lib -vet -strict-style -o:none -debug
        else
            odin build ./examples/hooks/ -build-mode:lib -vet -strict-style -o:"${opt}"
        fi
    fi

    if [ -d "./tests/hooks" ] && [ -n "$(find ./tests/hooks -name '*.odin' 2>/dev/null | head -1)" ]; then
        echo "  test tests/hooks/..."
        if [ "${opt}" = "none" ]; then
            odin test ./tests/hooks/ -vet -strict-style -disallow-do -o:none -debug
        else
            odin test ./tests/hooks/ -vet -strict-style -disallow-do -o:"${opt}"
        fi
    fi

    echo "${GREEN}  pass: ${opt}${NC}"
done

echo
echo "${BLUE}--- doc smoke test ---${NC}"
odin doc ./item/
odin doc ./examples/item/
odin doc ./hooks/
odin doc ./examples/hooks/
echo "${GREEN}  docs OK${NC}"

echo
echo "${GREEN}ALL CHECKS PASSED${NC}"
