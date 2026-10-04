import CmuxAgentChat
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(OMGCanvasChatPreviewHarness)
@testable import OMGCanvasChatPreviewHarness
#endif

@Suite("OMG canvas local chat preview")
struct OMGCanvasChatPreviewTests {
    @Test @MainActor func composerAppendsLocalTurnsWithStableIdentity() throws {
        let model = OMGCanvasChatPreviewModel()
        let initial = model.messages
        model.draft = " \n  "
        model.submitDraft()
        #expect(model.messages == initial)
        #expect(!model.canSubmit)

        model.draft = "  First line\nSecond line  "
        #expect(model.canSubmit)
        model.submitDraft()
        #expect(model.draft.isEmpty)
        #expect(model.submittedMessages.count == 2)
        let first = try #require(model.submittedMessages.first)
        #expect(first.role == .user)
        #expect(first.kind == .prose(ChatProse(text: "First line\nSecond line")))
        #expect(model.submittedMessages.last?.role == .agent)
        #expect(model.scrollAnchor == model.submittedMessages.last?.id)

        model.draft = "Another local turn"
        model.submitDraft()
        #expect(model.messages.prefix(initial.count).elementsEqual(initial))
        #expect(model.submittedMessages.first == first)
        #expect(Set(model.messages.map(\.id)).count == model.messages.count)
        #expect(model.messages.map(\.seq) == model.messages.map(\.seq).sorted())
        #expect(model.submittedMessages.count == 4)
    }

    @Test @MainActor func workingKeepsDraftUntilSimulationStops() {
        let model = OMGCanvasChatPreviewModel()
        model.selectScenario(.working)
        model.draft = "Keep this draft"
        let before = model.messages
        #expect(model.isWorking)
        #expect(!model.canSubmit)
        model.submitDraft()
        #expect(model.draft == "Keep this draft")
        #expect(model.messages == before)

        model.stop()
        #expect(model.hasStopped)
        #expect(!model.isWorking)
        #expect(model.canSubmit)
        model.submitDraft()
        #expect(model.submittedMessages.count == 2)
        model.stop()
        #expect(model.submittedMessages.count == 2)
    }

    @Test @MainActor func fixtureChoicesAndReviewKeepConversationState() {
        let model = OMGCanvasChatPreviewModel()
        model.choose(.detailed)
        #expect(model.selectedChoice == nil)
        model.selectScenario(.needsInput)
        model.choose(.compact)
        model.choose(.detailed)
        #expect(model.selectedChoice == .compact)
        model.draft = "A retained draft"
        model.activityExpanded = true
        model.scrollAnchor = "fixture-user"
        model.reviewChanges()
        #expect(model.isReviewVisible)
        model.backToConversation()
        #expect(!model.isReviewVisible)
        #expect(model.draft == "A retained draft")
        #expect(model.activityExpanded)
        #expect(model.scrollAnchor == "fixture-user")

        model.submitDraft()
        let localTurns = model.submittedMessages
        model.selectScenario(.results)
        #expect(model.selectedChoice == nil)
        #expect(!model.hasStopped)
        #expect(!model.isWorking)
        #expect(model.submittedMessages == localTurns)
    }

    @Test @MainActor func sharedPreviewRequestsPreserveGraphAndBindings() throws {
        let shared = try fixture()
        let snapshot = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: #require(shared["previewSnapshot"])))
        let state = OMGCanvasState()
        state.graph = graph(from: snapshot)
        let before = state.graph
        let workspaceRequest = try OMGCanvasBridgeRequest(body: #require(shared["previewRequest"]))
        #expect(workspaceRequest.method == .preview)
        #expect(workspaceRequest.params.id == nil)
        let workspaceModel = try state.presentChatPreview(nodeID: workspaceRequest.params.id)
        #expect(state.isChatPreviewPresented)
        #expect(state.presentedPreviewNodeID == nil)
        #expect(state.graph == before)

        let nodeRequest = try OMGCanvasBridgeRequest(body: #require(shared["nodePreviewRequest"]))
        #expect(nodeRequest.method == .preview)
        let nodeID = try #require(nodeRequest.params.id)
        let nodeModel = try state.presentChatPreview(nodeID: nodeID)
        #expect(nodeModel !== workspaceModel)
        #expect(state.presentedPreviewNodeID == nodeID)
        #expect(state.selectedId == nodeID)
        nodeModel.draft = "A local experiment"
        nodeModel.submitDraft()
        nodeModel.selectScenario(.working)
        nodeModel.stop()
        nodeModel.selectScenario(.needsInput)
        nodeModel.choose(.detailed)
        nodeModel.reviewChanges()
        state.dismissChatPreview()
        #expect(!state.isChatPreviewPresented)
        #expect(state.graph == before)
        #expect(state.requestedOpenId == nil)
    }

    @Test @MainActor func previewCacheKeepsPerNodeDraftsWithoutSharingThem() throws {
        let state = OMGCanvasState()
        let firstID = state.add(surfaceId: UUID(), title: "First terminal", runtime: "shell")
        let secondID = state.add(surfaceId: UUID(), title: "Second terminal", runtime: "shell")
        let before = state.graph
        state.presentedSurfaceId = state.graph.nodes[0].surfaceId
        let first = try state.presentChatPreview(nodeID: firstID)
        #expect(state.presentedSurfaceId == nil)
        first.draft = "First draft"
        first.activityExpanded = true
        first.selectScenario(.needsInput)
        first.scrollAnchor = "fixture-intro"
        first.choose(.compact)
        state.dismissChatPreview()

        let second = try state.presentChatPreview(nodeID: secondID)
        #expect(second !== first)
        #expect(second.draft.isEmpty)
        second.draft = "Second draft"
        let workspace = try state.presentChatPreview(nodeID: nil)
        #expect(workspace !== first && workspace !== second)
        #expect(workspace.draft.isEmpty)
        let reopened = try state.presentChatPreview(nodeID: firstID)
        #expect(reopened === first)
        #expect(reopened.draft == "First draft")
        #expect(reopened.activityExpanded)
        #expect(reopened.scrollAnchor == "fixture-intro")
        #expect(reopened.selectedChoice == .compact)
        #expect(state.graph == before)

        state.restore(before, mapping: [:])
        #expect(!state.isChatPreviewPresented)
        let restored = try state.presentChatPreview(nodeID: firstID)
        #expect(restored !== first)
        #expect(restored.draft.isEmpty)
    }

    @Test @MainActor func invalidPreviewTargetLeavesCurrentPresentationUntouched() throws {
        let state = OMGCanvasState()
        let id = state.add(surfaceId: UUID(), title: "Terminal", runtime: "shell")
        let model = try state.presentChatPreview(nodeID: id)
        model.draft = "Unsaved local draft"
        let graphBefore = state.graph
        let revisionBefore = state.revision
        #expect(throws: OMGCanvasBridgeRequest.Failure.invalid) { try state.presentChatPreview(nodeID: UUID()) }
        #expect(state.graph == graphBefore)
        #expect(state.revision == revisionBefore)
        #expect(state.presentedPreviewNodeID == id)
        #expect(state.isChatPreviewPresented)
        #expect(try state.presentChatPreview(nodeID: id) === model)
        #expect(model.draft == "Unsaved local draft")
    }

    @Test func previewRequestRejectsDispatchFieldsAndMalformedIDs() throws {
        let shared = try fixture()
        var body = try #require(shared["previewRequest"] as? [String: Any])
        let invalidParams: [[String: Any]] = [
            ["runtime": "codex"], ["command": "provider must not execute"],
            ["title": "Create a session"], ["parentId": UUID().uuidString],
            ["id": NSNull()], ["id": "not-a-node-id"]
        ]
        for params in invalidParams {
            body["params"] = params
            #expect(throws: (any Error).self) { try OMGCanvasBridgeRequest(body: body) }
        }
    }

    @Test func sharedSnapshotSeparatesPreviewAndTerminalPresentation() throws {
        let shared = try fixture()
        let input = try #require(shared["previewSnapshot"] as? [String: Any])
        let preview = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: input))
        #expect(preview.previewOpen)
        #expect(!preview.terminalOpen)
        let encoded = try preview.dictionary()
        #expect(encoded["previewOpen"] as? Bool == true)
        #expect(encoded["terminalOpen"] as? Bool == false)
        #expect(try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: encoded)).nodes.count == preview.nodes.count)

        var legacy = input
        legacy.removeValue(forKey: "previewOpen")
        legacy["terminalOpen"] = true
        let terminal = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!terminal.previewOpen)
        #expect(terminal.terminalOpen)
        let terminalEncoded = try terminal.dictionary()
        #expect(terminalEncoded["previewOpen"] as? Bool == false)
        #expect(terminalEncoded["terminalOpen"] as? Bool == true)
    }

    private func graph(from snapshot: OMGCanvasSnapshot) -> OMGCanvasGraph {
        OMGCanvasGraph(nodes: snapshot.nodes.map { node in
            OMGCanvasGraph.Node(id: node.id, surfaceId: node.surfaceId, title: node.title, runtime: node.runtime, createdAt: node.createdAt, x: node.x, y: node.y, history: node.history)
        }, edges: snapshot.edges, viewport: snapshot.viewport)
    }

    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configured = ProcessInfo.processInfo.environment["OMG_CANVAS_CHAT_PREVIEW_FIXTURE"]
        let url = configured.map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent("Resources/omg-canvas/bridge-fixture.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
