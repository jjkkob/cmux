import Darwin
import Foundation

/// A canvas-owned stdio client. It resumes exact Codex identities and never sends terminal input.
@MainActor
final class OMGCanvasCodexRuntime: OMGCanvasChatRuntime {
    var onEvent: ((OMGCanvasChatEvent) -> Void)?
    private let executableURL: URL
    private let environment: [String: String]
    private let arguments: [String]
    private let requestTimeout: Duration
    private var process: Process?
    private var writer: OMGCanvasChatInputWriter?
    private var readers: [Task<Void, Never>] = []
    private var startup: Task<Void, Error>?
    private var initialized = false
    private var shuttingDown = false
    private var buffer = Data()
    private var stderrTail = ""
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var identity: OMGCanvasChatIdentity?
    private var lease: OMGCanvasChatLease?
    private var activeTurnID: String?
    private var completedTurnIDs: Set<String> = []
    private var connectionID = UUID()
    private var turnStarting = false
    private var messages: [String: OMGCanvasChatMessage] = [:]
    private var activities: [String: OMGCanvasChatActivity] = [:]
    private var prompts: [String: [String: Any]] = [:]

    init(executableURL: URL, environment: [String: String], arguments: [String] = ["app-server", "--listen", "stdio://"], requestTimeout: Duration = .seconds(60)) {
        self.executableURL = executableURL
        self.environment = environment
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    func readHistory(sessionID: String, cwd: String) async throws -> [OMGCanvasChatMessage] {
        try await ensureProcess(cwd: cwd)
        let result = try await request("thread/read", ["threadId": sessionID, "includeTurns": true])
        let thread = try verifiedThread(result, expectedID: sessionID)
        return historyMessages(thread)
    }

    func open(sessionID: String?, cwd: String) async throws {
        if let identity {
            guard sessionID == identity.sessionID else { throw Failure.identityMismatch }
            return
        }
        do {
            if let sessionID { lease = try OMGCanvasChatLease(provider: .codex, sessionID: sessionID) }
            try await ensureProcess(cwd: cwd)
            let result: [String: Any]
            if let sessionID {
                // Reading is separate from resuming, and never replays historical tool calls.
                let stored = try await request("thread/read", ["threadId": sessionID, "includeTurns": true])
                _ = try verifiedThread(stored, expectedID: sessionID)
                result = try await request("thread/resume", ["threadId": sessionID])
            } else {
                result = try await request("thread/start", ["cwd": cwd, "serviceName": "omg-canvas", "threadSource": "user"])
            }
            let thread = try verifiedThread(result, expectedID: sessionID)
            guard let nativeID = thread["id"] as? String else { throw Failure.invalidResponse }
            if lease == nil { lease = try OMGCanvasChatLease(provider: .codex, sessionID: nativeID) }
            let opened = OMGCanvasChatIdentity(provider: .codex, sessionID: nativeID, cwd: thread["cwd"] as? String ?? cwd)
            identity = opened
            let history = historyMessages(thread)
            messages = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            onEvent?(.opened(opened, messages: history))
            if let turns = thread["turns"] as? [[String: Any]], let active = turns.last(where: { $0["status"] as? String == "inProgress" }) {
                activeTurnID = active["id"] as? String
            }
            emitStatus()
        } catch {
            shutdown()
            throw error
        }
    }

    func send(_ text: String) async throws {
        guard let identity, activeTurnID == nil, !turnStarting, prompts.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.notReady }
        guard text.utf8.count <= 1024 * 1024 else { throw Failure.inputTooLarge }
        turnStarting = true
        onEvent?(.status(.working))
        do {
            let result = try await request("turn/start", ["threadId": identity.sessionID, "input": [["type": "text", "text": text, "text_elements": []]]])
            guard let turn = result["turn"] as? [String: Any], let turnID = turn["id"] as? String else { throw Failure.invalidResponse }
            if turn["status"] as? String == "inProgress", !completedTurnIDs.contains(turnID) { activeTurnID = turnID }
            turnStarting = false
            emitStatus()
        } catch {
            turnStarting = false
            if case Failure.timeout = error {
                shutdown()
                onEvent?(.disconnected(error.localizedDescription))
                throw error
            }
            emitStatus()
            throw error
        }
    }

    func interrupt() async throws {
        guard let identity, let activeTurnID else { throw Failure.notReady }
        do {
            _ = try await request("turn/interrupt", ["threadId": identity.sessionID, "turnId": activeTurnID])
        } catch {
            // A turn may finish between the click and cancellation. Read authoritative state;
            // never start another turn or automatically retry an input to resolve that race.
            if self.activeTurnID != activeTurnID { return }
            if let result = try? await request("thread/read", ["threadId": identity.sessionID, "includeTurns": true]),
               let thread = try? verifiedThread(result, expectedID: identity.sessionID),
               let turn = (thread["turns"] as? [[String: Any]])?.first(where: { $0["id"] as? String == activeTurnID }),
               let status = turn["status"] as? String, ["completed", "interrupted", "failed"].contains(status) {
                notification("turn/completed", params: ["threadId": identity.sessionID, "turn": turn])
                return
            }
            throw error
        }
        // Completion notification is authoritative; the response only acknowledges cancellation.
    }

    func respond(to promptID: String, response: OMGCanvasChatResponse) async throws {
        guard let object = prompts[promptID], let id = object["id"], let method = object["method"] as? String else { throw Failure.notReady }
        let params = object["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        if method == "item/tool/requestUserInput" {
            guard case .answers(let answers) = response else { throw Failure.invalidResponse }
            result = ["answers": answers.mapValues { ["answers": $0] }]
        } else if method == "item/permissions/requestApproval" {
            result = ["permissions": response == .approve ? (params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"]
        } else if method == "execCommandApproval" || method == "applyPatchApproval" {
            result = ["decision": response == .approve ? "approved" : response == .cancel ? "abort" : "denied"]
        } else {
            result = ["decision": response == .approve ? "accept" : response == .cancel ? "cancel" : "decline"]
        }
        try await write(["id": id, "result": result])
        prompts.removeValue(forKey: promptID)
        onEvent?(.promptResolved(promptID))
        emitStatus()
    }

    func shutdown() {
        shuttingDown = true
        initialized = false
        startup?.cancel()
        startup = nil
        failPending(Failure.closed)
        readers.forEach { $0.cancel() }
        readers.removeAll()
        if let writer { Task { await writer.close() } }
        writer = nil
        let ownedProcess = process
        process = nil
        let ownedLease = lease
        lease = nil
        if let ownedProcess, ownedProcess.isRunning {
            ownedProcess.terminate()
            // Hold the writer lease until the child actually exits, including an escalation.
            Task { @MainActor in
                for _ in 0..<30 {
                    if !ownedProcess.isRunning { ownedLease?.release(); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if ownedProcess.isRunning { Darwin.kill(ownedProcess.processIdentifier, SIGKILL) }
                ownedLease?.release()
            }
        } else { ownedLease?.release() }
        identity = nil
        activeTurnID = nil
        turnStarting = false
        prompts.removeAll()
        messages.removeAll()
        activities.removeAll()
    }

    private func ensureProcess(cwd: String) async throws {
        if initialized { return }
        if let startup { try await startup.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw Failure.closed }
            try self.launch(cwd: cwd)
            _ = try await self.request("initialize", ["clientInfo": ["name": "omg_canvas", "title": "OMG Canvas", "version": "1"]])
            try await self.write(["method": "initialized"])
            self.initialized = true
        }
        startup = task
        do { try await task.value; startup = nil }
        catch { startup = nil; shutdown(); throw error }
    }

    private func launch(cwd: String) throws {
        shuttingDown = false
        buffer.removeAll()
        stderrTail = ""
        connectionID = UUID()
        completedTurnIDs.removeAll()
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        writer = OMGCanvasChatInputWriter(handle: input.fileHandleForWriting)
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in self?.exited(child) }
        }
        try child.run()
        process = child
        readers = [read(output.fileHandleForReading, isError: false, connectionID: connectionID), read(errors.fileHandleForReading, isError: true, connectionID: connectionID)]
    }

    private func read(_ handle: FileHandle, isError: Bool, connectionID: UUID) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            defer { try? handle.close() }
            while !Task.isCancelled {
                // Pipe reads must return currently available bytes, not wait to fill a file read.
                let data = handle.availableData
                if data.isEmpty { return }
                await self?.consume(data, isError: isError, connectionID: connectionID)
            }
        }
    }

    private func consume(_ data: Data, isError: Bool, connectionID: UUID) {
        guard !shuttingDown, self.connectionID == connectionID else { return }
        if isError {
            stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(4096))
            return
        }
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else { failPending(Failure.invalidResponse); shutdown(); onEvent?(.failure(Failure.invalidResponse.localizedDescription)); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            receive(object)
        }
    }

    private func receive(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            if object["id"] != nil { serverRequest(object, method: method) }
            else { notification(method, params: object["params"] as? [String: Any] ?? [:]) }
            return
        }
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: Failure.provider(error["message"] as? String ?? Failure.invalidResponse.localizedDescription))
        } else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            continuation.resume(returning: data)
        } else { continuation.resume(throwing: Failure.invalidResponse) }
    }

    private func notification(_ method: String, params: [String: Any]) {
        if let threadID = params["threadId"] as? String, let identity, threadID != identity.sessionID { return }
        switch method {
        case "turn/started":
            if let turnID = (params["turn"] as? [String: Any])?["id"] as? String, !completedTurnIDs.contains(turnID) { activeTurnID = turnID }
            turnStarting = false
            emitStatus()
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            if let id = turn["id"] as? String, let activeTurnID, id != activeTurnID { return }
            if let id = turn["id"] as? String { completedTurnIDs.insert(id) }
            activeTurnID = nil
            turnStarting = false
            for (id, var message) in messages where message.isStreaming { message.isStreaming = false; messages[id] = message; onEvent?(.message(message)) }
            for id in prompts.keys { onEvent?(.promptResolved(id)) }
            prompts.removeAll()
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String { onEvent?(.failure(message)) }
            emitStatus()
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            var message = messages[id] ?? OMGCanvasChatMessage(id: id, role: .assistant, text: "", isStreaming: true)
            message.text += delta
            message.isStreaming = true
            messages[id] = message
            onEvent?(.message(message))
        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any] { consumeItem(item, streaming: method == "item/started") }
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String, var activity = activities[id] else { return }
            activity.detail = String((activity.detail + delta).suffix(16000))
            activities[id] = activity
            onEvent?(.activity(activity))
        case "serverRequest/resolved":
            if let id = params["requestId"], let key = requestKey(id), prompts.removeValue(forKey: key) != nil { onEvent?(.promptResolved(key)); emitStatus() }
        case "error":
            if let error = params["error"] as? [String: Any], let message = error["message"] as? String { onEvent?(.failure(message)) }
        default: break
        }
    }

    private func consumeItem(_ item: [String: Any], streaming: Bool) {
        if let message = message(item, streaming: streaming) {
            messages[message.id] = message
            onEvent?(.message(message))
            return
        }
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return }
        let title = item["command"] as? String ?? item["tool"] as? String ?? type
        let detail = item["aggregatedOutput"] as? String ?? item["query"] as? String ?? (item["changes"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) } ?? "")
        let activity = OMGCanvasChatActivity(id: id, title: title, detail: String(detail.suffix(16000)), isRunning: streaming)
        activities[id] = activity
        onEvent?(.activity(activity))
    }

    private func serverRequest(_ object: [String: Any], method: String) {
        guard let id = object["id"], let key = requestKey(id) else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "execCommandApproval", "applyPatchApproval", "item/tool/requestUserInput"]
        guard supported.contains(method) else {
            Task { try? await write(["id": id, "error": ["code": -32601, "message": "Unsupported client request"]]) }
            return
        }
        if let threadID = params["threadId"] as? String, let identity, identity.sessionID != threadID { return }
        prompts[key] = object
        let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { value -> OMGCanvasChatPrompt.Question? in
            guard let questionID = value["id"] as? String, let text = value["question"] as? String else { return nil }
            let options = (value["options"] as? [[String: Any]] ?? []).compactMap { option -> OMGCanvasChatPrompt.Option? in
                guard let label = option["label"] as? String else { return nil }
                return .init(label: label, description: option["description"] as? String ?? "")
            }
            return .init(id: questionID, text: text, options: options, allowsOther: value["isOther"] as? Bool ?? true, isSecret: value["isSecret"] as? Bool ?? false)
        }
        let isQuestion = method == "item/tool/requestUserInput"
        let title = isQuestion ? String(localized: "omg.chat.questionTitle", defaultValue: "Codex needs your input") : String(localized: "omg.chat.approvalTitle", defaultValue: "Codex requests permission")
        let detail = [params["reason"] as? String, params["command"] as? String, params["cwd"] as? String, params["grantRoot"] as? String].compactMap { $0 }.joined(separator: "\n")
        let permissionDetail = (params["permissions"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) }
        onEvent?(.prompt(.init(id: key, kind: isQuestion ? .questions : .approval, title: title, detail: permissionDetail ?? detail, questions: questions)))
        emitStatus()
    }

    private func requestKey(_ id: Any) -> String? {
        if let number = id as? Int { return "n:\(number)" }
        if let string = id as? String { return "s:\(string)" }
        return nil
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let writer else { throw Failure.closed }
        let id = nextRequestID
        nextRequestID += 1
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([0x0A])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self, requestTimeout] in
                do { try await Task.sleep(for: requestTimeout) } catch { return }
                self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timeout)
                self?.deadlines.removeValue(forKey: id)
            }
            Task { [weak self] in
                guard let self else { return }
                do { try await writer.write(payload) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); deadlines.removeValue(forKey: id)?.cancel() }
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        return result
    }

    private func write(_ object: [String: Any]) async throws {
        guard let writer else { throw Failure.closed }
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try await writer.write(data)
    }

    private func verifiedThread(_ result: [String: Any], expectedID: String?) throws -> [String: Any] {
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty else { throw Failure.invalidResponse }
        guard expectedID == nil || expectedID == id else { throw Failure.identityMismatch }
        return thread
    }

    private func historyMessages(_ thread: [String: Any]) -> [OMGCanvasChatMessage] {
        (thread["turns"] as? [[String: Any]] ?? []).flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap { message($0, streaming: false) }
        }
    }

    private func message(_ item: [String: Any], streaming: Bool) -> OMGCanvasChatMessage? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        if type == "agentMessage", let text = item["text"] as? String { return .init(id: id, role: .assistant, text: text, isStreaming: streaming) }
        if type == "userMessage" {
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .init(id: id, role: .user, text: text)
        }
        return nil
    }

    private func emitStatus() { onEvent?(.status(prompts.isEmpty ? (activeTurnID == nil && !turnStarting ? .idle : .working) : .needsInput)) }

    private func failPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        callbacks.forEach { $0.resume(throwing: error) }
    }

    private func exited(_ child: Process) {
        guard process === child else { return }
        let error = Failure.provider(stderrTail.isEmpty ? String(localized: "omg.chat.codexExited", defaultValue: "Codex disconnected. Reopen the conversation to continue.") : stderrTail)
        failPending(error)
        lease?.release()
        lease = nil
        process = nil
        initialized = false
        identity = nil
        activeTurnID = nil
        turnStarting = false
        if !shuttingDown { onEvent?(.disconnected(error.localizedDescription)) }
    }

    enum Failure: LocalizedError {
        case closed, notReady, identityMismatch, invalidResponse, timeout, inputTooLarge
        case provider(String)
        var errorDescription: String? {
            switch self {
            case .closed: return String(localized: "omg.chat.closed", defaultValue: "The conversation is disconnected. Reopen it to continue.")
            case .notReady: return String(localized: "omg.chat.notReady", defaultValue: "Wait for the current turn or answer the pending request first.")
            case .identityMismatch: return String(localized: "omg.chat.identityMismatch", defaultValue: "The provider returned a different conversation. Reopen it before continuing.")
            case .invalidResponse: return String(localized: "omg.chat.invalidResponse", defaultValue: "The provider returned an unreadable response.")
            case .timeout: return String(localized: "omg.chat.timeout", defaultValue: "The provider did not respond in time. Reopen the conversation before retrying.")
            case .inputTooLarge: return String(localized: "omg.chat.inputTooLarge", defaultValue: "This message is too large to send.")
            case .provider(let message): return message
            }
        }
    }
}
