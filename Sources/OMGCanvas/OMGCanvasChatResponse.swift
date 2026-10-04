import Foundation

enum OMGCanvasChatResponse: Equatable, Sendable {
    case approve, deny, cancel
    case answers([String: [String]])
}
