import Foundation
import Observation

/// Workspace-owned state survives presentation changes; app session snapshots persist its graph.
@MainActor @Observable
final class OMGCanvasState {
    var enabled = false
    var graph = OMGCanvasGraph()
    var selectedId: UUID?
    var presentedSurfaceId: UUID?
    var revision = 0
    @ObservationIgnored var refreshPresentation: (() -> Void)?
    @ObservationIgnored var dismissPresentation: (() -> Void)?
    var requestedOpenId: UUID?
    var isChatPresented = false
    var presentedChatNodeID: UUID?
    var chatModels: [UUID: OMGCanvasChatModel] = [:]

    func presentChat(nodeID: UUID) throws {
        guard graph.nodes.contains(where: { $0.id == nodeID }) else { throw OMGCanvasBridgeRequest.Failure.invalid }
        presentedChatNodeID = nodeID
        isChatPresented = true
        presentedSurfaceId = nil
        selectedId = nodeID
        changed()
    }

    func dismissChat() {
        guard isChatPresented else { return }
        isChatPresented = false
        presentedChatNodeID = nil
        changed()
    }

    @discardableResult
    func addChat(conversation: OMGCanvasGraph.Conversation, title: String, requestID: UUID) -> UUID {
        if let existing = graph.nodes.first(where: { $0.requestId == requestID }) { return existing.id }
        let id = UUID()
        graph.nodes.append(.init(id: id, surfaceId: nil, title: title, runtime: conversation.provider,
            createdAt: ISO8601DateFormatter().string(from: Date()), x: Double(graph.nodes.count % 4) * 330 + 100,
            y: Double(graph.nodes.count / 4) * 200 + 130, requestId: requestID, conversation: conversation))
        changed()
        return id
    }

    func changed() { revision &+= 1 }

    func restore(_ graph: OMGCanvasGraph?, mapping: [UUID: UUID]) {
        guard var graph else { return }
        graph.remapSurfaces(mapping)
        self.graph = graph
        selectedId = nil
        requestedOpenId = nil
        presentedSurfaceId = nil
        isChatPresented = false
        presentedChatNodeID = nil
        chatModels.values.forEach { $0.shutdown() }
        chatModels.removeAll()
        changed()
    }

    /// Adding a terminal never establishes a relationship, including when another node is selected.
    @discardableResult
    func add(surfaceId: UUID, title: String, runtime: String, requestId: UUID? = nil, now: Date = Date()) -> UUID {
        if let existing = graph.nodes.first(where: { $0.surfaceId == surfaceId || (requestId != nil && $0.requestId == requestId) }) { return existing.id }
        var x = Double(graph.nodes.count % 4) * 330 + 100
        var y = Double(graph.nodes.count / 4) * 200 + 130
        while graph.nodes.contains(where: { abs($0.x - x) < 290 && abs($0.y - y) < 155 }) { y += 200 }
        x = min(x, 1_000_000)
        let id = UUID()
        graph.nodes.append(OMGCanvasGraph.Node(id: id, surfaceId: surfaceId, title: title, runtime: runtime, createdAt: ISO8601DateFormatter().string(from: now), x: x, y: y, requestId: requestId))
        changed()
        return id
    }
}
