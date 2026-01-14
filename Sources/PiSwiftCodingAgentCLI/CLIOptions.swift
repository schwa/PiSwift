import ArgumentParser
import Foundation
import PiSwiftAgent
import PiSwiftCodingAgent

struct CLIOptions: ParsableArguments {
    @Option(help: "Provider name")
    var provider: String?

    @Option(help: "Model ID")
    var model: String?

    @Option(name: .customLong("api-key"), help: "API key (defaults to env vars)")
    var apiKey: String?

    @Option(name: .customLong("system-prompt"), help: "System prompt")
    var systemPrompt: String?

    @Option(name: .customLong("append-system-prompt"), help: "Append text or file contents to the system prompt")
    var appendSystemPrompt: String?

    @Option(help: "Output mode: text (default), json, or rpc")
    var mode: String?

    @Flag(name: [.customShort("c"), .customLong("continue")], help: "Continue previous session")
    var continueSession: Bool = false

    @Flag(name: [.customShort("r"), .customLong("resume")], help: "Select a session to resume")
    var resume: Bool = false

    @Option(name: .customLong("thinking"), help: "Thinking level: off, minimal, low, medium, high, xhigh")
    var thinking: String?

    @Flag(name: .customLong("no-session"), help: "Don't save session (ephemeral)")
    var noSession: Bool = false

    @Option(name: .customLong("session"), help: "Use specific session file")
    var session: String?

    @Option(name: .customLong("session-dir"), help: "Directory for session storage and lookup")
    var sessionDir: String?

    @Option(name: [.customShort("m"), .customLong("models")], help: "Comma-separated model patterns for Ctrl+P cycling")
    var models: String?

    @Option(name: .customLong("tools"), help: "Comma-separated list of tools to enable")
    var tools: String?

    @Flag(name: .customLong("no-tools"), help: "Disable all built-in tools")
    var noTools: Bool = false

    @Option(name: .customLong("hook"), help: "Load a hook file (can be used multiple times)")
    var hooks: [String] = []

    @Option(name: .customLong("tool"), help: "Load a custom tool file (can be used multiple times)")
    var customTools: [String] = []

    @Flag(name: .customLong("no-extensions"), help: "Disable extension discovery")
    var noExtensions: Bool = false

    @Flag(name: [.customShort("p"), .customLong("print")], help: "Non-interactive mode: process prompt and exit")
    var print: Bool = false

    @Option(name: .customLong("export"), help: "Export session file to HTML and exit")
    var export: String?

    @Flag(name: .customLong("no-skills"), help: "Disable skills discovery and loading")
    var noSkills: Bool = false

    @Option(name: .customLong("skills"), help: "Comma-separated glob patterns to filter skills")
    var skills: String?

    @Flag(name: .customLong("list-models"), help: "List available models (with optional fuzzy search)")
    var listModels: Bool = false

    @Option(name: .customLong("list-models-search"), help: ArgumentHelp("", visibility: .hidden))
    var listModelsSearch: String?

    @Argument(help: "Messages and @file paths")
    var rawMessages: [String] = []
}

extension CLIOptions {
    func toArgs() -> Args {
        var result = Args()

        result.provider = provider
        result.model = model
        result.apiKey = apiKey
        result.systemPrompt = systemPrompt
        result.appendSystemPrompt = appendSystemPrompt
        if let mode, let parsedMode = Mode(rawValue: mode) {
            result.mode = parsedMode
        }
        if continueSession {
            result.continue = true
        }
        if resume {
            result.resume = true
        }
        if let thinking {
            if isValidThinkingLevel(thinking), let level = ThinkingLevel(rawValue: thinking) {
                result.thinking = level
            } else {
                Self.warn("Warning: Invalid thinking level \"\(thinking)\". Valid values: \(Self.thinkingLevels.joined(separator: ", "))")
            }
        }
        if noSession {
            result.noSession = true
        }
        result.session = session
        result.sessionDir = sessionDir
        if let models {
            result.models = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let tools {
            let toolNames = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var valid: [ToolName] = []
            for name in toolNames {
                if let tool = ToolName(rawValue: name) {
                    valid.append(tool)
                } else {
                    Self.warn("Warning: Unknown tool \"\(name)\". Valid tools: \(ToolName.allCases.map { $0.rawValue }.joined(separator: ", "))")
                }
            }
            result.tools = valid
        }
        if noTools {
            result.noTools = true
        }
        if !hooks.isEmpty {
            result.hooks = hooks
        }
        if !customTools.isEmpty {
            result.customTools = customTools
        }
        if noExtensions {
            result.noExtensions = true
        }
        if print {
            result.print = true
        }
        result.export = export
        if noSkills {
            result.noSkills = true
        }
        if let skills {
            result.skills = skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let listModelsSearch {
            result.listModels = .search(listModelsSearch)
        } else if listModels {
            result.listModels = .all
        }

        for arg in rawMessages {
            if arg.hasPrefix("@") {
                result.fileArgs.append(String(arg.dropFirst()))
            } else {
                result.messages.append(arg)
            }
        }

        return result
    }

    private static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]

    private static func warn(_ message: String) {
        fputs("\(message)\n", stderr)
    }
}
