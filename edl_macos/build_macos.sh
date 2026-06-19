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

echo "Patching legacy 'ptr == \\\"\\\\0\\\"' comparisons (5 sites; idempotent)..."
# Qualcomm's source has five places where `(char*)ptr == '\0'` is used to mean
# "ptr is null". gcc-11 silently treated '\0' as the null-pointer constant; clang
# refuses ("comparison between pointer and integer"). Replace with `NULL` literally.
# Anchored to the full surrounding tokens so we never touch a real char comparison.
PATCH_SED=(
  -e "s/(pch != '\\\\0')/(pch != NULL)/"
  -e "s/(Dest == '\\\\0')/(Dest == NULL)/"
  -e "s/(Source == '\\\\0')/(Source == NULL)/"
  -e "s/(pch == '\\\\0')/(pch == NULL)/"
  -e "s/(FileAndPath == '\\\\0' || strlen(FileAndPath) == 0)/(FileAndPath == NULL || strlen(FileAndPath) == 0)/"
)
# macOS sed needs '' after -i (or BSD sed's no-arg form). Use a portable approach:
# write to a temp file and replace.
sed "${PATCH_SED[@]}" fh_loader.cpp > fh_loader.cpp.tmp && mv fh_loader.cpp.tmp fh_loader.cpp

echo "Building fh_loader (arm64 Mach-O)..."
# Notes on the flags:
#   -fpermissive               : five legacy "ptr == '\0'" comparisons in fh_loader.cpp
#   -DSIZE_T_FORMAT='"zu"'     : the source uses `"%"SIZE_T_FORMAT` (a Microsoft-era
#                                idiom that pasted "%I64u" on Windows). Modern clang
#                                rejects literal-juxtaposed-with-identifier as a UDL.
#                                Defining it to "zu" gives clang a single string
#                                literal to parse, and `%zu` is the portable spec
#                                for size_t on macOS/Linux.
#   -Dstat64=stat (macOS only) : macOS doesn't expose `struct stat64` (its `struct stat`
#                                is already 64-bit when _FILE_OFFSET_BITS=64). Aliasing
#                                makes the two `struct stat64 buf;` declarations valid.
#                                Linux has `struct stat64` natively, so we MUST NOT
#                                define this there (would be a redefinition).
#   -Wno-... -Wno-...          : silence the now-redundant warnings cleanly.
EXTRA_FLAGS=()
case "$(uname -s)" in
  Darwin) EXTRA_FLAGS+=(-Dstat64=stat) ;;
esac

clang++ -std=c++17 -O2 -w -fpermissive -D_FILE_OFFSET_BITS=64 \
  -DSIZE_T_FORMAT='"zu"' \
  "${EXTRA_FLAGS[@]}" \
  -Wno-reserved-user-defined-literal \
  -Wno-format-security \
  fh_loader.cpp fh_loader_sha.cpp \
  -o fh_loader

file ./fh_loader
echo
echo "Smoke test:"
./fh_loader 2>&1 | head -5 || true
echo
echo "Done. Binary: $(pwd)/fh_loader"
