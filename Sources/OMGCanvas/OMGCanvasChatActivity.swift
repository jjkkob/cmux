import Foundation

struct OMGCanvasChatActivity: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String
    var isRunning: Bool
}
