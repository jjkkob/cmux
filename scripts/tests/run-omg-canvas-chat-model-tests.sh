#!/bin/bash
# Real production state/request/snapshot contracts with fake provider events; no providers or app launch.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd)
harness_root=$(mktemp -d "${TMPDIR:-/tmp/}omg-chat-model-tests.XXXXXX")
mkdir -p "$harness_root/Sources/OMGCanvasChatHarness" "$harness_root/Tests/OMGCanvasChatHarnessTests"
for file in OMGCanvasGraph OMGCanvasBridgeRequest OMGCanvasSnapshot OMGCanvasState OMGCanvasChatModel OMGCanvasChatOwnership OMGCanvasChatRuntime OMGCanvasChatProvider OMGCanvasChatIdentity OMGCanvasChatMessage OMGCanvasChatActivity OMGCanvasChatPrompt OMGCanvasChatResponse OMGCanvasChatStatus OMGCanvasChatEvent; do
  cp "$source_root/Sources/OMGCanvas/$file.swift" "$harness_root/Sources/OMGCanvasChatHarness/"
done
cp "$source_root/cmuxTests/OMGCanvasChatTests.swift" "$harness_root/Tests/OMGCanvasChatHarnessTests/"
cat > "$harness_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OMGCanvasChatHarness", platforms: [.macOS(.v14)], targets: [
  .target(name: "OMGCanvasChatHarness"),
  .testTarget(name: "OMGCanvasChatHarnessTests", dependencies: ["OMGCanvasChatHarness"])
])
PACKAGE
export CLANG_MODULE_CACHE_PATH="$harness_root/module-cache"
export SWIFT_MODULECACHE_PATH="$harness_root/module-cache"
export OMG_CANVAS_CHAT_FIXTURE="$source_root/Resources/omg-canvas/bridge-fixture.json"
printf 'Production chat model harness: %s\n' "$harness_root"
xcrun swift test --package-path "$harness_root" --disable-sandbox --scratch-path "$harness_root/build" -Xswiftc -module-cache-path -Xswiftc "$harness_root/module-cache"
