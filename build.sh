#!/bin/bash
# Build eventkit CLI and install to ~/.local/bin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/eventkit-build"

echo "Building eventkit..."
cd "$SCRIPT_DIR"
swift build -c release --build-path "$BUILD_DIR"

echo "Installing to ~/.local/bin/eventkit..."
mkdir -p ~/.local/bin
cp "$BUILD_DIR/release/eventkit" ~/.local/bin/eventkit
chmod +x ~/.local/bin/eventkit

echo "Done: $(eventkit --version)"
