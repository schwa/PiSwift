import Foundation

public struct PromptTemplate: Sendable {
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

private func parseFrontmatter(_ content: String) -> (frontmatter: [String: String], content: String) {
    guard content.hasPrefix("---") else {
        return ([:], content)
    }

    guard let endRange = content.range(of: "\n---", options: [], range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else {
        return ([:], content)
    }

    let frontmatterBlock = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
    let bodyStart = content.index(endRange.lowerBound, offsetBy: 4)
    let body = String(content[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

    var frontmatter: [String: String] = [:]
    for line in frontmatterBlock.split(separator: "\n", omittingEmptySubsequences: false) {
        let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        frontmatter[key] = value
    }

    return (frontmatter, body)
}

private func resolveEntryType(_ entry: URL) -> (isDirectory: Bool, isFile: Bool)? {
    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
    let isSymlink = values?.isSymbolicLink ?? false
    if isSymlink {
        let resolved = entry.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return nil
        }
        return (isDirectory.boolValue, !isDirectory.boolValue)
    }

    return (values?.isDirectory ?? false, values?.isRegularFile ?? false)
}

private func loadTemplatesFromDir(_ dir: String, source: String, subdir: String = "") -> [PromptTemplate] {
    var templates: [PromptTemplate] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: []
    ) else {
        return templates
    }

    for entry in entries {
        let name = entry.lastPathComponent
        guard let type = resolveEntryType(entry) else { continue }
        let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let subdirName = subdir.isEmpty ? name : "\(subdir):\(name)"

        if type.isDirectory {
            templates.append(contentsOf: loadTemplatesFromDir(entry.path, source: source, subdir: subdirName))
            continue
        }

        guard type.isFile, entry.pathExtension.lowercased() == "md" else {
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
            if let firstLine = parsed.content.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = String(firstLine)
                description = line.count > 60 ? String(line.prefix(60)) + "..." : line
            }
        }

        description = description.isEmpty ? sourceStr : "\(description) \(sourceStr)"

        templates.append(PromptTemplate(name: baseName, description: description, content: parsed.content, source: sourceStr))
    }

    return templates
}

public struct LoadPromptTemplatesOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?

    public init(cwd: String? = nil, agentDir: String? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
    }
}

public func loadPromptTemplates(_ options: LoadPromptTemplatesOptions = LoadPromptTemplatesOptions()) -> [PromptTemplate] {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getPromptsDir()

    var templates: [PromptTemplate] = []

    let globalPromptsDir = options.agentDir != nil
        ? URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("prompts").path
        : resolvedAgentDir
    templates.append(contentsOf: loadTemplatesFromDir(globalPromptsDir, source: "user"))

    let projectPromptsDir = URL(fileURLWithPath: resolvedCwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("prompts").path
    templates.append(contentsOf: loadTemplatesFromDir(projectPromptsDir, source: "project"))

    return templates
}

public func expandPromptTemplate(_ text: String, _ templates: [PromptTemplate]) -> String {
    guard text.hasPrefix("/") else { return text }
    let spaceIndex = text.firstIndex(of: " ")
    let templateName: String
    let argsString: String
    if let spaceIndex {
        templateName = String(text[text.index(after: text.startIndex)..<spaceIndex])
        argsString = String(text[text.index(after: spaceIndex)...])
    } else {
        templateName = String(text.dropFirst())
        argsString = ""
    }

    if let template = templates.first(where: { $0.name == templateName }) {
        let args = parseCommandArgs(argsString)
        return substituteArgs(template.content, args)
    }

    return text
}
