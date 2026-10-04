import SwiftUI

/// A real provider conversation hosted above the independently zoomable canvas.
struct OMGCanvasChatView: View {
    @Bindable var model: OMGCanvasChatModel
    var canOpenTerminal: Bool
    let onOpenTerminal: () -> Void
    let onContinue: () -> Void
    let onClose: () -> Void
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let error = model.error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(.orange)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(model.messages) { message in
                        OMGCanvasChatMessageView(message: message).id(message.id)
                    }
                    ForEach(model.activities) { activity in
                        DisclosureGroup {
                            Text(verbatim: activity.detail).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                if activity.isRunning { ProgressView().controlSize(.small) }
                                Text(verbatim: activity.title).font(.system(size: 12, weight: .medium))
                            }
                        }.padding(12).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(model.prompts) { prompt in
                        OMGCanvasChatPromptView(prompt: prompt) { response in
                            Task { await model.respond(to: prompt.id, response: response) }
                        }
                    }
                }
                .scrollTargetLayout().frame(maxWidth: 680)
                .padding(24).frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $model.scrollAnchor)
            .accessibilityIdentifier("OMGChatTranscript")
            Divider().opacity(0.5)
            if !model.isConnected {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: model.readOnlyReason ?? String(localized: "omg.chat.continueHint", defaultValue: "Close any other app writing this conversation before continuing here."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.canContinue {
                        Button(String(localized: "omg.chat.continue", defaultValue: "Continue here"), action: onContinue)
                            .disabled(model.isLoading)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .background(Color(red: 0.085, green: 0.09, blue: 0.095))
        .foregroundStyle(Color(white: 0.91)).preferredColorScheme(.dark)
        .accessibilityIdentifier("OMGChat")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(verbatim: model.provider.rawValue.capitalized)
                    Text(verbatim: "·")
                    Text(verbatim: model.statusLabel)
                    if let identity = model.identity {
                        Text(verbatim: String(identity.sessionID.prefix(8))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if canOpenTerminal {
                Menu {
                    Button(String(localized: "omg.chatPreview.openTerminal", defaultValue: "Open terminal"), systemImage: "terminal", action: onOpenTerminal)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(String(localized: "omg.chatPreview.menu", defaultValue: "Session menu"))
            }
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "omg.canvas.dismiss", defaultValue: "Close session window"))
        }.padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(String(localized: "omg.chat.message", defaultValue: "Message…"))
                        .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: $model.draft).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 86).focused($composerFocused)
                    .disabled(!model.isConnected)
                    .accessibilityLabel(String(localized: "omg.chat.message", defaultValue: "Message…"))
                    .accessibilityIdentifier("OMGChatComposer")
            }
            Button {
                Task { if model.isWorking { await model.stop() } else { await model.submitDraft(); composerFocused = true } }
            } label: {
                Image(systemName: model.isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain).background(Color.white.opacity(0.12), in: Circle())
            .disabled(!model.isWorking && !model.canSubmit)
            .accessibilityLabel(model.isWorking ? String(localized: "omg.chat.stop", defaultValue: "Stop") : String(localized: "omg.chat.send", defaultValue: "Send"))
            .accessibilityIdentifier("OMGChatSend")
        }
        .padding(12).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}
