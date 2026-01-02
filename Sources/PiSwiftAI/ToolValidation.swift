import Foundation

public func validateToolCall(tools: [AITool], toolCall: ToolCall) throws -> [String: AnyCodable] {
    guard tools.contains(where: { $0.name == toolCall.name }) else {
        throw ValidationError.toolNotFound(toolCall.name)
    }
    return toolCall.arguments
}

public func validateToolArguments(tool: AITool, toolCall: ToolCall) throws -> [String: AnyCodable] {
    guard tool.name == toolCall.name else {
        throw ValidationError.toolNotFound(toolCall.name)
    }
    return toolCall.arguments
}

public enum ValidationError: Error, LocalizedError {
    case toolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool \"\(name)\" not found"
        }
    }
}
