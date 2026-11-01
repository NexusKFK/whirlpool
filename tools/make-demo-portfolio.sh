#!/bin/bash
# Renders docs/img/portfolio-panel{,.zh}.png with the app's own PortfolioWindow and a made-up snapshot
# (no gateway, no network, no screen recording).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/demo-portfolio .build/ModuleCache
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != "Sources/main.swift" ]]; then sources+=("$source"); fi
done
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swiftc -O -parse-as-library "${sources[@]}" tools/DemoPortfolio.swift -o .build/demo-portfolio/run
.build/demo-portfolio/run "${1:-docs/img}"
