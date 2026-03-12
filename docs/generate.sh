#!/usr/bin/env bash

set -ex

# Ensure we use UTF-8 for sed and other tools
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Get absolute path to project root
ROOT_DIR=$(realpath "$(dirname "$0")/..")

cd docs

rm -rf build
mkdir build

# Generate intermediate binary format for our project
odin doc ../examples/ -all-packages -doc-format -out:odin-mbox.odin-doc

# Create a temporary config with absolute paths
sed "s|PROJECT_ROOT|$ROOT_DIR|g" odin-doc.json > build/odin-doc.json

cd build

# Render to HTML using the binary built in tools/
"$ROOT_DIR/tools/odin-doc" ../odin-mbox.odin-doc ./odin-doc.json

# Post-process: remove "Generation Information" sections and TOC links
find . -name "index.html" -exec sed -i '/<h2 id="pkg-generation-information">/,/<p>Generated with .*<\/p>/d' {} +
find . -name "index.html" -exec sed -i '/<li><a href="#pkg-generation-information">/d' {} +

# Post-process: Make all links and assets relative
# 1. Root index.html
sed -i 's|href="/|href="./|g' index.html
sed -i 's|src="/|src="./|g' index.html
# Fix the library link specifically (it should point to its own subdirectory)
sed -i 's|href="./odin-mbox"|href="./odin-mbox/"|g' index.html

# 2. Package index.html (in odin-mbox/ directory)
if [ -d "odin-mbox" ]; then
    sed -i 's|href="/|href="../|g' odin-mbox/index.html
    sed -i 's|src="/|src="../|g' odin-mbox/index.html
    # Fix self-links and navigation in the package page
    sed -i 's|href="\.\./odin-mbox"|href="../odin-mbox/"|g' odin-mbox/index.html
fi

cd ..

rm odin-mbox.odin-doc

cd ..
