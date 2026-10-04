#!/bin/bash
# Executes the actual Foundation-only production models in an isolated Swift Testing package.
# This deliberately does not stand in for the app-hosted cmuxTests build or native UI dogfood.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd)
harness_root=$(mktemp -d "${TMPDIR:-/tmp/}omg-history-model-tests.XXXXXX")
mkdir -p "$harness_root/Sources/OMGCanvasHistoryModel" "$harness_root/Tests/OMGCanvasHistoryModelTests"
for file in OMGCanvasGraph.swift OMGCanvasBridgeRequest.swift OMGCanvasHistoryManifest.swift OMGCanvasGraph+History.swift OMGCanvasSnapshot.swift; do
  cp "$source_root/Sources/OMGCanvas/$file" "$harness_root/Sources/OMGCanvasHistoryModel/$file"
done
cp "$source_root/cmuxTests/OMGCanvasHistoryTests.swift" "$harness_root/Tests/OMGCanvasHistoryModelTests/"
cat > "$harness_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OMGCanvasHistoryModel", platforms: [.macOS(.v14)], targets: [
    .target(name: "OMGCanvasHistoryModel"),
    .testTarget(name: "OMGCanvasHistoryModelTests", dependencies: ["OMGCanvasHistoryModel"])
])
PACKAGE
export CLANG_MODULE_CACHE_PATH="$harness_root/module-cache"
export SWIFT_MODULECACHE_PATH="$harness_root/module-cache"
export OMG_CANVAS_HISTORY_FIXTURE="$source_root/Resources/omg-canvas/bridge-fixture.json"
printf 'Production-model harness: %s\n' "$harness_root"
xcrun swift test --package-path "$harness_root" --disable-sandbox --scratch-path "$harness_root/build" -Xswiftc -module-cache-path -Xswiftc "$harness_root/module-cache"
