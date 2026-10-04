import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(OMGCanvasCodexHarness)
@testable import OMGCanvasCodexHarness
#endif

@Suite("OMG Codex protocol client", .serialized)
struct OMGCanvasCodexRuntimeTests {
    @Test @MainActor func splitUTF8AndLateStartReplyKeepCompletedTurnIdle() async throws {
        let context = try fixture("stream")
        let runtime = context.runtime
        defer { runtime.shutdown() }
        var events: [OMGCanvasChatEvent] = []
        runtime.onEvent = { events.append($0) }
        try await runtime.open(sessionID: nil, cwd: context.directory.path)
        try await runtime.send("First prompt")
        #expect(events.contains(.message(.init(id: "agent-1", role: .assistant, text: "Hello 🌱", isStreaming: true))))
        #expect(events.contains(.message(.init(id: "agent-1", role: .assistant, text: "Hello 🌱"))))
        #expect(events.last == .status(.idle))
        try await runtime.send("Second prompt")
        #expect(events.last == .status(.idle))
        #expect(try context.requests().filter { $0["method"] as? String == "turn/start" }.count == 2)
    }

    @Test @MainActor func historyReadDoesNotResumeAndOpenUsesExactID() async throws {
        let context = try fixture("history")
        defer { context.runtime.shutdown() }
        let history = try await context.runtime.readHistory(sessionID: context.nativeID, cwd: context.directory.path)
        #expect(history.map(\.id) == ["history-user", "history-agent"])
        #expect(!((try context.requests()).contains { $0["method"] as? String == "thread/resume" }))
        var opened: OMGCanvasChatIdentity?
        context.runtime.onEvent = { if case .opened(let identity, _) = $0 { opened = identity } }
        try await context.runtime.open(sessionID: context.nativeID, cwd: context.directory.path)
        #expect(opened?.sessionID == context.nativeID)
        #expect(opened?.provider == .codex)
        #expect(try context.requests().filter { $0["method"] as? String == "thread/resume" }.count == 1)
        #expect(!((try context.requests()).contains { $0["method"] as? String == "turn/start" }))
    }

    @Test @MainActor func mismatchedHistoryNeverResumes() async throws {
        let context = try fixture("mismatch")
        defer { context.runtime.shutdown() }
        await #expect(throws: (any Error).self) { try await context.runtime.open(sessionID: context.nativeID, cwd: context.directory.path) }
        #expect(!((try context.requests()).contains { $0["method"] as? String == "thread/resume" }))
    }

    @Test @MainActor func interruptUsesTurnIdentityAndKeepsProcessUsable() async throws {
        let context = try fixture("interrupt")
        defer { context.runtime.shutdown() }
        var events: [OMGCanvasChatEvent] = []
        context.runtime.onEvent = { events.append($0) }
        try await context.runtime.open(sessionID: nil, cwd: context.directory.path)
        try await context.runtime.send("Work")
        try await context.runtime.interrupt()
        try await wait { events.last == .status(.idle) }
        let request = try #require(context.requests().first { $0["method"] as? String == "turn/interrupt" })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["threadId"] as? String == context.nativeID)
        #expect(params["turnId"] as? String == "turn-1")
        try await context.runtime.send("Again")
        try await context.runtime.interrupt()
    }

    @Test @MainActor func approvalsAndQuestionsRequireExactExplicitReplies() async throws {
        let context = try fixture("approval")
        defer { context.runtime.shutdown() }
        var prompts: [OMGCanvasChatPrompt] = []
        context.runtime.onEvent = { if case .prompt(let prompt) = $0 { prompts.append(prompt) } }
        try await context.runtime.open(sessionID: nil, cwd: context.directory.path)
        try await context.runtime.send("Need permission")
        try await wait { prompts.count == 1 }
        #expect(!((try context.requests()).contains { $0["id"] as? Int == 901 }))
        await #expect(throws: (any Error).self) { try await context.runtime.respond(to: "wrong", response: .approve) }
        try await context.runtime.respond(to: prompts[0].id, response: .deny)
        try await wait { prompts.count == 2 }
        #expect(prompts[1].questions.first?.id == "tone")
        try await context.runtime.respond(to: prompts[1].id, response: .answers(["tone": ["Calm"]]))
        try await wait { (try? context.requests().contains { $0["id"] as? String == "question-902" }) == true }
        let response = try #require(context.requests().first { $0["id"] as? Int == 901 })
        #expect((response["result"] as? [String: String])?["decision"] == "decline")
    }

    @Test @MainActor func alreadyCompletedInterruptReconcilesWithoutRetry() async throws {
        let context = try fixture("interrupt_complete")
        defer { context.runtime.shutdown() }
        var status = OMGCanvasChatStatus.idle
        context.runtime.onEvent = { if case .status(let next) = $0 { status = next } }
        try await context.runtime.open(sessionID: nil, cwd: context.directory.path)
        try await context.runtime.send("Work")
        try await context.runtime.interrupt()
        #expect(status == .idle)
        let requests = try context.requests()
        #expect(requests.filter { $0["method"] as? String == "turn/interrupt" }.count == 1)
        #expect(requests.filter { $0["method"] as? String == "turn/start" }.count == 1)
        #expect(requests.filter { $0["method"] as? String == "thread/read" }.count == 1)
    }

    @Test @MainActor func requestTimeoutIsBounded() async throws {
        let context = try fixture("timeout", timeout: .milliseconds(50))
        defer { context.runtime.shutdown() }
        await #expect(throws: (any Error).self) { try await context.runtime.open(sessionID: nil, cwd: context.directory.path) }
    }

    @MainActor private func fixture(_ mode: String, timeout: Duration = .seconds(3)) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omg-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture = directory.appendingPathComponent("requests.jsonl")
        FileManager.default.createFile(atPath: capture.path, contents: Data())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = ProcessInfo.processInfo.environment["OMG_CODEX_FAKE_SERVER"] ?? root.appendingPathComponent("scripts/tests/fixtures/omg-codex-app-server.py").path
        let nativeID = UUID().uuidString
        let environment = ProcessInfo.processInfo.environment.merging(["OMG_CODEX_TEST_MODE": mode, "OMG_CODEX_TEST_CAPTURE": capture.path, "OMG_CODEX_TEST_THREAD_ID": nativeID]) { _, value in value }
        return Fixture(runtime: OMGCanvasCodexRuntime(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), environment: environment, arguments: [script], requestTimeout: timeout), directory: directory, capture: capture, nativeID: nativeID)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitFailure.expired
    }

    private enum WaitFailure: Error { case expired }

    @MainActor private struct Fixture {
        let runtime: OMGCanvasCodexRuntime
        let directory: URL
        let capture: URL
        let nativeID: String
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
    }
}
