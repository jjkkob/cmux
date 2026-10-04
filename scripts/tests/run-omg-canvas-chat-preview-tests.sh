#!/bin/bash
# Exercises actual production models without an app host or provider process.
# This does not replace native host routing, rendering, focus, or UI dogfood checks.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd)
harness_root=$(mktemp -d "${TMPDIR:-/tmp/}omg-chat-preview-tests.XXXXXX")
mkdir -p "$harness_root/Sources/OMGCanvasChatPreviewHarness" "$harness_root/Tests/OMGCanvasChatPreviewHarnessTests" "$harness_root/Packages"
for file in OMGCanvasGraph.swift OMGCanvasBridgeRequest.swift OMGCanvasSnapshot.swift OMGCanvasState.swift OMGCanvasChatPreviewModel.swift; do
  cp "$source_root/Sources/OMGCanvas/$file" "$harness_root/Sources/OMGCanvasChatPreviewHarness/$file"
done
cp "$source_root/cmuxTests/OMGCanvasChatPreviewTests.swift" "$harness_root/Tests/OMGCanvasChatPreviewHarnessTests/"
ln -s "$source_root/Packages/Shared/CmuxAgentChat" "$harness_root/Packages/CmuxAgentChat"
cat > "$harness_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OMGCanvasChatPreviewHarness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Packages/CmuxAgentChat")],
    targets: [
        .target(name: "OMGCanvasChatPreviewHarness", dependencies: [.product(name: "CmuxAgentChat", package: "CmuxAgentChat")]),
        .testTarget(name: "OMGCanvasChatPreviewHarnessTests", dependencies: ["OMGCanvasChatPreviewHarness", .product(name: "CmuxAgentChat", package: "CmuxAgentChat")])
    ]
)
PACKAGE
export CLANG_MODULE_CACHE_PATH="$harness_root/module-cache"
export SWIFT_MODULECACHE_PATH="$harness_root/module-cache"
export OMG_CANVAS_CHAT_PREVIEW_FIXTURE="$source_root/Resources/omg-canvas/bridge-fixture.json"
printf 'Production-model harness: %s\n' "$harness_root"
xcrun swift test --package-path "$harness_root" --disable-sandbox --scratch-path "$harness_root/build" -Xswiftc -module-cache-path -Xswiftc "$harness_root/module-cache"
