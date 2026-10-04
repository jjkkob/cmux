import AppKit
import CmuxAgentSessionStore
import WebKit

/// Trusted bundled-page bridge. Workspace owns processes; this coordinator owns presentation only.
@MainActor
final class OMGCanvasCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private weak var workspace: Workspace?
    private let shellURL: URL?
    private let runtimeResolver: OMGCanvasRuntimeResolver
    private weak var host: OMGCanvasHostView?
    private var active = false
    private var ready = false
    private var disposed = false
    private var lastPayload: Data?
    private var availability: [UUID: Bool] = [:]
    private let historyResolver = OMGCanvasHistorySessionResolver(loader: SessionIndexSnapshotLoader(), repository: AmpHookSessionRepository())
    private var historyEntries: [UUID: SessionEntry] = [:]
    private var historyIdentity: [String] = []
    private var historyLoad: Task<Void, Never>?
    private var runtimeLaunches: [String: OMGCanvasRuntimeResolver.Launch] = [:]
    private var creatingRequests: Set<UUID> = []
    private var chatTerminalTarget: (nodeID: UUID, surfaceID: UUID)?

    init(workspace: Workspace, resourceURL: URL?) {
        self.workspace = workspace
        self.shellURL = resourceURL?.appendingPathComponent("omg-canvas/index.html")
        self.runtimeResolver = OMGCanvasRuntimeResolver(resolver: AgentExecutableResolver(configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()))
        super.init()
        for runtime in ["shell", "python", "codex", "claude"] {
            runtimeLaunches[runtime] = try? runtimeResolver.resolve(runtime)
        }
    }

    func makeHost() -> OMGCanvasHostView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "omgCanvas")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        let host = OMGCanvasHostView(webView: webView)
        self.host = host
        host.onDismiss = { [weak self] in self?.dismiss() }
        workspace?.omgCanvasState.dismissPresentation = { [weak self] in self?.dismiss() }
        workspace?.omgCanvasState.refreshPresentation = { [weak self] in self?.reconcile(); self?.push() }
        if let shellURL {
            webView.loadFileURL(shellURL, allowingReadAccessTo: shellURL.deletingLastPathComponent())
        }
        return host
    }

    func update(isVisible: Bool) {
        guard !disposed else { return }
        active = isVisible
        if !isVisible { dismiss(focusCanvas: false) }
        reconcile()
        if isVisible, let state = workspace?.omgCanvasState, let id = state.requestedOpenId {
            state.requestedOpenId = nil
            try? open(id)
        }
        push()
    }

    private func reconcile() {
        guard let workspace else { return }
        let state = workspace.omgCanvasState
        for id in workspace.orderedPanelIds {
            guard let panel = workspace.panels[id] as? TerminalPanel else { continue }
            if !state.graph.nodes.contains(where: { $0.surfaceId == id }) {
                state.add(surfaceId: id, title: panel.displayTitle, runtime: "unknown")
            }
        }
        let observed = Dictionary(uniqueKeysWithValues: state.graph.nodes.map { node in
            (node.id, node.surfaceId.flatMap { workspace.panels[$0] as? TerminalPanel } != nil)
        })
        if observed != availability { availability = observed; state.changed() }
        if let surface = state.presentedSurfaceId, workspace.panels[surface] as? TerminalPanel == nil {
            dismiss()
        }
        host?.updateChatTerminalAvailability(chatTerminalIsAvailable)
        refreshHistoryAvailability()
    }

    func dispose() {
        guard !disposed else { return }
        dismiss(focusCanvas: false)
        disposed = true
        historyLoad?.cancel()
        workspace?.omgCanvasState.dismissPresentation = nil
        workspace?.omgCanvasState.refreshPresentation = nil
        host?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "omgCanvas", contentWorld: .page)
        host?.webView.navigationDelegate = nil
        host?.webView.stopLoading()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard OMGCanvasBridgeRequest.isTrustedFrame(message.frameInfo.request.url, expected: shellURL, isMainFrame: message.frameInfo.isMainFrame), !disposed else {
            replyHandler(errorReply(.invalid), nil)
            return
        }
        do {
            let request = try OMGCanvasBridgeRequest(body: message.body)
            Task { @MainActor in
                do {
                    let value = try await handle(request)
                    replyHandler(["ok": true, "value": value], nil)
                    push()
                } catch {
                    if let failure = error as? OMGCanvasBridgeRequest.Failure { replyHandler(errorReply(failure), nil) }
                    else { replyHandler(["ok": false, "error": ["code": "chat_failed", "message": error.localizedDescription]], nil) }
                }
            }
        } catch { replyHandler(errorReply(.invalid), nil) }
    }

    /// Synchronous main-actor mutations prevent create requests from interleaving.
    private func handle(_ request: OMGCanvasBridgeRequest) async throws -> [String: Any] {
        guard active, let workspace, workspace.omgCanvasState.enabled else { throw OMGCanvasBridgeRequest.Failure.inactive }
        let state = workspace.omgCanvasState
        switch request.method {
        case .snapshot:
            reconcile()
        case .resume:
            guard let id = request.params.id else { throw OMGCanvasBridgeRequest.Failure.invalid }
            try await resumeHistory(id)
        case .open:
            guard let id = request.params.id else { throw OMGCanvasBridgeRequest.Failure.invalid }
            if let node = state.graph.nodes.first(where: { $0.id == id }), OMGCanvasChatProvider(rawValue: node.runtime) != nil {
                try await openChat(id)
            } else { try open(id) }
        case .dismiss:
            dismiss()
        case .create:
            guard !workspace.isRemoteWorkspace else { throw OMGCanvasBridgeRequest.Failure.unavailable }
            guard let rawTitle = request.params.title, let runtime = request.params.runtime else { throw OMGCanvasBridgeRequest.Failure.invalid }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 120, ["shell", "python", "codex", "claude"].contains(runtime) else { throw OMGCanvasBridgeRequest.Failure.invalid }
            if let prior = state.graph.nodes.first(where: { $0.requestId == request.id }) {
                guard prior.title == title, prior.runtime == runtime else { throw OMGCanvasBridgeRequest.Failure.invalid }
                if prior.conversation != nil { try await openChat(prior.id) }
                return ["snapshot": snapshot(), "nodeId": prior.id.uuidString]
            }
            if let provider = OMGCanvasChatProvider(rawValue: runtime) {
                return try await createChat(provider: provider, title: title, requestID: request.id)
            }
            guard let launch = runtimeLaunches[runtime] else { throw OMGCanvasBridgeRequest.Failure.missingRuntime }
            guard let pane = workspace.bonsplitController.allPaneIds.first,
                  let panel = workspace.newTerminalSurface(inPane: pane, focus: false, workingDirectory: workspace.currentDirectory, initialInput: launch.command.map { $0 + "\n" }, startupEnvironment: launch.environment, suppressWorkspaceRemoteStartupCommand: true, allowTextBoxFocusDefault: false) else {
                throw OMGCanvasBridgeRequest.Failure.createFailed
            }
            let nodeId = state.add(surfaceId: panel.id, title: title, runtime: runtime, requestId: request.id)
            try open(nodeId)
            return ["snapshot": snapshot(), "nodeId": nodeId.uuidString]
        case .positions:
            guard let positions = request.params.positions else { throw OMGCanvasBridgeRequest.Failure.invalid }
            try state.graph.setPositions(positions, viewport: request.params.viewport)
            state.changed()
        case .link:
            guard let source = request.params.source, let target = request.params.target else { throw OMGCanvasBridgeRequest.Failure.invalid }
            try state.graph.link(source: source, target: target)
            state.changed()
        }
        return snapshot()
    }

    /// The index scan does not launch a provider or read commands from the import file.
    private func refreshHistoryAvailability() {
        guard let workspace else { return }
        let nodes = workspace.omgCanvasState.graph.nodes.filter { $0.history != nil }
        let identity = nodes.map { $0.id.uuidString + ":" + ($0.history?.externalKey ?? "") }.sorted()
        guard identity != historyIdentity else { return }
        historyIdentity = identity
        historyEntries = [:]
        historyLoad?.cancel()
        guard !nodes.isEmpty else { return }
        historyLoad = Task { @MainActor [weak self, historyResolver] in
            let matches = await historyResolver.resolve(nodes)
            guard let self, !Task.isCancelled, !self.disposed, self.historyIdentity == identity else { return }
            self.historyEntries = matches
            self.workspace?.omgCanvasState.changed()
            self.push()
        }
    }

    /// Only this explicit action can turn an imported history reference into a live terminal.
    private func resumeHistory(_ id: UUID) async throws {
        guard active, !disposed, let workspace, workspace.omgCanvasState.enabled,
              !workspace.isRemoteWorkspace, let manager = workspace.owningTabManager,
              let imported = workspace.omgCanvasState.graph.nodes.first(where: { $0.id == id }), imported.history != nil
        else { throw OMGCanvasBridgeRequest.Failure.historyUnavailable }
        if let surface = imported.surfaceId, workspace.panels[surface] is TerminalPanel {
            try open(id)
            return
        }
        // Refresh at the execution boundary so a removed/changed indexed record cannot use a stale launch.
        let matches = await historyResolver.resolve([imported])
        guard active, !disposed, workspace.omgCanvasState.enabled,
              let entry = matches[id], let launch = entry.resumeLaunch, launch.strategy == .restoreVerb,
              let index = workspace.omgCanvasState.graph.nodes.firstIndex(where: { $0.id == id && $0.history?.externalKey == imported.history?.externalKey })
        else { throw OMGCanvasBridgeRequest.Failure.historyUnavailable }
        // Another request may have resumed this same node during the async lookup.
        if let surface = workspace.omgCanvasState.graph.nodes[index].surfaceId, workspace.panels[surface] is TerminalPanel {
            try open(id)
            return
        }
        if let target = SessionEntryResumeCoordinator.activeTarget(for: entry, tabManager: manager) {
            // Reuse the exact live provider conversation; never start another copy as a fallback.
            if target.workspaceID == workspace.id {
                if let bound = workspace.omgCanvasState.graph.nodes.first(where: { $0.id != id && $0.surfaceId == target.surfaceID }) {
                    try open(bound.id)
                    return
                }
                workspace.omgCanvasState.graph.nodes[index].surfaceId = target.surfaceID
                try open(id)
            } else {
                if let targetWorkspace = manager.tabs.first(where: { $0.id == target.workspaceID }),
                   targetWorkspace.omgCanvasState.enabled,
                   let bound = targetWorkspace.omgCanvasState.graph.nodes.first(where: { $0.surfaceId == target.surfaceID }) {
                    targetWorkspace.omgCanvasState.requestedOpenId = bound.id
                }
                manager.focusTab(target.workspaceID, surfaceId: target.surfaceID)
            }
            return
        }
        guard let pane = workspace.bonsplitController.allPaneIds.first,
              let panel = workspace.newTerminalSurface(inPane: pane, focus: false,
                workingDirectory: launch.workingDirectory, initialInput: launch.initialInput,
                startupRestoreAgent: launch.startupRestoreAgent,
                suppressWorkspaceRemoteStartupCommand: true, allowTextBoxFocusDefault: false)
        else { throw OMGCanvasBridgeRequest.Failure.createFailed }
        // Bind before the next reconciliation so the historical node keeps its stable graph identity.
        workspace.omgCanvasState.graph.nodes[index].surfaceId = panel.id
        workspace.omgCanvasState.changed()
        try open(id)
    }

    private var chatTerminalIsAvailable: Bool {
        guard let workspace, let target = chatTerminalTarget else { return false }
        return workspace.omgCanvasState.graph.nodes.contains(where: { $0.id == target.nodeID && $0.surfaceId == target.surfaceID })
            && workspace.panels[target.surfaceID] is TerminalPanel
    }

    private func runtime(provider: OMGCanvasChatProvider, entry: SessionEntry? = nil) throws -> any OMGCanvasChatRuntime {
        let resolver = AgentExecutableResolver(configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths())
        let launch = try resolver.resolve(provider == .codex ? .codex : .claude)
        var environment = launch.environment
        if let entry, case .claude(_, _, let configDirectory) = entry.specifics, let configDirectory, !configDirectory.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        if provider == .codex { return OMGCanvasCodexRuntime(executableURL: launch.executableURL, environment: environment) }
        return OMGCanvasClaudeRuntime(executableURL: launch.executableURL, environment: environment)
    }

    private func referenceNode(_ node: OMGCanvasGraph.Node) -> OMGCanvasGraph.Node {
        var reference = node
        if reference.history == nil, let conversation = node.conversation {
            reference.history = .init(source: conversation.provider, sessionId: conversation.sessionID, cwd: conversation.cwd)
        }
        return reference
    }

    private func wire(_ model: OMGCanvasChatModel, nodeID: UUID) {
        model.onChange = { [weak self, weak workspace] in workspace?.omgCanvasState.changed(); self?.push() }
        model.onIdentity = { [weak workspace] identity in
            guard let state = workspace?.omgCanvasState,
                  let index = state.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            state.graph.nodes[index].conversation = .init(provider: identity.provider.rawValue, sessionID: identity.sessionID, cwd: identity.cwd)
            state.changed()
        }
    }

    private func createChat(provider: OMGCanvasChatProvider, title: String, requestID: UUID) async throws -> [String: Any] {
        guard let workspace, let ownership = AppDelegate.shared?.omgCanvasChatOwnership,
              creatingRequests.insert(requestID).inserted else { throw OMGCanvasBridgeRequest.Failure.createFailed }
        defer { creatingRequests.remove(requestID) }
        let model = OMGCanvasChatModel(provider: provider, title: title, runtime: try runtime(provider: provider), ownership: ownership)
        // Native identity is assigned by the provider; only then does the standalone node exist.
        model.onIdentity = { [weak workspace, weak model] identity in
            guard let state = workspace?.omgCanvasState, let model else { return }
            let id = state.addChat(conversation: .init(provider: identity.provider.rawValue, sessionID: identity.sessionID, cwd: identity.cwd), title: title, requestID: requestID)
            state.chatModels[id] = model
        }
        try await model.connect(sessionID: nil, cwd: workspace.currentDirectory)
        guard let node = workspace.omgCanvasState.graph.nodes.first(where: { $0.requestId == requestID }) else { throw OMGCanvasBridgeRequest.Failure.createFailed }
        wire(model, nodeID: node.id)
        try await openChat(node.id)
        return ["snapshot": snapshot(), "nodeId": node.id.uuidString]
    }

    private func openChat(_ id: UUID) async throws {
        guard active, !disposed, let workspace, let host, workspace.omgCanvasState.enabled,
              let node = workspace.omgCanvasState.graph.nodes.first(where: { $0.id == id }),
              let provider = OMGCanvasChatProvider(rawValue: node.runtime),
              let ownership = AppDelegate.shared?.omgCanvasChatOwnership else { throw OMGCanvasBridgeRequest.Failure.invalid }
        let state = workspace.omgCanvasState
        let model: OMGCanvasChatModel
        var needsHistory = false
        var entry: SessionEntry?
        if let cached = state.chatModels[id] { model = cached }
        else {
            let matches = await historyResolver.resolve([referenceNode(node)])
            guard active, !disposed else { throw OMGCanvasBridgeRequest.Failure.inactive }
            entry = matches[id]
            var resolvedRuntime: (any OMGCanvasChatRuntime)?
            var runtimeError: String?
            do { resolvedRuntime = try runtime(provider: provider, entry: entry) }
            catch { runtimeError = error.localizedDescription }
            model = OMGCanvasChatModel(provider: provider, title: node.title, runtime: resolvedRuntime, ownership: ownership)
            model.error = runtimeError
            let canIdentify = entry != nil || node.conversation != nil
            let liveTarget = entry.flatMap { entry in workspace.owningTabManager.flatMap { SessionEntryResumeCoordinator.activeTarget(for: entry, tabManager: $0) } }
            let hasTerminal = node.surfaceId.flatMap { workspace.panels[$0] as? TerminalPanel } != nil
            model.canContinue = canIdentify && liveTarget == nil && !hasTerminal && resolvedRuntime != nil
            if liveTarget != nil || hasTerminal {
                model.readOnlyReason = String(localized: "omg.chat.writerConflict", defaultValue: "This conversation is already open for writing. Use its existing chat or terminal.")
            } else if !canIdentify {
                model.readOnlyReason = String(localized: "omg.chat.historyUnavailable", defaultValue: "The original conversation could not be found locally. Its canvas history remains available.")
            }
            state.chatModels[id] = model
            wire(model, nodeID: id)
            needsHistory = canIdentify
        }
        dismiss(focusCanvas: false)
        try state.presentChat(nodeID: id)
        if let surfaceID = node.surfaceId, workspace.panels[surfaceID] is TerminalPanel { chatTerminalTarget = (id, surfaceID) }
        host.presentChat(model: model, canOpenTerminal: chatTerminalIsAvailable, onContinue: { [weak self, weak model] in
            Task { @MainActor in
                do { try await self?.continueChat(id) }
                catch { model?.error = error.localizedDescription }
            }
        }, onOpenTerminal: { [weak self] in
            guard let self, self.chatTerminalIsAvailable, let target = self.chatTerminalTarget else { return }
            try? self.open(target.nodeID, expectedSurfaceID: target.surfaceID, returnToChat: true)
            self.push()
        })
        push()
        if needsHistory {
            let sessionID = node.conversation?.sessionID ?? entry?.sessionId
            let cwd = node.conversation?.cwd ?? entry?.resumeWorkingDirectory ?? workspace.currentDirectory
            if let sessionID { await model.loadHistory(sessionID: sessionID, cwd: cwd) }
        }
    }

    private func continueChat(_ id: UUID) async throws {
        guard active, !disposed, let workspace,
              let node = workspace.omgCanvasState.graph.nodes.first(where: { $0.id == id }),
              let model = workspace.omgCanvasState.chatModels[id], model.canContinue else { throw OMGCanvasBridgeRequest.Failure.historyUnavailable }
        let entry = await historyResolver.resolve([referenceNode(node)])[id]
        guard active, !disposed else { throw OMGCanvasBridgeRequest.Failure.inactive }
        if let entry, let manager = workspace.owningTabManager, SessionEntryResumeCoordinator.activeTarget(for: entry, tabManager: manager) != nil {
            model.canContinue = false
            throw OMGCanvasChatModel.Failure.writerConflict
        }
        guard let sessionID = node.conversation?.sessionID ?? entry?.sessionId else { throw OMGCanvasBridgeRequest.Failure.historyUnavailable }
        try await model.connect(sessionID: sessionID, cwd: node.conversation?.cwd ?? entry?.resumeWorkingDirectory ?? workspace.currentDirectory)
    }

    private func open(_ id: UUID, expectedSurfaceID: UUID? = nil, returnToChat: Bool = false) throws {
        guard active, let workspace, let host,
              let node = workspace.omgCanvasState.graph.nodes.first(where: { $0.id == id }),
              let surfaceId = node.surfaceId, let panel = workspace.panels[surfaceId] as? TerminalPanel else { throw OMGCanvasBridgeRequest.Failure.unavailable }
        guard expectedSurfaceID == nil || expectedSurfaceID == surfaceId else { throw OMGCanvasBridgeRequest.Failure.unavailable }
        dismiss(focusCanvas: false)
        let state = workspace.omgCanvasState
        state.selectedId = id
        state.presentedSurfaceId = surfaceId
        state.changed()
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(workspaceId: workspace.id, panelId: surfaceId, in: host.window)
        workspace.focusPanel(surfaceId)
        let back: (() -> Void)? = returnToChat ? { [weak self] in
            Task { @MainActor in try? await self?.openChat(id) }
            self?.push()
        } : nil
        host.present(panel, title: node.title, onBackToChat: back) { [weak workspace] panelId in workspace?.focusPanel(panelId) }
    }

    private func dismiss(focusCanvas: Bool = true) {
        guard let workspace else { return }
        host?.dismiss(focusCanvas: focusCanvas && active)
        chatTerminalTarget = nil
        workspace.omgCanvasState.dismissChat()
        if workspace.omgCanvasState.presentedSurfaceId != nil {
            workspace.omgCanvasState.presentedSurfaceId = nil
            workspace.omgCanvasState.changed()
        }
        push()
    }

    private func snapshot() -> [String: Any] {
        guard let workspace else { return [:] }
        let state = workspace.omgCanvasState
        let nodes = state.graph.nodes.map { node in
            OMGCanvasSnapshot.Node(id: node.id, surfaceId: node.surfaceId, title: node.title, runtime: node.runtime, createdAt: node.createdAt, x: node.x, y: node.y, available: node.surfaceId.flatMap { workspace.panels[$0] as? TerminalPanel } != nil, history: node.history, canResume: node.history == nil ? nil : historyEntries[node.id] != nil, conversation: node.conversation, chatStatus: state.chatModels[node.id]?.statusLabel)
        }
        let payload = OMGCanvasSnapshot(
            revision: state.revision, locale: Locale.current.identifier,
            workspace: .init(id: workspace.id, title: workspace.title), nodes: nodes, edges: state.graph.edges,
            selectedId: state.selectedId, terminalOpen: state.presentedSurfaceId != nil, viewport: state.graph.viewport,
            runtimes: ["codex", "claude", "shell", "python"].map { .init(id: $0, label: $0, available: runtimeLaunches[$0] != nil && !workspace.isRemoteWorkspace) },
            chatOpen: state.isChatPresented
        )
        return (try? payload.dictionary()) ?? [:]
    }

    private func push() {
        guard ready, !disposed, let webView = host?.webView else { return }
        let payload = snapshot()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), data != lastPayload else { return }
        lastPayload = data
        webView.callAsyncJavaScript("window.dispatchEvent(new CustomEvent('omg:state', {detail: state}));", arguments: ["state": payload], in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        lastPayload = nil
        push()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let trusted = OMGCanvasBridgeRequest.isTrustedFrame(navigationAction.request.url, expected: shellURL, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
        decisionHandler(trusted ? .allow : .cancel)
    }

    private func errorReply(_ failure: OMGCanvasBridgeRequest.Failure) -> [String: Any] {
        let message: String
        switch failure {
        case .invalid: message = String(localized: "omg.canvas.invalid", defaultValue: "This canvas request could not be applied.")
        case .historyUnavailable: message = String(localized: "omg.canvas.historyUnavailable", defaultValue: "The original local CLI session could not be verified. You can still review its history.")
        case .unavailable: message = String(localized: "omg.canvas.unavailable", defaultValue: "This terminal is no longer available.")
        case .missingRuntime: message = String(localized: "omg.canvas.missingRuntime", defaultValue: "This runtime could not be found on this Mac.")
        case .createFailed: message = String(localized: "omg.canvas.createFailed", defaultValue: "The terminal could not be created.")
        case .inactive: message = String(localized: "omg.canvas.inactive", defaultValue: "Open this workspace to use its canvas.")
        }
        return ["ok": false, "error": ["code": String(describing: failure), "message": message]]
    }
}
