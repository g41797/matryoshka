#!/usr/bin/env bash

set -euo pipefail

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

OPTS=(none minimal size speed aggressive)

echo "${BLUE}Starting odin-mbox local CI...${NC}"

if ! command -v odin >/dev/null 2>&1; then
    echo "Error: odin compiler not found in PATH"
    exit 1
fi

for opt in "${OPTS[@]}"; do
    echo
    echo "${BLUE}--- opt: ${opt} ---${NC}"

    echo "  build root lib..."
    if [ "${opt}" = "none" ]; then
        odin build . -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build . -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  build mbox lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./mbox/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./mbox/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  build mpsc lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./mpsc/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./mpsc/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test mpsc/..."
    if [ "${opt}" = "none" ]; then
        odin test ./mpsc/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./mpsc/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  build wakeup lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./wakeup/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./wakeup/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test wakeup/..."
    if [ "${opt}" = "none" ]; then
        odin test ./wakeup/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./wakeup/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  build try_mbox lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./try_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./try_mbox/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test try_mbox/..."
    if [ "${opt}" = "none" ]; then
        odin test ./try_mbox/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./try_mbox/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  build nbio_mbox lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./nbio_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./nbio_mbox/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test nbio_mbox/..."
    if [ "${opt}" = "none" ]; then
        odin test ./nbio_mbox/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./nbio_mbox/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  build pool lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  build examples..."
    if [ "${opt}" = "none" ]; then
        odin build ./examples/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./examples/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test tests/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  build pool_tests/..."
    if [ "${opt}" = "none" ]; then
        odin build ./pool_tests/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./pool_tests/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  test pool_tests/..."
    if [ "${opt}" = "none" ]; then
        odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./pool_tests/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "${GREEN}  pass: ${opt}${NC}"
done

echo
echo "${BLUE}--- doc smoke test ---${NC}"
odin doc ./
odin doc ./mbox/
odin doc ./mpsc/
odin doc ./wakeup/
odin doc ./try_mbox/
odin doc ./nbio_mbox/
odin doc ./pool/
odin doc ./pool_tests/
odin doc ./examples/
odin doc ./tests/
echo "${GREEN}  docs OK${NC}"

echo
echo "${GREEN}ALL CHECKS PASSED${NC}"
