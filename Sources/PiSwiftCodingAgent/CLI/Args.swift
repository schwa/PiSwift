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
private let toolNames = ToolName.allCases.map { $0.rawValue }

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
                var valid: [ToolName] = []
                for name in toolNames {
                    if let tool = ToolName(rawValue: name) {
                        valid.append(tool)
                    } else {
                        warn("Warning: Unknown tool \"\(name)\". Valid tools: \(ToolName.allCases.map { $0.rawValue }.joined(separator: ", "))")
                    }
                }
                result.tools = valid
                i += 1
            }
        case "--thinking":
            if i + 1 < args.count {
                let level = args[i + 1]
                if isValidThinkingLevel(level) {
                    result.thinking = ThinkingLevel(rawValue: level)
                } else {
                    warn("Warning: Invalid thinking level \"\(level)\". Valid values: \(validThinkingLevels.sorted().joined(separator: ", "))")
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
    let toolsList = ToolName.allCases.map { $0.rawValue }.joined(separator: ", ")
    let help = """
\(APP_NAME) - AI coding assistant

Usage:
  \(APP_NAME) [options] [@files...] [messages...]

Options:
  --provider <name>              Provider name
  --model <id>                   Model ID
  --api-key <key>                API key (defaults to env vars)
  --system-prompt <text>         System prompt
  --append-system-prompt <text>  Append text or file contents to the system prompt
  --mode <mode>                  Output mode: text (default), json, or rpc
  --print, -p                    Non-interactive mode: process prompt and exit
  --continue, -c                 Continue previous session
  --resume, -r                   Select a session to resume
  --session <path>               Use specific session file
  --session-dir <dir>            Directory for session storage and lookup
  --no-session                   Don't save session (ephemeral)
  --models <patterns>            Comma-separated model patterns for Ctrl+P cycling
                                 Supports globs (anthropic/*, *sonnet*) and fuzzy matching
  --tools <tools>                Comma-separated list of tools to enable (default: read,bash,edit,write)
                                 Available: \(toolsList)
  --thinking <level>             Set thinking level: off, minimal, low, medium, high, xhigh
  --hook <path>                  Load a hook file (can be used multiple times)
  --tool <path>                  Load a custom tool file (can be used multiple times)
  --no-skills                    Disable skills discovery and loading
  --skills <patterns>            Comma-separated glob patterns to filter skills (e.g., git-*,docker)
  --export <file>                Export session file to HTML and exit
  --list-models [search]         List available models (with optional fuzzy search)
  --help, -h                     Show this help
  --version, -v                  Show version number

Examples:
  # Interactive mode
  \(APP_NAME)

  # Interactive mode with initial prompt
  \(APP_NAME) "List all .ts files in src/"

  # Include files in initial message
  \(APP_NAME) @prompt.md @image.png "What color is the sky?"

  # Non-interactive mode (process and exit)
  \(APP_NAME) -p "List all .ts files in src/"

  # Multiple messages (interactive)
  \(APP_NAME) "Read package.json" "What dependencies do we have?"

  # Continue previous session
  \(APP_NAME) --continue "What did we discuss?"

  # Use different model
  \(APP_NAME) --provider openai --model gpt-4o-mini "Help me refactor this code"

  # Limit model cycling to specific models
  \(APP_NAME) --models claude-sonnet,claude-haiku,gpt-4o

  # Limit to a specific provider with glob pattern
  \(APP_NAME) --models "github-copilot/*"

  # Cycle models with fixed thinking levels
  \(APP_NAME) --models sonnet:high,haiku:low

  # Start with a specific thinking level
  \(APP_NAME) --thinking high "Solve this complex problem"

  # Read-only mode (no file modifications possible)
  \(APP_NAME) --tools read,grep,find,ls -p "Review the code in src/"

  # Export a session file to HTML
  \(APP_NAME) --export ~/\(CONFIG_DIR_NAME)/agent/sessions/--path--/session.jsonl
  \(APP_NAME) --export session.jsonl output.html

Environment Variables:
  ANTHROPIC_API_KEY       - Anthropic Claude API key
  ANTHROPIC_OAUTH_TOKEN   - Anthropic OAuth token (alternative to API key)
  OPENAI_API_KEY          - OpenAI GPT API key
  GEMINI_API_KEY          - Google Gemini API key
  GROQ_API_KEY            - Groq API key
  CEREBRAS_API_KEY        - Cerebras API key
  XAI_API_KEY             - xAI Grok API key
  OPENROUTER_API_KEY      - OpenRouter API key
  ZAI_API_KEY             - ZAI API key
  \(ENV_AGENT_DIR) - Session storage directory (default: ~/\(CONFIG_DIR_NAME)/agent)

Available Tools (default: read, bash, edit, write):
  read   - Read file contents
  bash   - Execute bash commands
  edit   - Edit files with find/replace
  write  - Write files (creates/overwrites)
  grep   - Search file contents (read-only, off by default)
  find   - Find files by glob pattern (read-only, off by default)
  ls     - List directory contents (read-only, off by default)
"""
    print(help)
}

private func warn(_ message: String) {
    fputs("\(message)\n", stderr)
}
