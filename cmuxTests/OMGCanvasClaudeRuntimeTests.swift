import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(OMGCanvasClaudeHarness)
@testable import OMGCanvasClaudeHarness
#endif

@Suite("OMG Claude protocol client", .serialized, .timeLimit(.minutes(1)))
struct OMGCanvasClaudeRuntimeTests {
    @Test @MainActor func streamUpsertsUseStableIDsAndFinalTurnBoundary() async throws {
        let fixture = try fixture("stream")
        defer { fixture.runtime.shutdown() }
        try await fixture.runtime.open(sessionID: nil, cwd: fixture.directory.path)
        _ = await fixture.next { $0 == .status(.idle) }
        try await fixture.runtime.send("Fixture prompt")
        var messages: [OMGCanvasChatMessage] = []
        _ = await fixture.next { event in
            if case .message(let message) = event, message.role == .assistant { messages.append(message) }
            return event == .status(.idle)
        }
        #expect(messages.contains(.init(id: "assistant-1", role: .assistant, text: "Hello 🌱", isStreaming: true)))
        #expect(messages.last == .init(id: "assistant-1", role: .assistant, text: "Hello 🌱"))
        #expect(Set(messages.map(\.id)) == ["assistant-1"])
    }

    @Test @MainActor func approvalAndMultiSelectPreserveInputWithoutPermissionExpansion() async throws {
        let fixture = try fixture("permissions")
        defer { fixture.runtime.shutdown() }
        try await fixture.runtime.open(sessionID: nil, cwd: fixture.directory.path)
        _ = await fixture.next { $0 == .status(.idle) }
        try await fixture.runtime.send("Fixture tool request")
        let permission = await fixture.next { if case .prompt = $0 { return true }; return false }
        guard case .prompt(let approval) = permission else { Issue.record("No approval"); return }
        #expect(approval.id == "approve-1")
        #expect(!((try fixture.requests()).contains { $0["type"] as? String == "control_response" }))
        await #expect(throws: (any Error).self) { try await fixture.runtime.respond(to: "stale-request", response: .approve) }
        try await fixture.runtime.respond(to: approval.id, response: .approve)
        let next = await fixture.next { if case .prompt = $0 { return true }; return false }
        guard case .prompt(let prompt) = next else { Issue.record("No question"); return }
        #expect(prompt.questions.first?.allowsMultiple == true)
        try await fixture.runtime.respond(to: prompt.id, response: .answers(["Choose colors": ["Blue", "Green"]]))
        _ = await fixture.next { $0 == .status(.idle) }
        let responses = try fixture.requests().filter { $0["type"] as? String == "control_response" }
        let first = try #require((responses.first?["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(first["behavior"] as? String == "allow")
        #expect(first["updatedPermissions"] == nil)
        #expect((first["updatedInput"] as? [String: String])?["content"] == "fixture only")
        let last = try #require((responses.last?["response"] as? [String: Any])?["response"] as? [String: Any])
        let updated = try #require(last["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String])?["Choose colors"] == "Blue, Green")
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)
    }

    @Test @MainActor func intentionalInterruptDoesNotBecomeProviderFailureAndCanContinue() async throws {
        let fixture = try fixture("interrupt")
        defer { fixture.runtime.shutdown() }
        try await fixture.runtime.open(sessionID: nil, cwd: fixture.directory.path)
        _ = await fixture.next { $0 == .status(.idle) }
        for _ in 0..<2 {
            try await fixture.runtime.send("Fixture long turn")
            _ = await fixture.next { if case .message(let message) = $0 { return message.role == .assistant }; return false }
            try await fixture.runtime.interrupt()
            var failures = 0
            _ = await fixture.next { if case .failure = $0 { failures += 1 }; return $0 == .status(.idle) }
            #expect(failures == 0)
        }
        #expect(try fixture.requests().filter { ($0["request"] as? [String: Any])?["subtype"] as? String == "interrupt" }.count == 2)
    }

    @Test @MainActor func canceledOpenNeverLaunchesProvider() async throws {
        let fixture = try fixture("stream")
        defer { fixture.runtime.shutdown() }
        let opening = Task { try await fixture.runtime.open(sessionID: nil, cwd: fixture.directory.path) }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(try fixture.requests().isEmpty)
    }

    @Test func historyFollowsLatestMainBranchAndCompactionBoundary() {
        let lines = """
        {"type":"user","uuid":"u1","parentUuid":null,"message":{"content":"first"}}
        {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"content":[{"type":"text","text":"abandoned"}]}}
        {"type":"assistant","uuid":"a2","parentUuid":"u1","message":{"content":[{"type":"text","text":"active"}]}}
        {"type":"user","uuid":"side","parentUuid":null,"isSidechain":true,"message":{"content":"subagent prompt"}}
        """
        let history = OMGCanvasClaudeHistory.messages(lines, sessionID: UUID().uuidString)
        #expect(history.map(\.id) == ["u1", "a2"])
        let compacted = lines + "\n" + """
        {"type":"system","uuid":"boundary","parentUuid":null,"logicalParentUuid":"a2"}
        {"type":"user","uuid":"summary","parentUuid":"boundary","isCompactSummary":true,"message":{"content":"summary"}}
        {"type":"assistant","uuid":"a3","parentUuid":"summary","message":{"content":"after summary"}}
        """
        #expect(OMGCanvasClaudeHistory.messages(compacted, sessionID: UUID().uuidString).map(\.id) == ["summary", "a3"])
    }

    @Test @MainActor func historyReadDoesNotLaunchProcessOrAcquireWriter() async throws {
        let fixture = try fixture("stream")
        let id = UUID().uuidString.lowercased()
        let encoded = fixture.directory.resolvingSymlinksInPath().path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let folder = fixture.directory.appendingPathComponent("config/projects/" + encoded)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"uuid\":\"u1\",\"parentUuid\":null,\"message\":{\"content\":\"stored fixture\"}}\n".write(to: folder.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        let lease = try OMGCanvasChatLease(provider: .claude, sessionID: id)
        defer { lease.release() }
        let history = try await fixture.runtime.readHistory(sessionID: id, cwd: fixture.directory.path)
        #expect(history.map(\.text) == ["stored fixture"])
        #expect(try fixture.requests().isEmpty)
    }

    @MainActor private func fixture(_ mode: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omg-claude-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = directory.appendingPathComponent("requests.jsonl")
        FileManager.default.createFile(atPath: capture.path, contents: Data())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = ProcessInfo.processInfo.environment["OMG_CLAUDE_FAKE_SERVER"] ?? root.appendingPathComponent("scripts/tests/fixtures/omg-claude-stream-json.py").path
        let environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": directory.appendingPathComponent("config").path, "OMG_CLAUDE_TEST_MODE": mode, "OMG_CLAUDE_TEST_CAPTURE": capture.path]
        let runtime = OMGCanvasClaudeRuntime(executableURL: URL(fileURLWithPath: script), environment: environment)
        let (events, sink) = AsyncStream<OMGCanvasChatEvent>.makeStream()
        runtime.onEvent = { sink.yield($0) }
        return Fixture(runtime: runtime, directory: directory, capture: capture, events: events)
    }

    @MainActor private struct Fixture {
        let runtime: OMGCanvasClaudeRuntime
        let directory: URL
        let capture: URL
        let events: AsyncStream<OMGCanvasChatEvent>
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        func next(_ predicate: (OMGCanvasChatEvent) -> Bool) async -> OMGCanvasChatEvent? {
            for await event in events { if predicate(event) { return event } }
            return nil
        }
    }
}
