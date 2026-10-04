import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(OMGCanvasHistoryModel)
@testable import OMGCanvasHistoryModel
#endif

@Suite("OMG canvas history import")
struct OMGCanvasHistoryTests {
    private func manifest() -> OMGCanvasHistoryManifest {
        let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        return OMGCanvasHistoryManifest(version: 1, project: .init(id: "synthetic-project", title: "Example history"), nodes: [
            .init(id: first, title: "Research", runtime: "codex", createdAt: "2026-10-01T12:00:00Z", x: 100, y: 120,
                  history: .init(source: "codex", sessionId: first.uuidString, summary: "Explored approaches.", role: "conductor")),
            .init(id: second, title: "Design", runtime: "claude", createdAt: "", x: 460, y: 320,
                  history: .init(source: "claude", sessionId: second.uuidString, summary: "Compared alternatives.", role: "mission"))
        ], edges: [.init(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, source: first, target: second, kind: "handoff", evidence: "Explicit handoff record.")], viewport: .init(x: 20, y: 20, scale: 0.8))
    }

    @Test func importAddsHistoryWithoutTerminalBindingsOrImplicitConnections() throws {
        let input = manifest()
        let live = OMGCanvasGraph.Node(id: UUID(), surfaceId: UUID(), title: "Existing shell", runtime: "shell", createdAt: "2026-10-03T12:00:00Z", x: -330, y: 0)
        var graph = OMGCanvasGraph(nodes: [live])
        try graph.importHistory(input)
        #expect(graph.nodes.count == 3)
        #expect(graph.nodes.first == live)
        #expect(graph.nodes.dropFirst().allSatisfy { $0.surfaceId == nil })
        #expect(graph.edges == input.edges)
        #expect(graph.nodes.last?.createdAt == "")
        #expect(graph.historyProjectId == input.project.id)
        #expect(graph.viewport == input.viewport)
    }

    @Test func reimportUpdatesMetadataAndKeepsIdentityLayoutManualLinksAndBindings() throws {
        var input = manifest()
        var graph = OMGCanvasGraph()
        try graph.importHistory(input)
        let originalID = graph.nodes[0].id
        let surfaceID = UUID()
        graph.nodes[0].surfaceId = surfaceID
        graph.nodes[0].x = 991
        graph.viewport = .init(x: -80, y: 33, scale: 1.25)
        try graph.link(source: graph.nodes[1].id, target: graph.nodes[0].id)
        let manual = graph.edges.last
        input.nodes[0].id = UUID()
        input.edges[0].source = input.nodes[0].id
        input.nodes[0].title = "Updated research title"
        input.nodes[0].history.summary = "Updated source summary"
        try graph.importHistory(input)
        try graph.importHistory(input)
        #expect(graph.nodes.count == 2)
        #expect(graph.nodes[0].id == originalID)
        #expect(graph.nodes[0].surfaceId == surfaceID)
        #expect(graph.nodes[0].x == 991)
        #expect(graph.nodes[0].title == input.nodes[0].title)
        #expect(graph.nodes[0].history?.summary == input.nodes[0].history.summary)
        #expect(graph.viewport.scale == 1.25)
        #expect(graph.edges.count == 2)
        #expect(graph.edges.last == manual)
        #expect(graph.edges[0].source == originalID)
    }

    @Test func invalidBatchesAreAtomic() throws {
        let valid = manifest()
        var graph = OMGCanvasGraph()
        try graph.importHistory(valid)
        let before = graph
        var cases: [OMGCanvasHistoryManifest] = []
        var candidate = valid; candidate.edges[0].target = UUID(); cases.append(candidate)
        candidate = valid; candidate.edges[0].target = candidate.edges[0].source; cases.append(candidate)
        candidate = valid; candidate.nodes[0].x = .infinity; cases.append(candidate)
        candidate = valid; candidate.nodes[1].history = candidate.nodes[0].history; cases.append(candidate)
        candidate = valid; candidate.edges[0].kind = "assumed_parent"; cases.append(candidate)
        candidate = valid; candidate.nodes[0].createdAt = "yesterday"; cases.append(candidate)
        candidate = valid; candidate.project.id = "different-project"; cases.append(candidate)
        candidate = valid; candidate.version = 2; cases.append(candidate)
        for invalid in cases {
            #expect(throws: (any Error).self) { try graph.importHistory(invalid) }
            #expect(graph == before)
        }
        var collision = valid
        collision.nodes[0].history.sessionId = UUID().uuidString
        #expect(throws: (any Error).self) { try graph.importHistory(collision) }
        #expect(graph == before)
    }

    @Test func manifestDecodingNeverImportsSurfaceOrCommandFields() throws {
        let original = manifest()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var nodes = try #require(object["nodes"] as? [[String: Any]])
        nodes[0]["surfaceId"] = UUID().uuidString
        nodes[0]["command"] = "this field must never execute"
        object["nodes"] = nodes
        let decoded = try OMGCanvasHistoryManifest.decode(JSONSerialization.data(withJSONObject: object))
        var graph = OMGCanvasGraph()
        try graph.importHistory(decoded)
        #expect(graph.nodes.allSatisfy { $0.surfaceId == nil })
        #expect(graph.nodes[0].history == original.nodes[0].history)
        #expect(throws: (any Error).self) { try OMGCanvasHistoryManifest.decode(Data(repeating: 32, count: OMGCanvasHistoryManifest.maximumBytes + 1)) }
    }

    @Test func persistenceRetainsHistoryWhileRemappingOnlyLiveBindings() throws {
        var graph = OMGCanvasGraph()
        try graph.importHistory(manifest())
        let surfaceID = UUID(), replacement = UUID()
        graph.nodes[0].surfaceId = surfaceID
        let data = try JSONEncoder().encode(graph)
        var restored = try JSONDecoder().decode(OMGCanvasGraph.self, from: data)
        restored.remapSurfaces([surfaceID: replacement])
        #expect(restored.nodes[0].surfaceId == replacement)
        #expect(restored.nodes[1].surfaceId == nil)
        #expect(restored.nodes[0].history == graph.nodes[0].history)
        #expect(restored.edges == graph.edges)
        #expect(restored.historyProjectId == graph.historyProjectId)
    }

    @Test func legacyGraphStillDecodes() throws {
        let data = Data(#"{"nodes":[],"edges":[],"viewport":{"x":0,"y":0,"scale":1}}"#.utf8)
        let graph = try JSONDecoder().decode(OMGCanvasGraph.self, from: data)
        #expect(graph.historyProjectId == nil)
        #expect(graph.nodes.isEmpty)
    }

    @Test func sharedNativeHistorySnapshotRoundTrips() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["OMG_CANVAS_HISTORY_FIXTURE"]
            .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Resources/omg-canvas/bridge-fixture.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let snapshot = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: #require(fixture["historySnapshot"])))
        let roundtrip = try JSONDecoder().decode(OMGCanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot.dictionary()))
        #expect(roundtrip.nodes.contains { $0.history != nil && $0.canResume == false })
        #expect(roundtrip.nodes.contains { $0.history != nil && $0.canResume == true })
        #expect(roundtrip.nodes.map(\.history) == snapshot.nodes.map(\.history))
        #expect(roundtrip.edges == snapshot.edges)
        let request = try OMGCanvasBridgeRequest(body: #require(fixture["historyResumeRequest"]))
        #expect(request.method == .resume)
        #expect(request.params.id != nil)
    }
}
