import Foundation

/// Versioned, typed request shared by the bundled page and its native host.
struct OMGCanvasBridgeRequest: Decodable {
    enum Method: String, Decodable {
        case snapshot = "canvas.snapshot"
        case create = "session.create"
        case open = "session.open"
        case dismiss = "session.dismiss"
        case positions = "canvas.setPositions"
        case link = "canvas.link"
    }
    struct Position: Codable, Sendable { let id: UUID; let x: Double; let y: Double }
    struct Params: Decodable {
        var id: UUID?
        var title: String?
        var runtime: String?
        var source: UUID?
        var target: UUID?
        var positions: [Position]?
        var viewport: OMGCanvasGraph.Viewport?
    }
    enum Failure: Error { case invalid, unavailable, missingRuntime, createFailed, inactive }
    let version: Int
    let id: UUID
    let method: Method
    let params: Params

    init(body: Any) throws {
        guard JSONSerialization.isValidJSONObject(body) else { throw Failure.invalid }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 256 * 1024 else { throw Failure.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard version == 1 else { throw Failure.invalid }
        if method == .create {
            guard let fields = (body as? [String: Any])?["params"] as? [String: Any],
                  Set(fields.keys).isSubset(of: ["title", "runtime"]) else { throw Failure.invalid }
        }
    }

    static func isTrustedFrame(_ candidate: URL?, expected: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let candidate, candidate.isFileURL, let expected, expected.isFileURL else { return false }
        return candidate.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
    }
}
