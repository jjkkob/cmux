import Foundation

extension OMGCanvasGraph {
    /// Applies a validated import atomically, preserving user layout, manual links and live bindings.
    mutating func importHistory(_ manifest: OMGCanvasHistoryManifest) throws {
        try manifest.validate()
        guard historyProjectId == nil || historyProjectId == manifest.project.id,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(nodes.compactMap { $0.history?.externalKey }).count == nodes.filter({ $0.history != nil }).count
        else { throw OMGCanvasHistoryManifest.Failure.invalid }
        var updated = self
        let wasFirstImport = historyProjectId == nil
        var sourceToGraph: [UUID: UUID] = [:]
        var existingByExternal = Dictionary(uniqueKeysWithValues: nodes.enumerated().compactMap { index, node in
            node.history.map { ($0.externalKey, index) }
        })
        for imported in manifest.nodes {
            if let index = existingByExternal[imported.history.externalKey] {
                sourceToGraph[imported.id] = updated.nodes[index].id
                updated.nodes[index].title = imported.title
                updated.nodes[index].runtime = imported.runtime
                updated.nodes[index].createdAt = imported.createdAt
                updated.nodes[index].history = imported.history
            } else {
                guard !updated.nodes.contains(where: { $0.id == imported.id }) else { throw OMGCanvasHistoryManifest.Failure.invalid }
                existingByExternal[imported.history.externalKey] = updated.nodes.count
                sourceToGraph[imported.id] = imported.id
                updated.nodes.append(Node(id: imported.id, surfaceId: nil, title: imported.title, runtime: imported.runtime, createdAt: imported.createdAt, x: imported.x, y: imported.y, history: imported.history))
            }
        }
        for imported in manifest.edges {
            guard let source = sourceToGraph[imported.source], let target = sourceToGraph[imported.target] else { throw OMGCanvasHistoryManifest.Failure.invalid }
            if let index = updated.edges.firstIndex(where: { $0.id == imported.id }) {
                let old = updated.edges[index]
                guard old.source == source, old.target == target, old.kind == imported.kind else { throw OMGCanvasHistoryManifest.Failure.invalid }
                updated.edges[index].evidence = imported.evidence
            } else if !updated.edges.contains(where: { $0.source == source && $0.target == target && $0.kind == imported.kind }) {
                updated.edges.append(Edge(id: imported.id, source: source, target: target, kind: imported.kind, evidence: imported.evidence))
            }
        }
        guard updated.nodes.count <= 5000, updated.edges.count <= 15000 else { throw OMGCanvasHistoryManifest.Failure.invalid }
        updated.historyProjectId = manifest.project.id
        if wasFirstImport, let viewport = manifest.viewport { updated.viewport = viewport }
        self = updated
    }
}
