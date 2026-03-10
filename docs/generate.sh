#!/usr/bin/env bash

set -ex

# Get absolute path to project root
ROOT_DIR=$(realpath "$(dirname "$0")/..")

cd docs

rm -rf build
mkdir build

# Generate intermediate binary format for our project
odin doc .. -all-packages -doc-format -out:odin-mbox.odin-doc

# Create a temporary config with absolute paths
sed "s|PROJECT_ROOT|$ROOT_DIR|g" odin-doc.json > build/odin-doc.json

cd build

# Render to HTML using the binary built in tools/
../../tools/odin-doc ../odin-mbox.odin-doc ./odin-doc.json

# Post-process: remove "Generation Information" sections and TOC links
find . -name "index.html" -exec sed -i '/<h2 id="pkg-generation-information">/,/<p>Generated with .*<\/p>/d' {} +
find . -name "index.html" -exec sed -i '/<li><a href="#pkg-generation-information">Source Files<\/a><\/ul>/d' {} +
find . -name "index.html" -exec sed -i '/<li><a href="#pkg-generation-information">Generation Information<\/a>/d' {} +

cd ..

rm odin-mbox.odin-doc

cd ..
