import Foundation

public enum SubagentSource: String, Sendable {
    case user
    case project
}

public enum SubagentScope: String, Sendable {
    case user
    case project
    case both
}

public struct SubagentConfig: Sendable {
    public var name: String
    public var description: String
    public var tools: [String]
    public var model: String?
    public var outputFormat: String?
    public var systemPrompt: String
    public var source: SubagentSource
    public var sourceLabel: String
    public var path: String

    public init(
        name: String,
        description: String,
        tools: [String],
        model: String?,
        outputFormat: String?,
        systemPrompt: String,
        source: SubagentSource,
        sourceLabel: String,
        path: String
    ) {
        self.name = name
        self.description = description
        self.tools = tools
        self.model = model
        self.outputFormat = outputFormat
        self.systemPrompt = systemPrompt
        self.source = source
        self.sourceLabel = sourceLabel
        self.path = path
    }
}

public struct SubagentDiscoveryResult: Sendable {
    public var agents: [SubagentConfig]
    public var projectAgentsDir: String?

    public init(agents: [SubagentConfig], projectAgentsDir: String?) {
        self.agents = agents
        self.projectAgentsDir = projectAgentsDir
    }
}

public struct LoadSubagentsOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var scope: SubagentScope?

    public init(cwd: String? = nil, agentDir: String? = nil, scope: SubagentScope? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.scope = scope
    }
}

private func parseToolsList(_ raw: String) -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if !trimmed.contains(",") {
        return trimmed.split(whereSeparator: { $0.isWhitespace }).map { String($0) }.filter { !$0.isEmpty }
    }
    return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func loadAgentsFromDir(_ dir: String, source: SubagentSource) -> [SubagentConfig] {
    var agents: [SubagentConfig] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: []
    ) else {
        return agents
    }

    for entry in entries {
        guard entry.pathExtension.lowercased() == "md" else { continue }
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        let isDir = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false
        let isFile = values?.isRegularFile ?? false
        if isDir || (!isFile && !isSymlink) {
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
        let name = parsed.frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false) ? name! : baseName
        if resolvedName.isEmpty {
            continue
        }

        var description = parsed.frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            if let firstLine = parsed.body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = String(firstLine)
                description = line.count > 60 ? String(line.prefix(60)) + "..." : line
            }
        }
        if description.isEmpty {
            description = "(\(source.rawValue))"
        }

        let tools = parseToolsList(parsed.frontmatter["tools"] ?? "")
        let model = parsed.frontmatter["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputFormat = parsed.frontmatter["outputFormat"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? parsed.frontmatter["output_format"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        agents.append(SubagentConfig(
            name: resolvedName,
            description: description,
            tools: tools,
            model: model?.isEmpty == false ? model : nil,
            outputFormat: outputFormat?.isEmpty == false ? outputFormat : nil,
            systemPrompt: parsed.body,
            source: source,
            sourceLabel: source.rawValue,
            path: entry.path
        ))
    }

    return agents
}

private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
    return isDir.boolValue
}

private func findNearestProjectAgentsDir(_ cwd: String) -> String? {
    var currentDir = cwd
    while true {
        let candidate = URL(fileURLWithPath: currentDir)
            .appendingPathComponent(CONFIG_DIR_NAME)
            .appendingPathComponent("agents")
            .path
        if isDirectory(candidate) {
            return candidate
        }
        if currentDir == "/" { return nil }
        let parent = URL(fileURLWithPath: currentDir).deletingLastPathComponent().path
        if parent == currentDir { return nil }
        currentDir = parent
    }
}

public func loadSubagents(_ options: LoadSubagentsOptions = LoadSubagentsOptions()) -> SubagentDiscoveryResult {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getAgentDir()
    let scope = options.scope ?? .user

    let userAgentsDir = options.agentDir != nil
        ? URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("agents").path
        : getAgentsDir()
    let projectAgentsDir = findNearestProjectAgentsDir(resolvedCwd)

    let userAgents = scope == .project ? [] : loadAgentsFromDir(userAgentsDir, source: .user)
    let projectAgents = scope == .user || projectAgentsDir == nil ? [] : loadAgentsFromDir(projectAgentsDir!, source: .project)

    var agentMap: [String: SubagentConfig] = [:]
    switch scope {
    case .both:
        for agent in userAgents {
            agentMap[agent.name] = agent
        }
        for agent in projectAgents {
            agentMap[agent.name] = agent
        }
    case .user:
        for agent in userAgents {
            agentMap[agent.name] = agent
        }
    case .project:
        for agent in projectAgents {
            agentMap[agent.name] = agent
        }
    }

    return SubagentDiscoveryResult(
        agents: Array(agentMap.values),
        projectAgentsDir: projectAgentsDir
    )
}
