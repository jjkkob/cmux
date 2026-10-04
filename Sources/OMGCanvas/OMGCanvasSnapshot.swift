import Foundation

/// The v1 snapshot is the sole producer schema for bridge replies and pushed events.
struct OMGCanvasSnapshot: Codable {
    struct WorkspaceInfo: Codable { var id: UUID; var title: String }
    struct Runtime: Codable { var id: String; var label: String; var available: Bool }
    struct Node: Codable {
        var id: UUID
        var surfaceId: UUID?
        var title: String
        var runtime: String
        var createdAt: String
        var x: Double
        var y: Double
        var available: Bool?
    }
    var version = 1
    var revision: Int
    var locale: String
    var workspace: WorkspaceInfo
    var nodes: [Node]
    var edges: [OMGCanvasGraph.Edge]
    var selectedId: UUID?
    var terminalOpen: Bool
    var viewport: OMGCanvasGraph.Viewport
    var runtimes: [Runtime]

    func dictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OMGCanvasBridgeRequest.Failure.invalid }
        if selectedId == nil { value["selectedId"] = NSNull() }
        value["nodes"] = (value["nodes"] as? [[String: Any]] ?? []).map { node in
            var node = node
            if node["surfaceId"] == nil { node["surfaceId"] = NSNull() }
            if node["available"] == nil { node["available"] = NSNull() }
            return node
        }
        return value
    }
}
