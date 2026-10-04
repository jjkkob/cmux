import CmuxAgentChat
import SwiftUI

/// Rows receive a value snapshot, never the observable preview model.
struct OMGCanvasChatPreviewMessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.role == .user
                    ? String(localized: "omg.chatPreview.you", defaultValue: "You")
                    : String(localized: "omg.chatPreview.assistant", defaultValue: "Assistant"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if case .prose(let prose) = message.kind {
                    Text(verbatim: prose.text)
                        .font(.system(size: 15))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(message.role == .user ? 16 : 0)
            .background(message.role == .user ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: message.role == .user ? 520 : .infinity, alignment: .leading)
            if message.role != .user { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .contain)
    }
}
