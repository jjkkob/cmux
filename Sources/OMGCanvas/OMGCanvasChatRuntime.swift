import Foundation

/// Provider protocols own a conversation independently of its currently visible chat view.
@MainActor
protocol OMGCanvasChatRuntime: AnyObject {
    var onEvent: ((OMGCanvasChatEvent) -> Void)? { get set }
    func readHistory(sessionID: String, cwd: String) async throws -> [OMGCanvasChatMessage]
    func open(sessionID: String?, cwd: String) async throws
    func send(_ text: String) async throws
    func interrupt() async throws
    func respond(to promptID: String, response: OMGCanvasChatResponse) async throws
    func shutdown()
}
