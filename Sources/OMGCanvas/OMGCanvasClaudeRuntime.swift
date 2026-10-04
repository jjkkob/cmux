import Foundation

/// Native chat projection of Claude Code's bidirectional stream-json protocol.
@MainActor
final class OMGCanvasClaudeRuntime: OMGCanvasChatRuntime {
    var onEvent: ((OMGCanvasChatEvent) -> Void)?
    private let executableURL: URL
    private let environment: [String: String]
    private let history: OMGCanvasClaudeHistory
    private var transport: OMGCanvasClaudeTransport?
    private var eventTask: Task<Void, Never>?
    private var lease: OMGCanvasChatLease?
    private var identity: OMGCanvasChatIdentity?
    private var generation = UUID()
    private var ready = false
    private var opening = false
    private var working = false
    private var interruptionRequested = false
    private var shuttingDown = false
    private var stderrTail = ""
    private var controls: [String: Control] = [:]
    private var prompts: [String: Permission] = [:]
    private var assistantID: String?
    private var textBlocks: [Int: String] = [:]
    private var messages: [String: OMGCanvasChatMessage] = [:]
    private var activities: [String: OMGCanvasChatActivity] = [:]
    private var toolBlocks: [Int: String] = [:]
    private var toolInputs: [Int: String] = [:]

    private struct Control {
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }
    private struct Permission {
        let input: [String: Any]
        let questions: [OMGCanvasChatPrompt.Question]
    }

    init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
        history = OMGCanvasClaudeHistory(environment: environment)
    }

    func readHistory(sessionID: String, cwd: String) async throws -> [OMGCanvasChatMessage] {
        do { return try await history.read(sessionID: sessionID, cwd: cwd) }
        catch { throw Failure.historyUnavailable }
    }

    func open(sessionID: String?, cwd: String) async throws {
        guard transport == nil, !opening else { throw Failure.notReady }
        try Task.checkCancellation()
        opening = true
        defer { opening = false }
        shuttingDown = false
        generation = UUID()
        let currentGeneration = generation
        let id: String
        if let sessionID {
            guard let uuid = UUID(uuidString: sessionID) else { throw Failure.invalidResponse }
            id = uuid.uuidString.lowercased()
        } else { id = UUID().uuidString.lowercased() }
        let canonicalCWD = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().path
        let saved = sessionID == nil ? [] : try await readHistory(sessionID: id, cwd: canonicalCWD)
        try Task.checkCancellation()
        guard !shuttingDown, generation == currentGeneration else { throw Failure.closed }
        let nextIdentity = OMGCanvasChatIdentity(provider: .claude, sessionID: id, cwd: canonicalCWD)
        lease = try OMGCanvasChatLease(provider: .claude, sessionID: id)
        identity = nextIdentity
        stderrTail = ""
        messages = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let child = OMGCanvasClaudeTransport()
        transport = child
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        arguments.append(sessionID == nil ? "--session-id=\(id)" : "--resume=\(id)")
        var childEnvironment = environment
        childEnvironment["PWD"] = canonicalCWD
        do {
            let events = try await child.start(executableURL: executableURL, arguments: arguments, environment: childEnvironment, cwd: canonicalCWD, supervisorURL: Bundle.main.url(forResource: "cmux", withExtension: nil, subdirectory: "bin"))
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self, self.generation == currentGeneration else { return }
                    self.receive(event)
                }
            }
            try await control(["subtype": "initialize"], timeout: .seconds(60))
            guard generation == currentGeneration, transport != nil, !shuttingDown else { throw Failure.closed }
            ready = true
            onEvent?(.opened(nextIdentity, messages: saved))
            onEvent?(.status(.idle))
        } catch {
            await child.shutdown()
            lease?.release()
            lease = nil
            transport = nil
            throw error
        }
    }

    func send(_ text: String) async throws {
        guard ready, !shuttingDown, let identity else { throw Failure.closed }
        guard !working, prompts.isEmpty else { throw Failure.notReady }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf8.count <= 1_024 * 1_024 else { throw Failure.inputTooLarge }
        let userID = UUID().uuidString.lowercased()
        let payload: [String: Any] = ["type": "user", "uuid": userID, "session_id": identity.sessionID, "message": ["role": "user", "content": [["type": "text", "text": text]]], "parent_tool_use_id": NSNull()]
        working = true
        assistantID = nil
        textBlocks.removeAll()
        let message = OMGCanvasChatMessage(id: userID, role: .user, text: text)
        messages[userID] = message
        onEvent?(.message(message))
        onEvent?(.status(.working))
        do { try await write(payload) }
        catch {
            onEvent?(.disconnected(error.localizedDescription))
            shutdown()
            throw error
        }
    }

    func interrupt() async throws {
        guard ready, !shuttingDown else { throw Failure.closed }
        guard working || !prompts.isEmpty else { return }
        interruptionRequested = true
        do { try await control(["subtype": "interrupt"], timeout: .seconds(15)) }
        catch { interruptionRequested = false; throw error }
        // The result event is the turn boundary; an interrupt acknowledgement alone is not a completed turn.
    }

    func respond(to promptID: String, response: OMGCanvasChatResponse) async throws {
        guard ready, !shuttingDown else { throw Failure.closed }
        guard let permission = prompts[promptID] else { throw Failure.invalidResponse }
        var result: [String: Any]
        switch response {
        case .approve:
            guard permission.questions.isEmpty else { throw Failure.invalidResponse }
            result = ["behavior": "allow", "updatedInput": permission.input]
        case .answers(let answers):
            guard !permission.questions.isEmpty, Set(answers.keys) == Set(permission.questions.map(\.id)) else { throw Failure.invalidResponse }
            var selected: [String: String] = [:]
            for question in permission.questions {
                guard let values = answers[question.id], !values.isEmpty,
                      question.allowsMultiple || values.count == 1,
                      values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Failure.invalidResponse }
                selected[question.id] = values.joined(separator: ", ")
            }
            var updated = permission.input
            updated["answers"] = selected
            result = ["behavior": "allow", "updatedInput": updated]
        case .deny, .cancel:
            result = ["behavior": "deny", "message": "The user declined this request."]
            if response == .cancel { result["interrupt"] = true; interruptionRequested = true }
        }
        // Deliberately never echo permission_suggestions/updatedPermissions: each approval is one action only.
        try await write(["type": "control_response", "response": ["subtype": "success", "request_id": promptID, "response": result]])
        guard prompts.removeValue(forKey: promptID) != nil else { return }
        onEvent?(.promptResolved(promptID))
        onEvent?(.status(prompts.isEmpty ? .working : .needsInput))
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        ready = false
        failControls(Failure.closed)
        resolvePrompts()
        guard let transport else { lease?.release(); lease = nil; return }
        // Keep the lease until the old writer has actually exited, including its shutdown deadline.
        Task { await transport.shutdown() }
    }

    private func write(_ object: [String: Any], expectedGeneration: UUID? = nil) async throws {
        if let expectedGeneration, expectedGeneration != generation { throw Failure.closed }
        guard let transport else { throw Failure.closed }
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(0x0a)
        try await transport.write(bytes)
    }

    private func control(_ request: [String: Any], timeout: Duration) async throws {
        let id = UUID().uuidString.lowercased()
        let currentGeneration = generation
        guard let child = transport else { throw Failure.closed }
        var requestBytes = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
        requestBytes.append(0x0a)
        let bytes = requestBytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.generation == currentGeneration, let pending = self.controls.removeValue(forKey: id) else { return }
                pending.continuation.resume(throwing: Failure.timeout)
                self.onEvent?(.disconnected(Failure.timeout.localizedDescription))
                self.shutdown()
            }
            controls[id] = Control(continuation: continuation, deadline: deadline)
            Task {
                do {
                    guard generation == currentGeneration, !shuttingDown else { throw Failure.closed }
                    try await child.write(bytes)
                }
                catch {
                    guard generation == currentGeneration else { return }
                    if let pending = controls.removeValue(forKey: id) {
                        pending.deadline.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func receive(_ event: OMGCanvasClaudeTransport.Event) {
        switch event {
        case .line(let data):
            guard !shuttingDown else { return }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                onEvent?(.failure(Failure.invalidResponse.localizedDescription)); return
            }
            receive(root)
        case .diagnostic(let bytes):
            stderrTail = String((stderrTail + String(decoding: bytes, as: UTF8.self)).suffix(4_096))
        case .oversizedLine:
            onEvent?(.disconnected(Failure.invalidResponse.localizedDescription))
            shutdown()
        case .exited:
            ready = false
            working = false
            failControls(Failure.closed)
            resolvePrompts()
            finishMessagesAndActivities()
            lease?.release()
            lease = nil
            transport = nil
            let reason = shuttingDown ? nil : (stderrTail.isEmpty ? Failure.closed.localizedDescription : stderrTail)
            onEvent?(.disconnected(reason))
        }
    }

    private func receive(_ root: [String: Any]) {
        let type = root["type"] as? String ?? ""
        if let session = root["session_id"] as? String, !session.isEmpty,
           let identity, session.lowercased() != identity.sessionID.lowercased() {
            failControls(Failure.identityMismatch)
            onEvent?(.disconnected(Failure.identityMismatch.localizedDescription))
            shutdown()
            return
        }
        switch type {
        case "control_response":
            guard let response = root["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let pending = controls.removeValue(forKey: id) else { return }
            pending.deadline.cancel()
            if response["subtype"] as? String == "success" { pending.continuation.resume() }
            else { pending.continuation.resume(throwing: Failure.provider(response["error"] as? String ?? Failure.invalidResponse.localizedDescription)) }
        case "control_request": receivePermission(root)
        case "control_cancel_request":
            if let id = root["request_id"] as? String, prompts.removeValue(forKey: id) != nil {
                onEvent?(.promptResolved(id))
                onEvent?(.status(prompts.isEmpty ? (working ? .working : .idle) : .needsInput))
            }
        case "stream_event":
            guard root["parent_tool_use_id"] is NSNull || root["parent_tool_use_id"] == nil else { return }
            if let event = root["event"] as? [String: Any] { receiveStream(event) }
        case "assistant":
            guard root["parent_tool_use_id"] is NSNull || root["parent_tool_use_id"] == nil,
                  let value = root["message"] as? [String: Any] else { return }
            let id = value["id"] as? String ?? root["uuid"] as? String ?? UUID().uuidString
            let blocks = value["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            if !text.isEmpty { upsert(id: id, text: text, streaming: false) }
            for block in blocks where block["type"] as? String == "tool_use" {
                tool(block, streamingInput: nil)
            }
            if let error = root["error"] as? String { onEvent?(.failure(error)) }
        case "user":
            let value = root["message"] as? [String: Any] ?? [:]
            for block in value["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, var activity = activities[id] else { continue }
                activity.isRunning = false
                activities[id] = activity
                onEvent?(.activity(activity))
            }
        case "tool_progress":
            if let id = root["tool_use_id"] as? String, let activity = activities[id] { onEvent?(.activity(activity)) }
        case "result":
            working = false
            resolvePrompts()
            finishMessagesAndActivities()
            let stopped = interruptionRequested && root["subtype"] as? String == "error_during_execution"
            interruptionRequested = false
            if root["is_error"] as? Bool == true && !stopped {
                let errors = (root["errors"] as? [String])?.joined(separator: "\n")
                onEvent?(.failure(errors ?? root["result"] as? String ?? Failure.invalidResponse.localizedDescription))
            }
            onEvent?(.status(.idle))
        default: break
        }
    }

    private func receiveStream(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            assistantID = (event["message"] as? [String: Any])?["id"] as? String
            textBlocks.removeAll()
            toolBlocks.removeAll()
            toolInputs.removeAll()
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return }
            if block["type"] as? String == "text" { textBlocks[index] = block["text"] as? String ?? "" }
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                toolBlocks[index] = id
                toolInputs[index] = ""
                tool(block, streamingInput: nil)
            }
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "text_delta", let text = delta["text"] as? String, let id = assistantID {
                textBlocks[index, default: ""] += text
                upsert(id: id, text: textBlocks.keys.sorted().map { textBlocks[$0] ?? "" }.joined(separator: "\n\n"), streaming: true)
            }
            if delta["type"] as? String == "input_json_delta", let text = delta["partial_json"] as? String,
               let id = toolBlocks[index], var activity = activities[id] {
                toolInputs[index, default: ""] += text
                activity.detail = String((toolInputs[index] ?? "").prefix(16_384))
                activities[id] = activity
                onEvent?(.activity(activity))
            }
        case "message_stop":
            if let id = assistantID, var message = messages[id] {
                message.isStreaming = false
                messages[id] = message
                onEvent?(.message(message))
            }
        default: break
        }
    }

    private func upsert(id: String, text: String, streaming: Bool) {
        let message = OMGCanvasChatMessage(id: id, role: .assistant, text: text, isStreaming: streaming)
        messages[id] = message
        onEvent?(.message(message))
    }

    private func tool(_ block: [String: Any], streamingInput: String?) {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
        let detail = streamingInput ?? Self.pretty(block["input"] ?? [:])
        let activity = OMGCanvasChatActivity(id: id, title: name, detail: detail, isRunning: true)
        activities[id] = activity
        onEvent?(.activity(activity))
    }

    private func receivePermission(_ root: [String: Any]) {
        guard let id = root["request_id"] as? String, let request = root["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool", let input = request["input"] as? [String: Any],
              let name = request["tool_name"] as? String else {
            let currentGeneration = generation
            Task { try? await write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported control request"]], expectedGeneration: currentGeneration) }
            return
        }
        let questions: [OMGCanvasChatPrompt.Question] = name == "AskUserQuestion" ? (input["questions"] as? [[String: Any]] ?? []).compactMap { value in
            guard let text = value["question"] as? String else { return nil }
            let options = (value["options"] as? [[String: Any]] ?? []).compactMap { option -> OMGCanvasChatPrompt.Option? in
                guard let label = option["label"] as? String else { return nil }
                return .init(label: label, description: option["description"] as? String ?? "")
            }
            return .init(id: text, text: text, options: options, allowsOther: true, isSecret: false, allowsMultiple: value["multiSelect"] as? Bool ?? false)
        } : []
        prompts[id] = Permission(input: input, questions: questions)
        let title = name == "AskUserQuestion"
            ? String(localized: "omg.chat.claudeQuestionTitle", defaultValue: "Claude needs your input")
            : String(localized: "omg.chat.claudeApprovalTitle", defaultValue: "Claude requests permission")
        onEvent?(.prompt(.init(id: id, kind: name == "AskUserQuestion" ? .questions : .approval, title: title, detail: name + "\n" + Self.pretty(input), questions: questions)))
        onEvent?(.status(.needsInput))
    }

    private func resolvePrompts() {
        let ids = Array(prompts.keys)
        prompts.removeAll()
        for id in ids { onEvent?(.promptResolved(id)) }
    }

    private func finishMessagesAndActivities() {
        for (id, var message) in messages where message.isStreaming {
            message.isStreaming = false
            messages[id] = message
            onEvent?(.message(message))
        }
        for (id, var activity) in activities where activity.isRunning {
            activity.isRunning = false
            activities[id] = activity
            onEvent?(.activity(activity))
        }
    }

    private func failControls(_ error: Error) {
        let pending = controls.values
        controls.removeAll()
        for item in pending { item.deadline.cancel(); item.continuation.resume(throwing: error) }
    }

    private static func pretty(_ value: Any) -> String {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    enum Failure: LocalizedError {
        case closed, notReady, identityMismatch, invalidResponse, timeout, inputTooLarge, historyUnavailable
        case provider(String)
        var errorDescription: String? {
            switch self {
            case .closed: return String(localized: "omg.chat.closed", defaultValue: "The conversation is disconnected. Reopen it to continue.")
            case .notReady: return String(localized: "omg.chat.notReady", defaultValue: "Wait for the current turn or answer the pending request first.")
            case .identityMismatch: return String(localized: "omg.chat.identityMismatch", defaultValue: "The provider returned a different conversation. Reopen it before continuing.")
            case .invalidResponse: return String(localized: "omg.chat.invalidResponse", defaultValue: "The provider returned an unreadable response.")
            case .timeout: return String(localized: "omg.chat.timeout", defaultValue: "The provider did not respond in time. Reopen the conversation before retrying.")
            case .inputTooLarge: return String(localized: "omg.chat.inputTooLarge", defaultValue: "This message is too large to send.")
            case .historyUnavailable: return String(localized: "omg.chat.claudeHistoryUnavailable", defaultValue: "Claude’s saved conversation could not be read in this project.")
            case .provider(let message): return message
            }
        }
    }
}
