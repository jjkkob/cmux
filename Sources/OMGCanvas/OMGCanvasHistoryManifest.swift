import Foundation

/// Versioned metadata-only import. Native terminal identities and launch commands are never imported.
struct OMGCanvasHistoryManifest: Codable, Sendable {
    struct Project: Codable, Sendable {
        var id: String
        var title: String
    }
    struct Node: Codable, Sendable {
        var id: UUID
        var title: String
        var runtime: String
        var createdAt: String
        var x: Double
        var y: Double
        var history: OMGCanvasGraph.History
    }
    enum Failure: Error { case invalid }
    static let maximumBytes = 16 * 1024 * 1024
    static let edgeKinds: Set<String> = ["spawn", "fork", "handoff", "continuation", "linked", "created_from"]
    var version: Int
    var project: Project
    var nodes: [Node]
    var edges: [OMGCanvasGraph.Edge]
    var viewport: OMGCanvasGraph.Viewport?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        let ids = Set(nodes.map(\.id))
        guard version == 1, Self.text(project.id, limit: 256), Self.text(project.title, limit: 160),
              !nodes.isEmpty, nodes.count <= 5000, edges.count <= 15000,
              ids.count == nodes.count,
              Set(nodes.map { $0.history.externalKey }).count == nodes.count,
              Set(edges.map(\.id)).count == edges.count,
              viewport?.isValid != false else { throw Failure.invalid }
        for node in nodes {
            let history = node.history
            guard Self.text(node.title, limit: 2000), ["codex", "claude", "shell", "python", "unknown"].contains(node.runtime),
                  Self.date(node.createdAt), Self.coordinate(node.x), Self.coordinate(node.y),
                  Self.text(history.source, limit: 100), Self.text(history.sessionId, limit: 512),
                  !history.source.contains("\u{001F}"), !history.sessionId.contains("\u{001F}"),
                  history.summary.map({ $0.count <= 32000 }) ?? true,
                  history.updatedAt.map(Self.date) ?? true,
                  history.role.map({ Self.text($0, limit: 80) }) ?? true,
                  history.status.map({ $0.count <= 500 }) ?? true,
                  history.cwd.map({ $0.count <= 4096 }) ?? true,
                  history.runtimeConfig.map({ $0.count <= 2000 }) ?? true,
                  (history.references?.count ?? 0) <= 100,
                  history.references?.allSatisfy({ Self.text($0.label, limit: 500) && Self.text($0.value, limit: 8000) }) ?? true
            else { throw Failure.invalid }
        }
        for edge in edges {
            guard ids.contains(edge.source), ids.contains(edge.target), edge.source != edge.target,
                  Self.edgeKinds.contains(edge.kind), edge.evidence.map({ $0.count <= 16000 }) ?? true
            else { throw Failure.invalid }
        }
    }

    private static func text(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit && !value.contains("\0")
    }
    private static func coordinate(_ value: Double) -> Bool { value.isFinite && abs(value) <= 1_000_000 }
    private static func date(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.count <= 64 else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}
