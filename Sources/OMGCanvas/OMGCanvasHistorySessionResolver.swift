import CmuxAgentSessionStore
import Foundation

/// Matches imported identities to records independently discovered by cmux's local session index.
struct OMGCanvasHistorySessionResolver: Sendable {
    let loader: SessionIndexSnapshotLoader
    let repository: any AmpHookSessionReading

    func resolve(_ nodes: [OMGCanvasGraph.Node]) async -> [UUID: SessionEntry] {
        let entries = await loader.load(ampSessionRepository: repository)
        var result: [UUID: SessionEntry] = [:]
        for node in nodes {
            guard let history = node.history, ["codex", "claude"].contains(history.source),
                  history.source == node.runtime, let nativeID = UUID(uuidString: history.sessionId) else { continue }
            let matches = entries.filter { entry in
                entry.agent.rawValue == node.runtime && UUID(uuidString: entry.sessionId) == nativeID
                    && entry.fileURL?.isFileURL == true
                    && entry.resumeLaunch?.strategy == .restoreVerb
            }
            guard matches.count == 1, let entry = matches.first else { continue }
            result[node.id] = entry
        }
        return result
    }
}
