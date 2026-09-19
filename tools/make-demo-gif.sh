#!/bin/bash
# Renders docs/img/whirlpool-demo.gif with the app's own renderers and demo quotes (no screen recording).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/demo-gif .build/ModuleCache
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != "Sources/main.swift" ]]; then sources+=("$source"); fi
done
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swiftc -O -parse-as-library "${sources[@]}" tools/DemoGIF.swift -o .build/demo-gif/run
.build/demo-gif/run docs/img/whirlpool-demo.gif
ls -la docs/img/whirlpool-demo.gif
