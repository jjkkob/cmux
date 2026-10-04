import SwiftUI
import AppKit

struct OMGCanvasView: NSViewRepresentable {
    let workspace: Workspace
    let isVisible: Bool

    func makeCoordinator() -> OMGCanvasCoordinator {
        OMGCanvasCoordinator(workspace: workspace, resourceURL: Bundle.main.resourceURL)
    }
    func makeNSView(context: Context) -> OMGCanvasHostView { context.coordinator.makeHost() }
    func updateNSView(_ view: OMGCanvasHostView, context: Context) {
        context.coordinator.update(isVisible: isVisible)
    }
    static func dismantleNSView(_ view: OMGCanvasHostView, coordinator: OMGCanvasCoordinator) {
        coordinator.dispose()
    }
}
