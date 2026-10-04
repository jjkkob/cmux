import AppKit
import WebKit

/// An unscaled native terminal window above a separately zoomable web canvas.
@MainActor
final class OMGCanvasHostView: NSView {
    let webView: WKWebView
    private let sessionWindow = NSView()
    private let terminalContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var mount: CanvasPaneContentMount?
    private weak var mountedPanel: TerminalPanel?
    var onDismiss: (() -> Void)?
    override var isFlipped: Bool { true }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        sessionWindow.wantsLayer = true
        sessionWindow.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sessionWindow.layer?.cornerRadius = 14
        sessionWindow.layer?.borderWidth = 1
        sessionWindow.layer?.borderColor = NSColor.separatorColor.cgColor
        sessionWindow.layer?.masksToBounds = true
        sessionWindow.addSubview(terminalContainer)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        sessionWindow.addSubview(titleLabel)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "omg.canvas.dismiss", defaultValue: "Close session window"))
        closeButton.bezelStyle = .texturedRounded
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.toolTip = String(localized: "omg.canvas.dismissHint", defaultValue: "Return to canvas. The session keeps running.")
        sessionWindow.addSubview(closeButton)
        addSubview(sessionWindow)
        sessionWindow.isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let size = NSSize(width: max(180, min(1100, bounds.width - 64)), height: max(160, min(780, bounds.height - 88)))
        sessionWindow.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        terminalContainer.frame = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 53)
        titleLabel.frame = NSRect(x: 18, y: size.height - 35, width: max(20, size.width - 80), height: 20)
        closeButton.frame = NSRect(x: size.width - 46, y: size.height - 42, width: 30, height: 30)
    }

    func present(_ panel: TerminalPanel, title: String, onFocus: @escaping (UUID) -> Void) {
        titleLabel.stringValue = title
        if mountedPanel === panel {
            panel.focus()
            return
        }
        dismiss(focusCanvas: false)
        sessionWindow.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        mount = CanvasPaneContentMount(
            content: .terminal(panel, .disabled),
            panelId: panel.id,
            container: terminalContainer,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil),
            onFocusPanel: onFocus
        )
        mountedPanel = panel
        panel.focus()
    }

    func dismiss(focusCanvas: Bool) {
        mountedPanel?.unfocus()
        mount?.unmount()
        mountedPanel?.hostedView.setVisibleInUI(false)
        mountedPanel?.surface.applyVisibilityOcclusion(false)
        mount = nil
        mountedPanel = nil
        sessionWindow.isHidden = true
        if focusCanvas { window?.makeFirstResponder(webView) }
    }

    @objc private func dismissClicked() { onDismiss?() }
}
