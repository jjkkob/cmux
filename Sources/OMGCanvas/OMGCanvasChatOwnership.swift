import Foundation

/// Main-actor reservations prevent two windows in this app from writing one conversation.
@MainActor
final class OMGCanvasChatOwnership {
    private var owners: [String: UUID] = [:]

    func claim(provider: OMGCanvasChatProvider, sessionID: String, owner: UUID) -> Bool {
        let key = provider.rawValue + ":" + (UUID(uuidString: sessionID)?.uuidString ?? sessionID)
        guard owners[key] == nil || owners[key] == owner else { return false }
        owners[key] = owner
        return true
    }

    func release(owner: UUID) { owners = owners.filter { $0.value != owner } }
}
