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
            if request.method == .resume {
                Task { @MainActor in
                    do {
                        guard let id = request.params.id else { throw OMGCanvasBridgeRequest.Failure.invalid }
                        try await resumeHistory(id)
                        replyHandler(["ok": true, "value": snapshot()], nil)
                        push()
                    } catch {
                        replyHandler(errorReply(error as? OMGCanvasBridgeRequest.Failure ?? .historyUnavailable), nil)
                    }
                }
            } else {
                let value = try handle(request)
                replyHandler(["ok": true, "value": value], nil)
                push()
            }
        } catch {
            replyHandler(errorReply(error as? OMGCanvasBridgeRequest.Failure ?? .invalid), nil)
        }
    }

    /// Synchronous main-actor mutations prevent create requests from interleaving.
    private func handle(_ request: OMGCanvasBridgeRequest) throws -> [String: Any] {
        guard active, let workspace, workspace.omgCanvasState.enabled else { throw OMGCanvasBridgeRequest.Failure.inactive }
        let state = workspace.omgCanvasState
        switch request.method {
        case .snapshot:
            reconcile()
        case .resume:
            throw OMGCanvasBridgeRequest.Failure.invalid
        case .open:
            guard let id = request.params.id else { throw OMGCanvasBridgeRequest.Failure.invalid }
            try open(id)
        case .dismiss:
            dismiss()
        case .create:
            guard !workspace.isRemoteWorkspace else { throw OMGCanvasBridgeRequest.Failure.unavailable }
            guard let rawTitle = request.params.title, let runtime = request.params.runtime else { throw OMGCanvasBridgeRequest.Failure.invalid }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 120, ["shell", "python", "codex", "claude"].contains(runtime) else { throw OMGCanvasBridgeRequest.Failure.invalid }
            if let prior = state.graph.nodes.first(where: { $0.requestId == request.id }) {
                guard prior.title == title, prior.runtime == runtime else { throw OMGCanvasBridgeRequest.Failure.invalid }
                return ["snapshot": snapshot(), "nodeId": prior.id.uuidString]
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

    private func open(_ id: UUID) throws {
        guard active, let workspace, let host,
              let node = workspace.omgCanvasState.graph.nodes.first(where: { $0.id == id }),
              let surfaceId = node.surfaceId, let panel = workspace.panels[surfaceId] as? TerminalPanel else { throw OMGCanvasBridgeRequest.Failure.unavailable }
        dismiss(focusCanvas: false)
        let state = workspace.omgCanvasState
        state.selectedId = id
        state.presentedSurfaceId = surfaceId
        state.changed()
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(workspaceId: workspace.id, panelId: surfaceId, in: host.window)
        workspace.focusPanel(surfaceId)
        host.present(panel, title: node.title) { [weak workspace] panelId in workspace?.focusPanel(panelId) }
    }

    private func dismiss(focusCanvas: Bool = true) {
        guard let workspace else { return }
        host?.dismiss(focusCanvas: focusCanvas && active)
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
            OMGCanvasSnapshot.Node(id: node.id, surfaceId: node.surfaceId, title: node.title, runtime: node.runtime, createdAt: node.createdAt, x: node.x, y: node.y, available: node.surfaceId.flatMap { workspace.panels[$0] as? TerminalPanel } != nil, history: node.history, canResume: node.history == nil ? nil : historyEntries[node.id] != nil)
        }
        let payload = OMGCanvasSnapshot(
            revision: state.revision, locale: Locale.current.identifier,
            workspace: .init(id: workspace.id, title: workspace.title), nodes: nodes, edges: state.graph.edges,
            selectedId: state.selectedId, terminalOpen: state.presentedSurfaceId != nil, viewport: state.graph.viewport,
            runtimes: ["shell", "python", "codex", "claude"].map { .init(id: $0, label: $0, available: runtimeLaunches[$0] != nil && !workspace.isRemoteWorkspace) }
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
