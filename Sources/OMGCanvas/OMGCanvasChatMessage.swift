import Foundation

struct OMGCanvasChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant, system }
    let id: String
    let role: Role
    var text: String
    var isStreaming: Bool = false
}
