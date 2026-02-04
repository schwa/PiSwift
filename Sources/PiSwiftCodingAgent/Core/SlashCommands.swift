import Foundation

public struct FileSlashCommand: Sendable {
    public var name: String
    public var description: String
    public var content: String
    public var source: String

    public init(name: String, description: String, content: String, source: String) {
        self.name = name
        self.description = description
        self.content = content
        self.source = source
    }
}

public func parseCommandArgs(_ argsString: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inQuote: Character? = nil

    for char in argsString {
        if let quote = inQuote {
            if char == quote {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char == " " || char == "\t" {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }

    if !current.isEmpty {
        args.append(current)
    }

    return args
}

public func substituteArgs(_ content: String, _ args: [String]) -> String {
    var result = content

    if let regex = try? NSRegularExpression(pattern: "\\$(\\d+)", options: []) {
        let range = NSRange(location: 0, length: result.utf16.count)
        let matches = regex.matches(in: result, options: [], range: range)
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let fullRange = match.range(at: 0)
            let numRange = match.range(at: 1)
            guard let numberRange = Range(numRange, in: result),
                  let replaceRange = Range(fullRange, in: result) else { continue }
            let index = Int(result[numberRange]) ?? 0
            let replacement = (index > 0 && args.indices.contains(index - 1)) ? args[index - 1] : ""
            result.replaceSubrange(replaceRange, with: replacement)
        }
    }

    let allArgs = args.joined(separator: " ")
    result = result.replacingOccurrences(of: "$ARGUMENTS", with: allArgs)
    result = result.replacingOccurrences(of: "$@", with: allArgs)

    return result
}

private func loadCommandsFromDir(_ dir: String, source: String, subdir: String = "") -> [FileSlashCommand] {
    var commands: [FileSlashCommand] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return commands
    }

    for entry in entries {
        let name = entry.lastPathComponent
        let subdirName = subdir.isEmpty ? name : "\(subdir):\(name)"
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDir = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false

        if isDir {
            commands.append(contentsOf: loadCommandsFromDir(entry.path, source: source, subdir: subdirName))
            continue
        }

        if !(entry.pathExtension.lowercased() == "md") {
            continue
        }

        if !isSymlink && !FileManager.default.isReadableFile(atPath: entry.path) {
            continue
        }

        guard let rawContent = try? String(contentsOfFile: entry.path, encoding: .utf8) else {
            continue
        }

        let parsed = parseFrontmatter(rawContent)
        let baseName = entry.deletingPathExtension().lastPathComponent

        let sourceStr: String = {
            if source == "user" {
                return subdir.isEmpty ? "(user)" : "(user:\(subdir))"
            }
            return subdir.isEmpty ? "(project)" : "(project:\(subdir))"
        }()

        var description = parsed.frontmatter["description"] ?? ""
        if description.isEmpty {
            if let firstLine = parsed.body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = String(firstLine)
                description = line.count > 60 ? String(line.prefix(60)) + "..." : line
            }
        }

        description = description.isEmpty ? sourceStr : "\(description) \(sourceStr)"

        commands.append(FileSlashCommand(name: baseName, description: description, content: parsed.body, source: sourceStr))
    }

    return commands
}

public struct LoadSlashCommandsOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?

    public init(cwd: String? = nil, agentDir: String? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
    }
}

public func loadSlashCommands(_ options: LoadSlashCommandsOptions = LoadSlashCommandsOptions()) -> [FileSlashCommand] {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getCommandsDir()

    var commands: [FileSlashCommand] = []

    let globalCommandsDir = options.agentDir != nil
        ? URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("commands").path
        : resolvedAgentDir
    commands.append(contentsOf: loadCommandsFromDir(globalCommandsDir, source: "user"))

    let projectCommandsDir = URL(fileURLWithPath: resolvedCwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("commands").path
    commands.append(contentsOf: loadCommandsFromDir(projectCommandsDir, source: "project"))

    return commands
}

public func expandSlashCommand(_ text: String, _ fileCommands: [FileSlashCommand]) -> String {
    guard text.hasPrefix("/") else { return text }
    let spaceIndex = text.firstIndex(of: " ")
    let commandName: String
    let argsString: String
    if let spaceIndex {
        commandName = String(text[text.index(after: text.startIndex)..<spaceIndex])
        argsString = String(text[text.index(after: spaceIndex)...])
    } else {
        commandName = String(text.dropFirst())
        argsString = ""
    }

    if let command = fileCommands.first(where: { $0.name == commandName }) {
        let args = parseCommandArgs(argsString)
        return substituteArgs(command.content, args)
    }

    return text
}
