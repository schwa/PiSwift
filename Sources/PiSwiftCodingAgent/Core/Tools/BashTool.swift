import Foundation
import PiSwiftAI
import PiSwiftAgent

enum BashToolError: LocalizedError, Sendable {
    case operationAborted
    case missingCommand
    case commandTimedOut(seconds: Int)
    case commandAborted
    case commandFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingCommand:
            return "Missing command"
        case let .commandTimedOut(seconds):
            return "Command timed out after \(seconds) seconds"
        case .commandAborted:
            return "Command aborted"
        case let .commandFailed(exitCode):
            return "Command exited with code \(exitCode)"
        }
    }
}

public struct BashToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var fullOutputPath: String?
}

public protocol BashOperations: Sendable {
    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult
}

public struct DefaultBashOperations: BashOperations {
    public init() {}

    public func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        try await executeBash(command, options: options)
    }
}

public struct BashToolOptions: Sendable {
    public var operations: BashOperations?

    public init(operations: BashOperations? = nil) {
        self.operations = operations
    }
}

public func createBashTool(cwd: String, options: BashToolOptions? = nil) -> PiSwiftAgent.AgentTool {
    let parameters: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "command": ["type": "string", "description": "Bash command to execute"],
            "timeout": ["type": "number", "description": "Timeout in seconds (optional)"],
        ]),
    ]
    @Sendable func execute(
        _ toolCallId: String,
        _ params: [String: AnyCodable],
        _ signal: CancellationToken?,
        _ onUpdate: AgentToolUpdateCallback?
    ) async throws -> AgentToolResult {
        _ = toolCallId
        if signal?.isCancelled == true {
            throw BashToolError.operationAborted
        }
        guard let command = params["command"]?.value as? String else {
            throw BashToolError.missingCommand
        }
        let timeoutValue: Double? = doubleValue(params["timeout"])
        let operations: BashOperations = options?.operations ?? DefaultBashOperations()
        let outputState: LockedState<String> = LockedState("")
        let onChunk: (@Sendable (String) -> Void)?
        if let onUpdate {
            onChunk = { chunk in
                let current: String = outputState.withLock { state in
                    state += chunk
                    return state
                }
                let text = current.isEmpty ? "(no output)" : current
                onUpdate(AgentToolResult(content: [.text(TextContent(text: text))]))
            }
        } else {
            onChunk = nil
        }
        let result: BashResult = try await operations.execute(
            command,
            options: BashExecutorOptions(onChunk: onChunk, signal: signal, timeoutSeconds: timeoutValue)
        )
        if result.cancelled {
            if let timeoutValue {
                throw BashToolError.commandTimedOut(seconds: Int(timeoutValue))
            }
            throw BashToolError.commandAborted
        }
        if let exitCode = result.exitCode, exitCode != 0 {
            throw BashToolError.commandFailed(exitCode: exitCode)
        }
        let output = result.output.isEmpty ? "(no output)" : result.output
        return AgentToolResult(content: [.text(TextContent(text: output))])
    }
    return PiSwiftAgent.AgentTool(
        label: "bash",
        name: "bash",
        description: "Execute a bash command in the current working directory. Returns stdout and stderr.",
        parameters: parameters,
        execute: execute
    )
}

public let bashTool = createBashTool(cwd: FileManager.default.currentDirectoryPath)
