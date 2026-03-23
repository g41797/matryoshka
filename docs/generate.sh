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
odin doc ../mbox ../mpsc ../pool ../wakeup ../loop_mbox ../nbio_mbox ../examples -all-packages -doc-format -out:matryoshka.odin-doc

# Create a temporary config with absolute paths
sed "s|PROJECT_ROOT|$ROOT_DIR|g" odin-doc.json > build/odin-doc.json

cd build

# Render to HTML using the binary built in tools/
"$ROOT_DIR/tools/odin-doc" ../matryoshka.odin-doc ./odin-doc.json

# Post-process: remove "Generation Information" sections and TOC links
find . -name "index.html" -exec sed -i '/<h2 id="pkg-generation-information">/,/<p>Generated with .*<\/p>/d' {} +
find . -name "index.html" -exec sed -i '/<li><a href="#pkg-generation-information">/d' {} +

# Post-process: Make all links and assets relative
# Patterns match href="/<non-slash>" to avoid corrupting protocol-relative URLs (href="//cdn...")
# 1. Root index.html
sed -i 's|href="/\([^/]\)|href="./\1|g' index.html
sed -i 's|src="/\([^/]\)|src="./\1|g' index.html
# Fix the library link specifically (it should point to its own subdirectory)
sed -i 's|href="./matryoshka"|href="./matryoshka/"|g' index.html
# Fix the blank root package link text
sed -i 's|<a href="./matryoshka/"></a>|<a href="./matryoshka/">mbox</a>|g' index.html

# 2. Collection home index.html (in matryoshka/ directory — depth 1)
if [ -d "matryoshka" ]; then
    sed -i 's|href="/\([^/]\)|href="../\1|g' matryoshka/index.html
    sed -i 's|src="/\([^/]\)|src="../\1|g' matryoshka/index.html
    # Fix self-links and navigation in the package page
    sed -i 's|href="\.\./matryoshka"|href="../matryoshka/"|g' matryoshka/index.html
    # Fix the blank root package link text
    sed -i 's|<a href="../matryoshka/"></a>|<a href="../matryoshka/">mbox</a>|g' matryoshka/index.html
fi

# 3. Sub-package index.html files (in matryoshka/*/ directory — depth 2)
for subdir in matryoshka/*/; do
    if [ -f "${subdir}index.html" ]; then
        sed -i 's|href="/\([^/]\)|href="../../\1|g' "${subdir}index.html"
        sed -i 's|src="/\([^/]\)|src="../../\1|g' "${subdir}index.html"
        # Fix the blank root package link text
        sed -i 's|<a href="../../matryoshka/"></a>|<a href="../../matryoshka/">mbox</a>|g' "${subdir}index.html"
    fi
done

cd ..

rm matryoshka.odin-doc

cd ..
