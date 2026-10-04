import Foundation

extension Workspace {
    func setOMGCanvasEnabled(_ enabled: Bool) {
        guard omgCanvasState.enabled != enabled else { return }
        omgCanvasState.dismissPresentation?()
        hideAllTerminalPortalViews()
        hideAllBrowserPortalViews()
        omgCanvasState.enabled = enabled
        if !enabled {
            reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
            reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "omg.dismiss")
        }
    }
}
