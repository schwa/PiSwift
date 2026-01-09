#if !canImport(UIKit)
import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct BashToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var fullOutputPath: String?
}

public func createBashTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "bash",
        name: "bash",
        description: "Execute a bash command in the current working directory. Returns stdout and stderr.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "command": ["type": "string", "description": "Bash command to execute"],
                "timeout": ["type": "number", "description": "Timeout in seconds (optional)"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw NSError(domain: "BashTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation aborted"])
        }
        guard let command = params["command"]?.value as? String else {
            throw NSError(domain: "BashTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing command"])
        }
        let timeoutValue = doubleValue(params["timeout"])

        let result = try await executeBash(command, options: BashExecutorOptions(onChunk: nil, signal: signal, timeoutSeconds: timeoutValue))

        if result.cancelled {
            if let timeoutValue {
                throw NSError(domain: "BashTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Command timed out after \(Int(timeoutValue)) seconds"])
            }
            throw NSError(domain: "BashTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Command aborted"])
        }

        if let exitCode = result.exitCode, exitCode != 0 {
            throw NSError(domain: "BashTool", code: 5, userInfo: [NSLocalizedDescriptionKey: "Command exited with code \(exitCode)"])
        }

        return AgentToolResult(content: [.text(TextContent(text: result.output.isEmpty ? "(no output)" : result.output))])
    }
}

public let bashTool = createBashTool(cwd: FileManager.default.currentDirectoryPath)
#endif
