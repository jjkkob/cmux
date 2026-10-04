import Foundation

/// Resolves interactive CLI executables without using the structured-chat provider arguments.
struct OMGCanvasRuntimeResolver {
    struct Launch { let command: String?; let environment: [String: String] }
    private let resolver: AgentExecutableResolver
    private let fileManager: FileManager

    init(resolver: AgentExecutableResolver, fileManager: FileManager = .default) {
        self.resolver = resolver
        self.fileManager = fileManager
    }

    func resolve(_ runtime: String) throws -> Launch {
        if runtime == "shell" { return Launch(command: nil, environment: [:]) }
        if runtime == "codex" || runtime == "claude" {
            let plan = try resolver.resolve(runtime == "codex" ? .codex : .claude)
            return Launch(command: Self.quote(plan.executableURL.path), environment: ["PATH": plan.environment["PATH"] ?? ""])
        }
        if runtime == "python" {
            for directory in resolver.resolvedSearchDirectories() {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("python3").path
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) {
                    return Launch(command: Self.quote(path), environment: [:])
                }
            }
            throw OMGCanvasBridgeRequest.Failure.missingRuntime
        }
        throw OMGCanvasBridgeRequest.Failure.invalid
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
