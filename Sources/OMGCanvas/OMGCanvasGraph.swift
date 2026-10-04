import Foundation

/// Saved graph metadata, independent of any currently mounted terminal view.
struct OMGCanvasGraph: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable {
        var id: UUID
        var surfaceId: UUID?
        var title: String
        var runtime: String
        var createdAt: String
        var x: Double
        var y: Double
        var requestId: UUID?
    }
    struct Edge: Codable, Equatable, Sendable {
        var id: UUID
        var source: UUID
        var target: UUID
        var kind: String
    }
    struct Viewport: Codable, Equatable, Sendable {
        var x = 0.0
        var y = 0.0
        var scale = 1.0
        var isValid: Bool { x.isFinite && y.isFinite && scale.isFinite && (0.15...3).contains(scale) }
    }
    var nodes: [Node] = []
    var edges: [Edge] = []
    var viewport = Viewport()

    mutating func remapSurfaces(_ mapping: [UUID: UUID]) {
        for index in nodes.indices {
            nodes[index].surfaceId = nodes[index].surfaceId.flatMap { mapping[$0] }
        }
    }

    /// Validate the whole batch before applying any layout mutation.
    mutating func setPositions(_ positions: [OMGCanvasBridgeRequest.Position], viewport: Viewport?) throws {
        let known = Set(nodes.map(\.id))
        guard positions.count <= 2000,
              Set(positions.map(\.id)).count == positions.count,
              positions.allSatisfy({ known.contains($0.id) && $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }),
              viewport?.isValid != false else { throw OMGCanvasBridgeRequest.Failure.invalid }
        let byID = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })
        for index in nodes.indices {
            if let position = byID[nodes[index].id] {
                nodes[index].x = position.x
                nodes[index].y = position.y
            }
        }
        if let viewport { self.viewport = viewport }
    }

    mutating func link(source: UUID, target: UUID) throws {
        guard source != target, nodes.contains(where: { $0.id == source }),
              nodes.contains(where: { $0.id == target }) else {
            throw OMGCanvasBridgeRequest.Failure.invalid
        }
        guard !edges.contains(where: { $0.source == source && $0.target == target && $0.kind == "linked" }) else { return }
        edges.append(Edge(id: UUID(), source: source, target: target, kind: "linked"))
    }
}
