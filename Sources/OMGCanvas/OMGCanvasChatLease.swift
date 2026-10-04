import CryptoKit
import Darwin
import Foundation

/// An advisory cross-process lease for OMG-managed writers, not a detector for external CLI clients.
@MainActor
final class OMGCanvasChatLease {
    private var descriptor: Int32 = -1

    init(provider: OMGCanvasChatProvider, sessionID: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omg-canvas-chat-leases", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data("\(provider.rawValue):\(sessionID)".utf8)).map { String(format: "%02x", $0) }.joined()
        descriptor = Darwin.open(directory.appendingPathComponent(digest).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw Failure.ownedElsewhere
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    enum Failure: LocalizedError {
        case unavailable, ownedElsewhere
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "omg.chat.leaseUnavailable", defaultValue: "The conversation could not be locked for editing.")
            case .ownedElsewhere:
                return String(localized: "omg.chat.ownedElsewhere", defaultValue: "This conversation is already open in another OMG app. Close it there before continuing here.")
            }
        }
    }
}
