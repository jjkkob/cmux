import SwiftUI

/// Transcript rows receive immutable values so streaming only invalidates the changed content.
struct OMGCanvasChatMessageView: View {
    let message: OMGCanvasChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.role == .user ? String(localized: "omg.chatPreview.you", defaultValue: "You") : String(localized: "omg.chatPreview.assistant", defaultValue: "Assistant"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(verbatim: message.text).font(.system(size: 15)).lineSpacing(5)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if message.isStreaming { ProgressView().controlSize(.mini) }
            }
            .padding(message.role == .user ? 16 : 0)
            .background(message.role == .user ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: message.role == .user ? 520 : .infinity, alignment: .leading)
        }.accessibilityElement(children: .contain)
    }
}
