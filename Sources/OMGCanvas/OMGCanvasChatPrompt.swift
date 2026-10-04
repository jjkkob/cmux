import Foundation

struct OMGCanvasChatPrompt: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case approval, questions }
    struct Option: Identifiable, Equatable, Sendable {
        var id: String { label }
        let label: String
        let description: String
    }
    struct Question: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let options: [Option]
        var allowsOther: Bool = true
        var isSecret: Bool = false
        var allowsMultiple: Bool = false
    }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    var questions: [Question] = []
}
