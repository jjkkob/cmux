import CmuxAgentChat
import Foundation
import Observation

/// Synthetic, workspace-owned presentation state. It has no runtime or transcript dependencies.
@MainActor @Observable
final class OMGCanvasChatPreviewModel {
    enum Scenario: String, CaseIterable, Identifiable {
        case ready, working, needsInput, results
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ready: return String(localized: "omg.chatPreview.conversation", defaultValue: "Conversation")
            case .working: return String(localized: "omg.chatPreview.working", defaultValue: "Working")
            case .needsInput: return String(localized: "omg.chatPreview.needsInput", defaultValue: "Needs input")
            case .results: return String(localized: "omg.chatPreview.results", defaultValue: "Results")
            }
        }
    }

    enum Choice: String, CaseIterable, Identifiable {
        case compact, detailed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: return String(localized: "omg.chatPreview.compact", defaultValue: "Warm and concise")
            case .detailed: return String(localized: "omg.chatPreview.detailed", defaultValue: "More descriptive")
            }
        }
    }

    private(set) var scenario: Scenario = .ready
    var draft = ""
    var activityExpanded = false
    var scrollAnchor: String?
    private(set) var hasStopped = false
    private(set) var selectedChoice: Choice?
    private(set) var isReviewVisible = false
    private(set) var submittedMessages: [ChatMessage] = []
    private var nextSequence = 10

    var isWorking: Bool { scenario == .working && !hasStopped }
    var canSubmit: Bool { !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var status: String {
        if hasStopped { return String(localized: "omg.chatPreview.stopped", defaultValue: "Stopped") }
        switch scenario {
        case .ready: return String(localized: "omg.chatPreview.ready", defaultValue: "Ready")
        case .working: return String(localized: "omg.chatPreview.working", defaultValue: "Working")
        case .needsInput: return selectedChoice == nil
            ? String(localized: "omg.chatPreview.needsInput", defaultValue: "Needs input")
            : String(localized: "omg.chatPreview.ready", defaultValue: "Ready")
        case .results: return String(localized: "omg.chatPreview.complete", defaultValue: "Complete")
        }
    }

    var messages: [ChatMessage] {
        [
            message(id: "fixture-user", seq: 0, role: .user, text: String(localized: "omg.chatPreview.fixturePrompt", defaultValue: "Give this sample project a calmer empty state.")),
            message(id: "fixture-intro", seq: 1, role: .agent, text: String(localized: "omg.chatPreview.fixtureIntro", defaultValue: "I’ll keep the layout simple, make the next action clear, and leave room for the work to grow.")),
            message(id: "fixture-state", seq: 2, role: .agent, text: scenarioText)
        ] + submittedMessages
    }

    func selectScenario(_ value: Scenario) {
        scenario = value
        hasStopped = false
        selectedChoice = nil
        isReviewVisible = false
        scrollAnchor = nil
    }

    /// Appends only in-memory synthetic messages; no terminal or provider action is available here.
    func submitDraft() {
        guard canSubmit else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        submittedMessages.append(message(id: "preview-user-\(nextSequence)", seq: nextSequence, role: .user, text: text))
        nextSequence += 1
        submittedMessages.append(message(id: "preview-reply-\(nextSequence)", seq: nextSequence, role: .agent, text: String(localized: "omg.chatPreview.fixtureReply", defaultValue: "This message stays in the preview. Your real session has not received it.")))
        nextSequence += 1
        scrollAnchor = submittedMessages.last?.id
    }

    func stop() { if isWorking { hasStopped = true } }
    func choose(_ choice: Choice) {
        guard scenario == .needsInput, selectedChoice == nil else { return }
        selectedChoice = choice
    }
    func reviewChanges() { isReviewVisible = true }
    func backToConversation() { isReviewVisible = false }

    private var scenarioText: String {
        if hasStopped { return String(localized: "omg.chatPreview.fixtureStopped", defaultValue: "The simulation is stopped. Your real session keeps running.") }
        switch scenario {
        case .ready: return String(localized: "omg.chatPreview.fixtureReady", defaultValue: "The preview is ready. Try a message below, explore the activity, or review the sample changes.")
        case .working: return String(localized: "omg.chatPreview.fixtureWorking", defaultValue: "I’m refining the empty state and checking how it reads at smaller sizes.")
        case .needsInput: return String(localized: "omg.chatPreview.fixtureQuestion", defaultValue: "Which tone should the empty state use?")
        case .results: return String(localized: "omg.chatPreview.fixtureResults", defaultValue: "The sample update is ready to review. The primary action is clearer, and the layout has more breathing room.")
        }
    }

    private func message(id: String, seq: Int, role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, timestamp: Date(timeIntervalSince1970: 0), kind: .prose(ChatProse(text: text)))
    }
}
