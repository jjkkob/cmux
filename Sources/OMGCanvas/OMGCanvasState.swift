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
    @ObservationIgnored var dismissPresentation: (() -> Void)?

    func changed() { revision &+= 1 }

    func restore(_ graph: OMGCanvasGraph?, mapping: [UUID: UUID]) {
        guard var graph else { return }
        graph.remapSurfaces(mapping)
        self.graph = graph
        selectedId = nil
        presentedSurfaceId = nil
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
