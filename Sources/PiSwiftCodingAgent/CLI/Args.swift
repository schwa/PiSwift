import Foundation
import PiSwiftAgent

public enum Mode: String, Sendable {
    case text
    case json
    case rpc
}

public enum ListModelsOption: Equatable, Sendable {
    case all
    case search(String)
}

public struct Args: Sendable {
    public var provider: String?
    public var model: String?
    public var apiKey: String?
    public var systemPrompt: String?
    public var appendSystemPrompt: String?
    public var thinking: ThinkingLevel?
    public var `continue`: Bool?
    public var resume: Bool?
    public var help: Bool?
    public var version: Bool?
    public var mode: Mode?
    public var noSession: Bool?
    public var session: String?
    public var sessionDir: String?
    public var models: [String]?
    public var tools: [ToolName]?
    public var hooks: [String]?
    public var customTools: [String]?
    public var print: Bool?
    public var export: String?
    public var noSkills: Bool?
    public var skills: [String]?
    public var listModels: ListModelsOption?
    public var messages: [String]
    public var fileArgs: [String]

    public init() {
        self.messages = []
        self.fileArgs = []
    }
}

private let validThinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh"]

public func isValidThinkingLevel(_ level: String) -> Bool {
    validThinkingLevels.contains(level)
}

public func parseArgs(_ args: [String]) -> Args {
    var result = Args()

    var i = 0
    while i < args.count {
        let arg = args[i]

        switch arg {
        case "--help", "-h":
            result.help = true
        case "--version", "-v":
            result.version = true
        case "--mode":
            if i + 1 < args.count {
                let modeValue = args[i + 1]
                if let mode = Mode(rawValue: modeValue) {
                    result.mode = mode
                }
                i += 1
            }
        case "--continue", "-c":
            result.continue = true
        case "--resume", "-r":
            result.resume = true
        case "--provider":
            if i + 1 < args.count {
                result.provider = args[i + 1]
                i += 1
            }
        case "--model":
            if i + 1 < args.count {
                result.model = args[i + 1]
                i += 1
            }
        case "--api-key":
            if i + 1 < args.count {
                result.apiKey = args[i + 1]
                i += 1
            }
        case "--system-prompt":
            if i + 1 < args.count {
                result.systemPrompt = args[i + 1]
                i += 1
            }
        case "--append-system-prompt":
            if i + 1 < args.count {
                result.appendSystemPrompt = args[i + 1]
                i += 1
            }
        case "--no-session":
            result.noSession = true
        case "--session":
            if i + 1 < args.count {
                result.session = args[i + 1]
                i += 1
            }
        case "--session-dir":
            if i + 1 < args.count {
                result.sessionDir = args[i + 1]
                i += 1
            }
        case "--models":
            if i + 1 < args.count {
                result.models = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                i += 1
            }
        case "--tools":
            if i + 1 < args.count {
                let toolNames = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let valid = toolNames.compactMap { ToolName(rawValue: $0) }
                result.tools = valid
                i += 1
            }
        case "--thinking":
            if i + 1 < args.count {
                let level = args[i + 1]
                if isValidThinkingLevel(level) {
                    result.thinking = ThinkingLevel(rawValue: level)
                }
                i += 1
            }
        case "--print", "-p":
            result.print = true
        case "--export":
            if i + 1 < args.count {
                result.export = args[i + 1]
                i += 1
            }
        case "--hook":
            if i + 1 < args.count {
                result.hooks = result.hooks ?? []
                result.hooks?.append(args[i + 1])
                i += 1
            }
        case "--tool":
            if i + 1 < args.count {
                result.customTools = result.customTools ?? []
                result.customTools?.append(args[i + 1])
                i += 1
            }
        case "--no-skills":
            result.noSkills = true
        case "--skills":
            if i + 1 < args.count {
                result.skills = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                i += 1
            }
        case "--list-models":
            if i + 1 < args.count, !args[i + 1].hasPrefix("-"), !args[i + 1].hasPrefix("@") {
                result.listModels = .search(args[i + 1])
                i += 1
            } else {
                result.listModels = .all
            }
        default:
            if arg.hasPrefix("@") {
                result.fileArgs.append(String(arg.dropFirst()))
            } else if !arg.hasPrefix("-") {
                result.messages.append(arg)
            }
        }

        i += 1
    }

    return result
}

public func printHelp() {
    print("\(APP_NAME) - AI coding assistant\n")
    print("Usage:\n  \(APP_NAME) [options] [@files...] [messages...]\n")
}
