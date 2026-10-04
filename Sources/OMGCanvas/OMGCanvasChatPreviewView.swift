import SwiftUI

/// A fixture-only chat surface. Callbacks are limited to dismissal and exact-terminal navigation.
struct OMGCanvasChatPreviewView: View {
    @Bindable var model: OMGCanvasChatPreviewModel
    let title: String
    let runtime: String?
    var canOpenTerminal: Bool
    let onOpenTerminal: () -> Void
    let onClose: () -> Void
    @FocusState private var composerFocused: Bool
    private let background = Color(red: 0.085, green: 0.09, blue: 0.095)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            previewControls
            if model.isReviewVisible {
                review
            } else {
                conversation
            }
            Divider().opacity(0.5)
            composer
        }
        .background(background)
        .foregroundStyle(Color(white: 0.91))
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("OMGChatPreview")
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    if let runtime { Text(verbatim: runtime).foregroundStyle(.secondary) }
                    Circle().fill(model.isWorking || (model.scenario == .needsInput && model.selectedChoice == nil) ? Color.orange : Color(red: 0.57, green: 0.72, blue: 0.59)).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(model.status).foregroundStyle(.secondary)
                }.font(.system(size: 11))
            }
            Spacer(minLength: 8)
            Text(String(localized: "omg.chatPreview.badge", defaultValue: "Preview"))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.74, green: 0.82, blue: 0.72))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.055), in: Capsule())
            Menu {
                if canOpenTerminal {
                    Button(String(localized: "omg.chatPreview.openTerminal", defaultValue: "Open terminal"), systemImage: "terminal", action: onOpenTerminal)
                }
                Button(String(localized: "omg.chatPreview.review", defaultValue: "Review sample diff"), systemImage: "doc.text.magnifyingglass") { model.reviewChanges() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(String(localized: "omg.chatPreview.menu", defaultValue: "Session menu"))
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "omg.chatPreview.close", defaultValue: "Close preview"))
                .help(String(localized: "omg.chatPreview.close", defaultValue: "Close preview"))
        }
        .padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "omg.chatPreview.statePicker", defaultValue: "Preview state"), selection: Binding(get: { model.scenario }, set: { model.selectScenario($0) })) {
                ForEach(OMGCanvasChatPreviewModel.Scenario.allCases) { scenario in
                    Text(scenario.title).tag(scenario)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(String(localized: "omg.chatPreview.notice", defaultValue: "Synthetic conversation. Messages and controls stay in this preview."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.messages) { message in
                    OMGCanvasChatPreviewMessageView(message: message).id(message.id)
                }
                activity.id("preview-activity")
                if model.scenario == .needsInput { question.id("preview-question") }
                if model.scenario == .results { changes.id("preview-changes") }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 680)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $model.scrollAnchor)
        .accessibilityIdentifier("OMGChatPreviewTranscript")
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.activityExpanded.toggle() } label: {
                HStack(spacing: 9) {
                    if model.isWorking { ProgressView().controlSize(.small).scaleEffect(0.75) }
                    else { Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary) }
                    Text(String(localized: "omg.chatPreview.activity", defaultValue: "Sample activity")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: model.activityExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if model.activityExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Label(String(localized: "omg.chatPreview.activityRead", defaultValue: "Read the empty-state view"), systemImage: "doc.text")
                    Label(String(localized: "omg.chatPreview.activityEdit", defaultValue: "Adjust spacing and copy"), systemImage: "pencil.line")
                    Label(String(localized: "omg.chatPreview.activityCheck", defaultValue: "Check the compact layout"), systemImage: "rectangle.compress.vertical")
                    Text(String(localized: "omg.chatPreview.activityOutput", defaultValue: "Preview only — no commands were run."))
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(.leading, 24)
            }
        }
        .padding(14).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let choice = model.selectedChoice {
                Label(String(localized: "omg.chatPreview.choiceRecorded", defaultValue: "Choice recorded in preview"), systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(choice.title).font(.system(size: 14)).textSelection(.enabled)
            } else {
                ForEach(OMGCanvasChatPreviewModel.Choice.allCases) { choice in
                    Button { model.choose(choice) } label: {
                        HStack { Text(choice.title); Spacer(); Image(systemName: "arrow.up.left") }
                            .font(.system(size: 13)).padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private var changes: some View {
        Button { model.reviewChanges() } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "omg.chatPreview.sampleChanges", defaultValue: "Sample changes")).font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "omg.chatPreview.checks", defaultValue: "Checks not run")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }.padding(15).contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(String(localized: "omg.chatPreview.review", defaultValue: "Review sample diff"))
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { model.backToConversation() } label: {
                    Label(String(localized: "omg.chatPreview.backConversation", defaultValue: "Back to conversation"), systemImage: "arrow.left")
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Text(String(localized: "omg.chatPreview.sampleChanges", defaultValue: "Sample changes")).font(.system(size: 21, weight: .semibold))
                    Text(String(localized: "omg.chatPreview.diffScope", defaultValue: "Synthetic diff · no files changed")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(verbatim: "EmptyState.swift").font(.system(size: 12, weight: .medium))
                        Spacer()
                    }.padding(13)
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            diffLine("  struct EmptyState {", tint: .clear)
                            diffLine("−     let spacing = 16", tint: Color.red.opacity(0.12))
                            diffLine("+     let spacing = 24", tint: Color.green.opacity(0.12))
                            diffLine("+     let isPrimaryActionVisible = true", tint: Color.green.opacity(0.12))
                            diffLine("  }", tint: .clear)
                        }.padding(.vertical, 10).frame(minWidth: 600, alignment: .leading)
                    }
                }.background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                Text(String(localized: "omg.chatPreview.checks", defaultValue: "Checks not run")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("OMGChatPreviewDiff")
    }

    private func diffLine(_ value: String, tint: Color) -> some View {
        Text(verbatim: value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).background(tint)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(String(localized: "omg.chatPreview.composerPlaceholder", defaultValue: "Try a message in this preview…"))
                            .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $model.draft)
                        .font(.system(size: 14)).scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 76).focused($composerFocused)
                        .accessibilityLabel(String(localized: "omg.chatPreview.composerPlaceholder", defaultValue: "Try a message in this preview…"))
                        .accessibilityHint(String(localized: "omg.chatPreview.composerHint", defaultValue: "Return adds a new line. Use the send button to add a preview message."))
                        .accessibilityIdentifier("OMGChatPreviewComposer")
                }
                Button {
                    if model.isWorking { model.stop() } else { model.submitDraft(); composerFocused = true }
                } label: {
                    Image(systemName: model.isWorking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(model.isWorking || model.canSubmit ? Color(white: 0.85) : Color.white.opacity(0.09), in: Circle())
                .foregroundStyle(model.isWorking || model.canSubmit ? Color.black : Color.gray)
                .disabled(!model.isWorking && !model.canSubmit)
                .accessibilityLabel(model.isWorking ? String(localized: "omg.chatPreview.stop", defaultValue: "Stop preview") : String(localized: "omg.chatPreview.send", defaultValue: "Send preview message"))
                .help(model.isWorking ? String(localized: "omg.chatPreview.stop", defaultValue: "Stop preview") : String(localized: "omg.chatPreview.send", defaultValue: "Send preview message"))
            }
            .padding(12).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.09)))
            Text(String(localized: "omg.chatPreview.localOnly", defaultValue: "Local preview · nothing is sent to a provider"))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 720).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16).frame(maxWidth: .infinity)
    }
}
