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
        var history: OMGCanvasGraph.History? = nil
        var canResume: Bool? = nil
        var conversation: OMGCanvasGraph.Conversation? = nil
        var chatStatus: String? = nil
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
    var chatOpen = false

    init(revision: Int, locale: String, workspace: WorkspaceInfo, nodes: [Node], edges: [OMGCanvasGraph.Edge], selectedId: UUID?, terminalOpen: Bool, viewport: OMGCanvasGraph.Viewport, runtimes: [Runtime], chatOpen: Bool = false) {
        self.revision = revision
        self.locale = locale
        self.workspace = workspace
        self.nodes = nodes
        self.edges = edges
        self.selectedId = selectedId
        self.terminalOpen = terminalOpen
        self.viewport = viewport
        self.runtimes = runtimes
        self.chatOpen = chatOpen
    }

    private enum CodingKeys: String, CodingKey {
        case version, revision, locale, workspace, nodes, edges, selectedId, terminalOpen, viewport, runtimes, chatOpen
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        revision = try values.decode(Int.self, forKey: .revision)
        locale = try values.decode(String.self, forKey: .locale)
        workspace = try values.decode(WorkspaceInfo.self, forKey: .workspace)
        nodes = try values.decode([Node].self, forKey: .nodes)
        edges = try values.decode([OMGCanvasGraph.Edge].self, forKey: .edges)
        selectedId = try values.decodeIfPresent(UUID.self, forKey: .selectedId)
        terminalOpen = try values.decode(Bool.self, forKey: .terminalOpen)
        viewport = try values.decode(OMGCanvasGraph.Viewport.self, forKey: .viewport)
        runtimes = try values.decode([Runtime].self, forKey: .runtimes)
        chatOpen = try values.decodeIfPresent(Bool.self, forKey: .chatOpen) ?? false
    }

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
