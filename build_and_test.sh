#!/usr/bin/env bash

set -euo pipefail

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

OPTS=(none minimal size speed aggressive)

echo "${BLUE}Starting matryoshka local CI...${NC}"

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

    echo "  build loop_mbox lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./loop_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./loop_mbox/ -build-mode:lib -vet -strict-style -o:"${opt}"
    fi

    echo "  build nbio_mbox lib..."
    if [ "${opt}" = "none" ]; then
        odin build ./nbio_mbox/ -build-mode:lib -vet -strict-style -o:none -debug
    else
        odin build ./nbio_mbox/ -build-mode:lib -vet -strict-style -o:"${opt}"
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

    echo "  test tests/mbox/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/mbox/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/mbox/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  test tests/loop_mbox/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/loop_mbox/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/loop_mbox/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  test tests/nbio_mbox/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/nbio_mbox/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/nbio_mbox/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "  test tests/pool/..."
    if [ "${opt}" = "none" ]; then
        odin test ./tests/pool/ -vet -strict-style -disallow-do -o:none -debug
    else
        odin test ./tests/pool/ -vet -strict-style -disallow-do -o:"${opt}"
    fi

    echo "${GREEN}  pass: ${opt}${NC}"
done

echo
echo "${BLUE}--- doc smoke test ---${NC}"
odin doc ./
odin doc ./mbox/
odin doc ./mpsc/
odin doc ./wakeup/
odin doc ./loop_mbox/
odin doc ./nbio_mbox/
odin doc ./pool/
odin doc ./examples/
odin doc ./tests/
echo "${GREEN}  docs OK${NC}"

echo
echo "${GREEN}ALL CHECKS PASSED${NC}"

echo
echo "${BLUE}--- building docs ---${NC}"
bash "$(dirname "$0")/docs_site/build.sh"
echo "${GREEN}  docs OK${NC}"
