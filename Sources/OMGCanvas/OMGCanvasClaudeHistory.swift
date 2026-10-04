import Foundation

/// Reads Claude's own durable transcript, following the active parent chain rather than replaying abandoned branches.
actor OMGCanvasClaudeHistory {
    private let environment: [String: String]
    private let fileManager: FileManager

    init(environment: [String: String], fileManager: FileManager = .default) {
        self.environment = environment
        self.fileManager = fileManager
    }

    func read(sessionID: String, cwd: String) throws -> [OMGCanvasChatMessage] {
        guard let uuid = UUID(uuidString: sessionID) else { throw CocoaError(.fileReadInvalidFileName) }
        let id = uuid.uuidString.lowercased()
        let root = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path).appendingPathComponent(".claude").path
        let projects = URL(fileURLWithPath: root.precomposedStringWithCanonicalMapping, isDirectory: true).appendingPathComponent("projects")
        let canonical = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        let encoded = canonical.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        var candidates = [projects.appendingPathComponent(encoded).appendingPathComponent(id + ".jsonl")]
        // Claude's Bun hash for paths longer than 200 characters differs from SDK runtimes.
        if encoded.count > 200 {
            let prefix = String(encoded.prefix(200)) + "-"
            candidates = try fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .map { $0.appendingPathComponent(id + ".jsonl") }
        }
        let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }
        guard existing.count == 1, let url = existing.first else { throw CocoaError(.fileReadNoSuchFile) }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Self.messages(contents, sessionID: id)
    }

    nonisolated static func messages(_ contents: String, sessionID: String) -> [OMGCanvasChatMessage] {
        let linkTypes: Set<String> = ["user", "assistant", "progress", "system", "attachment"]
        let entries: [[String: Any]] = contents.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, linkTypes.contains(type), object["uuid"] is String,
                  (object["sessionId"] as? String).map({ $0.lowercased() == sessionID.lowercased() }) ?? true else { return nil }
            return object
        }
        var byID: [String: [String: Any]] = [:]
        var positions: [String: Int] = [:]
        var parents: Set<String> = []
        for (index, entry) in entries.enumerated() {
            guard let id = entry["uuid"] as? String else { continue }
            byID[id] = entry
            positions[id] = index
            if let parent = entry["parentUuid"] as? String { parents.insert(parent) }
        }
        var leaves: [[String: Any]] = []
        for entry in entries where !parents.contains(entry["uuid"] as? String ?? "") {
            var cursor: [String: Any]? = entry
            var visited: Set<String> = []
            while let value = cursor, let id = value["uuid"] as? String, visited.insert(id).inserted {
                if ["user", "assistant"].contains(value["type"] as? String ?? "") { leaves.append(value); break }
                cursor = (value["parentUuid"] as? String).flatMap { byID[$0] }
            }
        }
        let mainLeaves = leaves.filter { $0["isSidechain"] as? Bool != true && $0["isMeta"] as? Bool != true && $0["teamName"] == nil }
        var cursor = (mainLeaves.isEmpty ? leaves : mainLeaves).max {
            (positions[$0["uuid"] as? String ?? ""] ?? -1) < (positions[$1["uuid"] as? String ?? ""] ?? -1)
        }
        var chain: [[String: Any]] = []
        var visited: Set<String> = []
        while let entry = cursor, let id = entry["uuid"] as? String, visited.insert(id).inserted {
            chain.append(entry)
            cursor = (entry["parentUuid"] as? String).flatMap { byID[$0] }
        }
        return chain.reversed().compactMap { entry in
            guard let type = entry["type"] as? String, ["user", "assistant"].contains(type),
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true, entry["teamName"] == nil,
                  let message = entry["message"] as? [String: Any], let id = entry["uuid"] as? String else { return nil }
            let text: String
            if let content = message["content"] as? String { text = content }
            else {
                text = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined(separator: "\n\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return OMGCanvasChatMessage(id: id, role: type == "user" ? .user : .assistant, text: text)
        }
    }
}
