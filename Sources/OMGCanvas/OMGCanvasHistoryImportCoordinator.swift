import AppKit
import UniformTypeIdentifiers

/// Imports into a dedicated workspace; reimport finds that workspace by the manifest project identity.
@MainActor
struct OMGCanvasHistoryImportCoordinator {
    let tabManager: TabManager
    let repository: OMGCanvasHistoryRepository

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "omg.canvas.importHistory", defaultValue: "Import Session History…")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try apply(await repository.read(url)) }
                catch { showFailure() }
            }
        }
    }

    private func apply(_ manifest: OMGCanvasHistoryManifest) throws {
        if let workspace = tabManager.tabs.first(where: { $0.omgCanvasState.graph.historyProjectId == manifest.project.id }) {
            try workspace.omgCanvasState.graph.importHistory(manifest)
            workspace.omgCanvasState.changed()
            workspace.setOMGCanvasEnabled(true)
            workspace.omgCanvasState.refreshPresentation?()
            tabManager.focusTab(workspace.id)
            return
        }
        // Validate/merge before workspace creation so malformed input leaves no partially imported workspace.
        var graph = OMGCanvasGraph()
        try graph.importHistory(manifest)
        guard let workspace = tabManager.addWorkspaceIfActive(
            title: manifest.project.title,
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false,
            allowTextBoxFocusDefault: false
        ) else { throw OMGCanvasHistoryManifest.Failure.invalid }
        workspace.omgCanvasState.graph = graph
        workspace.omgCanvasState.changed()
        workspace.setOMGCanvasEnabled(true)
    }

    private func showFailure() {
        let alert = NSAlert()
        alert.messageText = String(localized: "omg.canvas.importFailed", defaultValue: "Session history could not be imported.")
        alert.informativeText = String(localized: "omg.canvas.importInvalid", defaultValue: "Choose a valid version 1 history file. The existing canvas has not been changed.")
        alert.runModal()
    }
}
