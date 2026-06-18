#!/usr/bin/env bash
# Build fh_loader natively on Apple Silicon macOS.
# Source is Qualcomm's official fh_loader.cpp (via LonelyFool/fh_loader on GitHub),
# which is portable POSIX C++ (uses termios; no Linux-specific headers).
# `-fpermissive` silences five legacy "pointer == '\0'" comparisons that older
# Visual C++ accepted but modern clang/gcc reject.

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v clang++ >/dev/null 2>&1; then
  echo "clang++ not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

echo "Building fh_loader (arm64 Mach-O)..."
clang++ -std=c++17 -O2 -w -fpermissive -D_FILE_OFFSET_BITS=64 \
  fh_loader.cpp fh_loader_sha.cpp \
  -o fh_loader

file ./fh_loader
echo
echo "Smoke test:"
./fh_loader 2>&1 | head -5 || true
echo
echo "Done. Binary: $(pwd)/fh_loader"
