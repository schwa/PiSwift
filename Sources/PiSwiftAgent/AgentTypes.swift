import Foundation
import PiSwiftAI

public typealias StreamFn = @Sendable (Model, Context, SimpleStreamOptions) async throws -> AssistantMessageEventStream

public enum ThinkingLevel: String, Sendable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public struct AgentCustomMessage: Sendable {
    public var role: String
    public var payload: AnyCodable?
    public var timestamp: Int64

    public init(role: String, payload: AnyCodable? = nil, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.role = role
        self.payload = payload
        self.timestamp = timestamp
    }
}

public enum AgentMessage: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(AgentCustomMessage)

    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        case .custom(let custom):
            return custom.role
        }
    }

    public var timestamp: Int64 {
        switch self {
        case .user(let message):
            return message.timestamp
        case .assistant(let message):
            return message.timestamp
        case .toolResult(let message):
            return message.timestamp
        case .custom(let message):
            return message.timestamp
        }
    }

    public var asMessage: Message? {
        switch self {
        case .user(let message):
            return .user(message)
        case .assistant(let message):
            return .assistant(message)
        case .toolResult(let message):
            return .toolResult(message)
        case .custom:
            return nil
        }
    }

    public init(_ message: Message) {
        switch message {
        case .user(let msg):
            self = .user(msg)
        case .assistant(let msg):
            self = .assistant(msg)
        case .toolResult(let msg):
            self = .toolResult(msg)
        }
    }
}

public struct AgentToolResult: Sendable {
    public var content: [ContentBlock]
    public var details: AnyCodable?

    public init(content: [ContentBlock], details: AnyCodable? = nil) {
        self.content = content
        self.details = details
    }
}

public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void
public typealias AgentToolExecute = @Sendable (
    _ toolCallId: String,
    _ params: [String: AnyCodable],
    _ signal: CancellationToken?,
    _ onUpdate: AgentToolUpdateCallback?
) async throws -> AgentToolResult

public struct AgentTool: Sendable {
    public var label: String
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var execute: AgentToolExecute

    public init(
        label: String,
        name: String,
        description: String,
        parameters: [String: AnyCodable],
        execute: @escaping AgentToolExecute
    ) {
        self.label = label
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    public var aiTool: AITool {
        AITool(name: name, description: description, parameters: parameters)
    }
}

public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [AgentMessage]
    public var tools: [AgentTool]?

    public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentTool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [AgentMessage])
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    case messageStart(message: AgentMessage)
    case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: AgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: [String: AnyCodable])
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: [String: AnyCodable], partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}

public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoning: ReasoningEffort?
    public var apiKey: String?
    public var sessionId: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var convertToLlm: @Sendable ([AgentMessage]) async throws -> [Message]
    public var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?

    public init(
        model: Model,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoning: ReasoningEffort? = nil,
        apiKey: String? = nil,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        convertToLlm: @escaping @Sendable ([AgentMessage]) async throws -> [Message],
        transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.apiKey = apiKey
        self.sessionId = sessionId
        self.thinkingBudgets = thinkingBudgets
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.getApiKey = getApiKey
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
    }
}

public enum AgentSteeringMode: String, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

public enum AgentFollowUpMode: String, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [AgentMessage]
    public var isStreaming: Bool
    public var streamMessage: AgentMessage?
    public var pendingToolCalls: Set<String>
    public var error: String?

    public init(
        systemPrompt: String = "",
        model: Model = getModel(provider: .openai, modelId: "gpt-4o-mini"),
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [AgentMessage] = [],
        isStreaming: Bool = false,
        streamMessage: AgentMessage? = nil,
        pendingToolCalls: Set<String> = [],
        error: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamMessage = streamMessage
        self.pendingToolCalls = pendingToolCalls
        self.error = error
    }
}
