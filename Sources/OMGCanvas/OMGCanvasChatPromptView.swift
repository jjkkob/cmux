import SwiftUI

/// A request remains visible until its provider confirms resolution by the same request ID.
struct OMGCanvasChatPromptView: View {
    let prompt: OMGCanvasChatPrompt
    let onRespond: (OMGCanvasChatResponse) -> Void
    @State private var answers: [String: [String]] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: prompt.title).font(.system(size: 14, weight: .semibold))
            if !prompt.detail.isEmpty { Text(verbatim: prompt.detail).font(.system(size: 12)).textSelection(.enabled) }
            if prompt.kind == .approval {
                HStack {
                    Button(String(localized: "omg.chat.allow", defaultValue: "Allow")) { onRespond(.approve) }
                    Button(String(localized: "omg.chat.deny", defaultValue: "Deny")) { onRespond(.deny) }
                }
            } else {
                ForEach(prompt.questions) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: question.text).font(.system(size: 13, weight: .medium))
                        ForEach(question.options) { option in
                            Button {
                                var values = answers[question.id] ?? []
                                if question.allowsMultiple {
                                    if values.contains(option.label) { values.removeAll { $0 == option.label } }
                                    else { values.append(option.label) }
                                } else { values = [option.label] }
                                answers[question.id] = values
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: (answers[question.id] ?? []).contains(option.label) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: option.label)
                                        if !option.description.isEmpty { Text(verbatim: option.description).font(.system(size: 11)).foregroundStyle(.secondary) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        if question.allowsOther || question.options.isEmpty {
                            let binding = Binding(get: { other[question.id] ?? "" }, set: { other[question.id] = $0 })
                            if question.isSecret {
                                SecureField(String(localized: "omg.chat.answer", defaultValue: "Your answer"), text: binding)
                            } else {
                                TextField(String(localized: "omg.chat.answer", defaultValue: "Your answer"), text: binding)
                            }
                        }
                    }
                }
                HStack {
                    Button(String(localized: "omg.chat.submitAnswers", defaultValue: "Submit answers")) {
                        var submitted = answers
                        for (key, value) in other where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            submitted[key, default: []].append(value)
                        }
                        onRespond(.answers(submitted))
                    }.disabled(prompt.questions.contains { (answers[$0.id] ?? []).isEmpty && (other[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    Button(String(localized: "omg.chat.cancel", defaultValue: "Cancel request")) { onRespond(.cancel) }
                }
            }
        }.padding(16).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
