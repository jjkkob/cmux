import AppKit
import WebKit
import SwiftUI

/// An unscaled native terminal window above a separately zoomable web canvas.
@MainActor
final class OMGCanvasHostView: NSView {
    let webView: WKWebView
    private let sessionWindow = NSView()
    private let terminalContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let backButton = NSButton()
    private var chatHost: NSHostingView<OMGCanvasChatView>?
    private var onBackToChat: (() -> Void)?
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
        backButton.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: String(localized: "omg.chat.back", defaultValue: "Back to chat"))
        backButton.bezelStyle = .texturedRounded
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.toolTip = String(localized: "omg.chat.back", defaultValue: "Back to chat")
        backButton.isHidden = true
        sessionWindow.addSubview(backButton)
        addSubview(sessionWindow)
        sessionWindow.isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let isChat = chatHost != nil
        let size = NSSize(width: max(180, min(isChat ? 860 : 1100, bounds.width - (isChat ? 40 : 64))), height: max(160, min(780, bounds.height - (isChat ? 40 : 88))))
        sessionWindow.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        terminalContainer.frame = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 53)
        let titleX: CGFloat = onBackToChat == nil ? 18 : 54
        titleLabel.frame = NSRect(x: titleX, y: size.height - 35, width: max(20, size.width - titleX - 62), height: 20)
        closeButton.frame = NSRect(x: size.width - 46, y: size.height - 42, width: 30, height: 30)
        backButton.frame = NSRect(x: 12, y: size.height - 42, width: 30, height: 30)
        chatHost?.frame = sessionWindow.bounds
    }

    func present(_ panel: TerminalPanel, title: String, onBackToChat: (() -> Void)? = nil, onFocus: @escaping (UUID) -> Void) {
        titleLabel.stringValue = title
        if mountedPanel === panel {
            panel.focus()
            return
        }
        dismiss(focusCanvas: false)
        self.onBackToChat = onBackToChat
        backButton.isHidden = onBackToChat == nil
        titleLabel.isHidden = false
        closeButton.isHidden = false
        terminalContainer.isHidden = false
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

    func presentChat(model: OMGCanvasChatModel, canOpenTerminal: Bool, onContinue: @escaping () -> Void, onOpenTerminal: @escaping () -> Void) {
        dismiss(focusCanvas: false)
        titleLabel.isHidden = true
        closeButton.isHidden = true
        terminalContainer.isHidden = true
        let content = OMGCanvasChatView(model: model, canOpenTerminal: canOpenTerminal, onOpenTerminal: onOpenTerminal, onContinue: onContinue, onClose: { [weak self] in self?.onDismiss?() })
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        chatHost = hostingView
        sessionWindow.addSubview(hostingView)
        sessionWindow.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        // NSHostingView may decline first responder. Clear a prior terminal first.
        window?.makeFirstResponder(nil)
        window?.makeFirstResponder(hostingView)
    }

    func updateChatTerminalAvailability(_ available: Bool) {
        guard let chatHost, chatHost.rootView.canOpenTerminal != available else { return }
        chatHost.rootView.canOpenTerminal = available
    }

    func dismiss(focusCanvas: Bool) {
        mountedPanel?.unfocus()
        mount?.unmount()
        mountedPanel?.hostedView.setVisibleInUI(false)
        mountedPanel?.surface.applyVisibilityOcclusion(false)
        mount = nil
        mountedPanel = nil
        chatHost?.removeFromSuperview()
        chatHost = nil
        onBackToChat = nil
        backButton.isHidden = true
        sessionWindow.isHidden = true
        if focusCanvas { window?.makeFirstResponder(webView) }
    }

    @objc private func dismissClicked() { onDismiss?() }
    @objc private func backClicked() { onBackToChat?() }
}
