import Foundation
import PiSwiftAgent

public extension AgentEvent {
    var type: String {
        switch self {
        case .agentStart:
            return "agent_start"
        case .agentEnd:
            return "agent_end"
        case .turnStart:
            return "turn_start"
        case .turnEnd:
            return "turn_end"
        case .messageStart:
            return "message_start"
        case .messageUpdate:
            return "message_update"
        case .messageEnd:
            return "message_end"
        case .toolExecutionStart:
            return "tool_execution_start"
        case .toolExecutionUpdate:
            return "tool_execution_update"
        case .toolExecutionEnd:
            return "tool_execution_end"
        }
    }
}
