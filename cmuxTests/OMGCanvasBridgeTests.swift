import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("OMG canvas native contract")
struct OMGCanvasBridgeTests {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/omg-canvas/bridge-fixture.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func productionRequestAndSnapshotRoundTrip() throws {
        let data = try fixture()
        let request = try OMGCanvasBridgeRequest(body: #require(data["request"]))
        #expect(request.method == .create)
        #expect(request.params.runtime == "shell")
        let reply = try #require(data["response"] as? [String: Any])
        let value = try #require(reply["value"] as? [String: Any])
        let snapshotData = try JSONSerialization.data(withJSONObject: #require(value["snapshot"]))
        let snapshot = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: snapshotData)
        let encoded = try snapshot.dictionary()
        let decoded = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.nodes.count == 2)
        #expect(decoded.edges.isEmpty)
        #expect(decoded.nodes.last?.title == request.params.title)
        #expect(decoded.terminalOpen)
    }

    @Test func positionRequestIsAtomicAndRestoreKeepsHistory() throws {
        let data = try fixture()
        let request = try OMGCanvasBridgeRequest(body: #require(data["positionsRequest"]))
        let position = try #require(request.params.positions?.first)
        let oldSurface = UUID()
        var graph = OMGCanvasGraph(nodes: [.init(id: position.id, surfaceId: oldSurface, title: "Test", runtime: "shell", createdAt: "2026-10-03T20:00:00Z", x: 0, y: 0)])
        try graph.setPositions(try #require(request.params.positions), viewport: request.params.viewport)
        #expect(graph.nodes.first?.x == 144)
        #expect(graph.viewport.scale == 0.8)
        let prior = graph
        #expect(throws: OMGCanvasBridgeRequest.Failure.self) {
            try graph.setPositions([.init(id: position.id, x: 900, y: 800), .init(id: UUID(), x: 1, y: 1)], viewport: nil)
        }
        #expect(graph == prior)
        let replacement = UUID()
        graph.remapSurfaces([oldSurface: replacement])
        #expect(graph.nodes.first?.id == position.id)
        #expect(graph.nodes.first?.surfaceId == replacement)
        graph.remapSurfaces([:])
        #expect(graph.nodes.count == 1)
        #expect(graph.nodes.first?.surfaceId == nil)
        #expect(try JSONDecoder().decode(OMGCanvasGraph.self, from: JSONEncoder().encode(graph)) == graph)
    }

    @Test func trustBoundaryRejectsOtherFramesAndURLs() {
        let url = URL(fileURLWithPath: "/tmp/app/omg-canvas/index.html")
        #expect(OMGCanvasBridgeRequest.isTrustedFrame(url, expected: url, isMainFrame: true))
        #expect(!OMGCanvasBridgeRequest.isTrustedFrame(url, expected: url, isMainFrame: false))
        #expect(!OMGCanvasBridgeRequest.isTrustedFrame(URL(string: "https://evil.example/"), expected: url, isMainFrame: true))
        #expect(!OMGCanvasBridgeRequest.isTrustedFrame(url.deletingLastPathComponent().appendingPathComponent("other.html"), expected: url, isMainFrame: true))
    }

    @Test @MainActor func createWhileSelectedIsStandaloneUntilExplicitlyConnected() throws {
        let fixture = try fixture()
        let beforeData = try JSONSerialization.data(withJSONObject: #require(fixture["beforeCreateSnapshot"]))
        let before = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: beforeData)
        let request = try OMGCanvasBridgeRequest(body: #require(fixture["request"]))
        let selected = try #require(before.nodes.first)
        let state = OMGCanvasState()
        state.graph.nodes = [.init(id: selected.id, surfaceId: selected.surfaceId, title: selected.title, runtime: selected.runtime, createdAt: selected.createdAt, x: selected.x, y: selected.y)]
        state.selectedId = before.selectedId
        state.presentedSurfaceId = selected.surfaceId

        let added = state.add(surfaceId: UUID(), title: try #require(request.params.title), runtime: try #require(request.params.runtime), requestId: request.id)
        let duplicate = state.add(surfaceId: UUID(), title: try #require(request.params.title), runtime: try #require(request.params.runtime), requestId: request.id)
        #expect(added == duplicate)
        #expect(state.graph.nodes.count == 2)
        #expect(state.graph.edges.isEmpty)
        #expect(state.selectedId == selected.id)

        // The later explicit connect request is a separate production-shaped action.
        var linkBody = try #require(fixture["linkRequest"] as? [String: Any])
        linkBody["params"] = ["source": selected.id.uuidString, "target": added.uuidString]
        let connect = try OMGCanvasBridgeRequest(body: linkBody)
        #expect(connect.method == .link)
        try state.graph.link(source: #require(connect.params.source), target: #require(connect.params.target))
        #expect(state.graph.edges.count == 1)
        #expect(state.graph.edges.first?.kind == "linked")
        #expect(state.graph.edges.first?.source == selected.id)
        #expect(state.graph.edges.first?.target == added)
        let relations = state.graph.edges
        _ = state.add(surfaceId: UUID(), title: "Another terminal", runtime: "shell")
        #expect(state.graph.edges == relations)
    }

    @Test func obsoleteImplicitParentRequestIsRejected() throws {
        let fixture = try fixture()
        #expect(throws: OMGCanvasBridgeRequest.Failure.self) {
            _ = try OMGCanvasBridgeRequest(body: #require(fixture["obsoleteParentRequest"]))
        }
        let linkReply = try #require(fixture["linkResponse"] as? [String: Any])
        let snapshot = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: #require(linkReply["value"])))
        #expect(snapshot.edges.count == 1)
        #expect(snapshot.edges.first?.kind == "linked")
    }
}
