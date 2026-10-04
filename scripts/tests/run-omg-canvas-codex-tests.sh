#!/bin/bash
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd)
harness_root=$(mktemp -d "${TMPDIR:-/tmp/}omg-codex-tests.XXXXXX")
mkdir -p "$harness_root/Sources/OMGCanvasCodexHarness" "$harness_root/Tests/OMGCanvasCodexHarnessTests"
for name in Runtime Provider Identity Message Activity Prompt Response Status Event Lease InputWriter; do
  cp "$source_root/Sources/OMGCanvas/OMGCanvasChat$name.swift" "$harness_root/Sources/OMGCanvasCodexHarness/"
done
cp "$source_root/Sources/OMGCanvas/OMGCanvasCodexRuntime.swift" "$harness_root/Sources/OMGCanvasCodexHarness/"
cp "$source_root/cmuxTests/OMGCanvasCodexRuntimeTests.swift" "$harness_root/Tests/OMGCanvasCodexHarnessTests/"
cat > "$harness_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OMGCanvasCodexHarness", platforms: [.macOS(.v14)], targets: [.target(name: "OMGCanvasCodexHarness"), .testTarget(name: "OMGCanvasCodexHarnessTests", dependencies: ["OMGCanvasCodexHarness"])])
PACKAGE
export OMG_CODEX_FAKE_SERVER="$source_root/scripts/tests/fixtures/omg-codex-app-server.py"
export CLANG_MODULE_CACHE_PATH="$harness_root/module-cache"
export SWIFT_MODULECACHE_PATH="$harness_root/module-cache"
xcrun swift test --package-path "$harness_root" --disable-sandbox --scratch-path "$harness_root/build" -Xswiftc -module-cache-path -Xswiftc "$harness_root/module-cache"
