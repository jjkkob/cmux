import Foundation

enum OMGCanvasChatEvent: Equatable, Sendable {
    case opened(OMGCanvasChatIdentity, messages: [OMGCanvasChatMessage])
    case message(OMGCanvasChatMessage)
    case activity(OMGCanvasChatActivity)
    case prompt(OMGCanvasChatPrompt)
    case promptResolved(String)
    case status(OMGCanvasChatStatus)
    case failure(String)
    case disconnected(String?)
}
