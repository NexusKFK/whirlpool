#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/price-flash-tests .build/ModuleCache
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != "Sources/main.swift" ]]; then sources+=("$source"); fi
done
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swiftc -parse-as-library \
    "${sources[@]}" Tests/*.swift -o .build/price-flash-tests/run
.build/price-flash-tests/run
