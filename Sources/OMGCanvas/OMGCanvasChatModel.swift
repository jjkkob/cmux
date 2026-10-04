import Foundation
import Observation

/// Real provider state outlives its floating presentation; dismissing chat never stops its runtime.
@MainActor @Observable
final class OMGCanvasChatModel {
    let provider: OMGCanvasChatProvider
    let title: String
    private(set) var identity: OMGCanvasChatIdentity?
    private(set) var messages: [OMGCanvasChatMessage] = []
    private(set) var activities: [OMGCanvasChatActivity] = []
    private(set) var prompts: [OMGCanvasChatPrompt] = []
    private(set) var status: OMGCanvasChatStatus = .idle
    private(set) var isConnected = false
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    var error: String?
    var draft = ""
    var scrollAnchor: String?
    var canContinue = false
    var readOnlyReason: String?
    @ObservationIgnored var onIdentity: ((OMGCanvasChatIdentity) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let runtime: (any OMGCanvasChatRuntime)?
    @ObservationIgnored private let ownership: OMGCanvasChatOwnership
    @ObservationIgnored private let ownerID = UUID()
    @ObservationIgnored private var expectedSessionID: String?
    @ObservationIgnored private var pendingResponses: Set<String> = []

    init(provider: OMGCanvasChatProvider, title: String, runtime: (any OMGCanvasChatRuntime)?, ownership: OMGCanvasChatOwnership) {
        self.provider = provider
        self.title = title
        self.runtime = runtime
        self.ownership = ownership
        runtime?.onEvent = { [weak self] event in self?.receive(event) }
    }

    var isWorking: Bool { isConnected && status == .working }
    var canSubmit: Bool { isConnected && status == .idle && !isSubmitting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var statusLabel: String {
        if isLoading { return String(localized: "omg.chat.loading", defaultValue: "Loading…") }
        if !isConnected { return String(localized: "omg.chat.readOnly", defaultValue: "Read only") }
        switch status {
        case .idle: return String(localized: "omg.chatPreview.ready", defaultValue: "Ready")
        case .working: return String(localized: "omg.chatPreview.working", defaultValue: "Working")
        case .needsInput: return String(localized: "omg.chatPreview.needsInput", defaultValue: "Needs input")
        }
    }

    func loadHistory(sessionID: String, cwd: String) async {
        guard !isLoading, !isConnected else { return }
        guard let runtime else { error = Failure.notConnected.localizedDescription; return }
        isLoading = true
        expectedSessionID = sessionID
        identity = .init(provider: provider, sessionID: sessionID, cwd: cwd)
        defer { isLoading = false; onChange?() }
        do { messages = try await runtime.readHistory(sessionID: sessionID, cwd: cwd) }
        catch { self.error = error.localizedDescription }
    }

    func connect(sessionID: String?, cwd: String) async throws {
        guard !isLoading, !isConnected else { return }
        guard let runtime else { throw Failure.notConnected }
        if let sessionID, !ownership.claim(provider: provider, sessionID: sessionID, owner: ownerID) {
            throw Failure.writerConflict
        }
        isLoading = true
        expectedSessionID = sessionID
        error = nil
        defer { isLoading = false; onChange?() }
        do {
            try await runtime.open(sessionID: sessionID, cwd: cwd)
            guard isConnected else { throw Failure.notConnected }
        } catch {
            ownership.release(owner: ownerID)
            runtime.shutdown()
            self.error = error.localizedDescription
            throw error
        }
    }

    func submitDraft() async {
        guard canSubmit, let runtime else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        error = nil
        defer { isSubmitting = false; onChange?() }
        do {
            try await runtime.send(text)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        guard isConnected, status == .working, let runtime else { return }
        do { try await runtime.interrupt() }
        catch { self.error = error.localizedDescription }
    }

    func respond(to promptID: String, response: OMGCanvasChatResponse) async {
        guard let runtime, isConnected, prompts.contains(where: { $0.id == promptID }), pendingResponses.insert(promptID).inserted else { return }
        do { try await runtime.respond(to: promptID, response: response) }
        catch { pendingResponses.remove(promptID); self.error = error.localizedDescription }
    }

    func shutdown() {
        runtime?.shutdown()
        ownership.release(owner: ownerID)
        isConnected = false
    }

    private func receive(_ event: OMGCanvasChatEvent) {
        switch event {
        case .opened(let identity, let messages):
            guard identity.provider == provider,
                  expectedSessionID == nil || expectedSessionID == identity.sessionID,
                  ownership.claim(provider: provider, sessionID: identity.sessionID, owner: ownerID) else {
                error = Failure.identityMismatch.localizedDescription
                runtime?.shutdown()
                return
            }
            self.identity = identity
            self.messages = messages
            isConnected = true
            canContinue = true
            readOnlyReason = nil
            onIdentity?(identity)
        case .message(let message):
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
            else { messages.append(message) }
            scrollAnchor = message.id
        case .activity(let activity):
            if let index = activities.firstIndex(where: { $0.id == activity.id }) { activities[index] = activity }
            else { activities.append(activity) }
        case .prompt(let prompt):
            if let index = prompts.firstIndex(where: { $0.id == prompt.id }) { prompts[index] = prompt }
            else { prompts.append(prompt) }
            status = .needsInput
        case .promptResolved(let id):
            prompts.removeAll { $0.id == id }
            pendingResponses.remove(id)
        case .status(let status): self.status = status
        case .failure(let message): error = message
        case .disconnected(let message):
            isConnected = false
            ownership.release(owner: ownerID)
            if let message { error = message }
        }
        onChange?()
    }

    enum Failure: LocalizedError {
        case writerConflict, notConnected, identityMismatch
        var errorDescription: String? {
            switch self {
            case .writerConflict: return String(localized: "omg.chat.writerConflict", defaultValue: "This conversation is already open for writing. Use its existing chat or terminal.")
            case .notConnected: return String(localized: "omg.chat.notConnected", defaultValue: "The provider did not open the requested conversation.")
            case .identityMismatch: return String(localized: "omg.chat.identityMismatch", defaultValue: "The provider returned a different conversation. Reopen it before continuing.")
            }
        }
    }
}
