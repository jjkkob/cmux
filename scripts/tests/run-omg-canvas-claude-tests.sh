#!/bin/bash
# Tests the production Claude client against a deterministic wire fixture; never starts a provider.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/../.." && pwd)
harness_root=$(mktemp -d "${TMPDIR:-/tmp/}omg-claude-tests.XXXXXX")
mkdir -p "$harness_root/Sources/OMGCanvasClaudeHarness" "$harness_root/Tests/OMGCanvasClaudeHarnessTests"
for name in Runtime Provider Identity Message Activity Prompt Response Status Event Lease; do
  cp "$source_root/Sources/OMGCanvas/OMGCanvasChat$name.swift" "$harness_root/Sources/OMGCanvasClaudeHarness/"
done
for name in Runtime Transport History; do
  cp "$source_root/Sources/OMGCanvas/OMGCanvasClaude$name.swift" "$harness_root/Sources/OMGCanvasClaudeHarness/"
done
cp "$source_root/cmuxTests/OMGCanvasClaudeRuntimeTests.swift" "$harness_root/Tests/OMGCanvasClaudeHarnessTests/"
cat > "$harness_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OMGCanvasClaudeHarness", platforms: [.macOS(.v14)], targets: [.target(name: "OMGCanvasClaudeHarness"), .testTarget(name: "OMGCanvasClaudeHarnessTests", dependencies: ["OMGCanvasClaudeHarness"])])
PACKAGE
export OMG_CLAUDE_FAKE_SERVER="$source_root/scripts/tests/fixtures/omg-claude-stream-json.py"
export CLANG_MODULE_CACHE_PATH="$harness_root/module-cache"
export SWIFT_MODULECACHE_PATH="$harness_root/module-cache"
xcrun swift test --package-path "$harness_root" --disable-sandbox --scratch-path "$harness_root/build" -Xswiftc -module-cache-path -Xswiftc "$harness_root/module-cache"
