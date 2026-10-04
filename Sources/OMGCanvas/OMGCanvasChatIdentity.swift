import Foundation

struct OMGCanvasChatIdentity: Codable, Equatable, Sendable {
    let provider: OMGCanvasChatProvider
    let sessionID: String
    let cwd: String
}
