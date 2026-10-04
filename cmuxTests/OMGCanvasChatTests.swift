import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(OMGCanvasChatHarness)
@testable import OMGCanvasChatHarness
#endif

@Suite("OMG real chat model and canvas contract")
struct OMGCanvasChatTests {
    @Test @MainActor func readingHistoryDoesNotResumeOrSend() async {
        let runtime = FakeRuntime()
        let model = makeModel(runtime)
        await model.loadHistory(sessionID: runtime.sessionID, cwd: "/tmp")
        #expect(model.messages == runtime.history)
        #expect(model.identity?.sessionID == runtime.sessionID)
        #expect(!model.isConnected)
        #expect(!model.canSubmit)
        #expect(runtime.opens.isEmpty && runtime.sent.isEmpty)
    }

    @Test @MainActor func resumeKeepsExactNativeIdentityAndCreationIsStandalone() async throws {
        let runtime = FakeRuntime()
        let model = makeModel(runtime)
        let state = OMGCanvasState()
        _ = state.add(surfaceId: UUID(), title: "Existing terminal", runtime: "shell")
        state.selectedId = state.graph.nodes.first?.id
        let requestID = UUID()
        model.onIdentity = { identity in
            let id = state.addChat(conversation: .init(provider: identity.provider.rawValue, sessionID: identity.sessionID, cwd: identity.cwd), title: "Codex", requestID: requestID)
            state.chatModels[id] = model
        }
        try await model.connect(sessionID: runtime.sessionID, cwd: "/tmp")
        #expect(runtime.opens == [runtime.sessionID])
        #expect(state.graph.nodes.count == 2)
        #expect(state.graph.edges.isEmpty)
        let node = try #require(state.graph.nodes.last)
        #expect(node.conversation?.sessionID == runtime.sessionID)
        #expect(node.surfaceId == nil)
        let before = state.graph
        try state.presentChat(nodeID: node.id)
        model.draft = "Retain this draft"
        state.dismissChat()
        try state.presentChat(nodeID: node.id)
        #expect(state.chatModels[node.id] === model)
        #expect(model.draft == "Retain this draft")
        #expect(runtime.opens.count == 1)
        #expect(runtime.shutdowns == 0)
        #expect(state.graph == before)
        let idAgain = state.addChat(conversation: node.conversation!, title: "Codex", requestID: requestID)
        #expect(idAgain == node.id && state.graph.nodes.count == 2)
    }

    @Test @MainActor func ownershipRejectsASecondWriterAcrossModels() async throws {
        let ownership = OMGCanvasChatOwnership()
        let first = FakeRuntime(), second = FakeRuntime()
        let modelA = makeModel(first, ownership: ownership)
        let modelB = makeModel(second, ownership: ownership)
        try await modelA.connect(sessionID: first.sessionID, cwd: "/tmp")
        await #expect(throws: (any Error).self) { try await modelB.connect(sessionID: first.sessionID, cwd: "/tmp") }
        #expect(second.opens.isEmpty)
        modelA.shutdown()
        try await modelB.connect(sessionID: first.sessionID, cwd: "/tmp")
        #expect(second.opens.count == 1)
    }

    @Test @MainActor func mismatchedProviderIdentityNeverEnablesComposer() async {
        let runtime = FakeRuntime()
        runtime.returnedID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let model = makeModel(runtime)
        await #expect(throws: (any Error).self) { try await model.connect(sessionID: runtime.sessionID, cwd: "/tmp") }
        #expect(!model.isConnected)
        model.draft = "Must stay unsent"
        await model.submitDraft()
        #expect(runtime.sent.isEmpty)
        #expect(model.draft == "Must stay unsent")
    }

    @Test @MainActor func actualEventsReplaceStreamingRowsAndPreserveFailedDraft() async throws {
        let runtime = FakeRuntime()
        let model = makeModel(runtime)
        try await model.connect(sessionID: nil, cwd: "/tmp")
        runtime.onEvent?(.message(.init(id: "answer", role: .assistant, text: "Par", isStreaming: true)))
        runtime.onEvent?(.message(.init(id: "answer", role: .assistant, text: "Partial answer", isStreaming: false)))
        #expect(model.messages.filter { $0.id == "answer" }.count == 1)
        #expect(model.messages.last?.text == "Partial answer")
        model.draft = "First line\nSecond line"
        runtime.rejectSend = true
        await model.submitDraft()
        #expect(model.draft == "First line\nSecond line")
        #expect(model.error != nil)
        runtime.rejectSend = false
        await model.submitDraft()
        #expect(model.draft.isEmpty)
        #expect(runtime.sent == ["First line\nSecond line"])
        runtime.onEvent?(.status(.working))
        await model.stop()
        #expect(runtime.interrupts == 1)
        runtime.onEvent?(.disconnected("Disconnected"))
        #expect(!model.isConnected && !model.canSubmit)
        #expect(model.canContinue)
    }

    @Test @MainActor func exactPromptResponseWaitsForProviderResolution() async throws {
        let runtime = FakeRuntime(), model = makeModel(FakeRuntime())
        let target = makeModel(runtime)
        _ = model
        try await target.connect(sessionID: nil, cwd: "/tmp")
        let prompt = OMGCanvasChatPrompt(id: "permission-1", kind: .approval, title: "Permission", detail: "Read file")
        runtime.onEvent?(.prompt(prompt))
        await target.respond(to: "stale-permission", response: .approve)
        #expect(runtime.responses.isEmpty)
        await target.respond(to: prompt.id, response: .deny)
        await target.respond(to: prompt.id, response: .approve)
        #expect(runtime.responses.count == 1)
        #expect(runtime.responses.first?.0 == prompt.id)
        #expect(runtime.responses.first?.1 == .deny)
        #expect(target.prompts.count == 1)
        runtime.onEvent?(.promptResolved(prompt.id))
        #expect(target.prompts.isEmpty)
    }

    @Test func nativeChatSnapshotUsesTheSameBrowserContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = ProcessInfo.processInfo.environment["OMG_CANVAS_CHAT_FIXTURE"].map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent("Resources/omg-canvas/bridge-fixture.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let request = try OMGCanvasBridgeRequest(body: #require(fixture["chatOpenRequest"]))
        #expect(request.method == .open)
        let source = try #require(fixture["chatSnapshot"] as? [String: Any])
        let snapshot = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: source))
        #expect(snapshot.chatOpen && !snapshot.terminalOpen)
        #expect(snapshot.nodes.contains { $0.id == request.params.id })
        #expect(snapshot.nodes.first?.conversation?.provider == "codex")
        let encoded = try snapshot.dictionary()
        #expect(encoded["chatOpen"] as? Bool == true)
        var old = source; old.removeValue(forKey: "chatOpen"); old["terminalOpen"] = true
        let legacy = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(!legacy.chatOpen && legacy.terminalOpen)
    }

    @Test @MainActor func invalidNodeDoesNotChangeSelectionOrLineage() throws {
        let state = OMGCanvasState()
        state.selectedId = state.add(surfaceId: UUID(), title: "Shell", runtime: "shell")
        let before = state.graph, selected = state.selectedId
        #expect(throws: (any Error).self) { try state.presentChat(nodeID: UUID()) }
        #expect(state.graph == before && state.selectedId == selected)
        #expect(!state.isChatPresented)
    }

    @MainActor private func makeModel(_ runtime: FakeRuntime, ownership: OMGCanvasChatOwnership? = nil) -> OMGCanvasChatModel {
        OMGCanvasChatModel(provider: .codex, title: "Synthetic test conversation", runtime: runtime, ownership: ownership ?? OMGCanvasChatOwnership())
    }

    @MainActor private final class FakeRuntime: OMGCanvasChatRuntime {
        var onEvent: ((OMGCanvasChatEvent) -> Void)?
        let sessionID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        var returnedID: String?
        var opens: [String?] = [], sent: [String] = []
        var interrupts = 0, shutdowns = 0
        var rejectSend = false
        var responses: [(String, OMGCanvasChatResponse)] = []
        let history: [OMGCanvasChatMessage] = [.init(id: "saved-turn", role: .assistant, text: "Saved response")]
        func readHistory(sessionID: String, cwd: String) async throws -> [OMGCanvasChatMessage] { history }
        func open(sessionID: String?, cwd: String) async throws {
            opens.append(sessionID)
            onEvent?(.opened(.init(provider: .codex, sessionID: returnedID ?? sessionID ?? self.sessionID, cwd: cwd), messages: history))
            onEvent?(.status(.idle))
        }
        func send(_ text: String) async throws {
            if rejectSend { throw NSError(domain: "test", code: 1) }
            sent.append(text)
        }
        func interrupt() async throws { interrupts += 1 }
        func respond(to promptID: String, response: OMGCanvasChatResponse) async throws { responses.append((promptID, response)) }
        func shutdown() { shutdowns += 1 }
    }
}
