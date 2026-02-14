import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// MARK: - Extension State

final class McpExtensionState: Sendable {
    let manager: McpServerManager
    let lifecycle: McpLifecycleManager
    let toolMetadata: LockedState<[String: [ToolMetadata]]>
    let config: McpConfig
    let failureTracker: LockedState<[String: Date]>
    let prefix: String

    init(manager: McpServerManager, lifecycle: McpLifecycleManager, config: McpConfig, prefix: String) {
        self.manager = manager
        self.lifecycle = lifecycle
        self.toolMetadata = LockedState([:])
        self.config = config
        self.failureTracker = LockedState([:])
        self.prefix = prefix
    }
}

// MARK: - Constants

private let failureBackoffSeconds: TimeInterval = 60
private let maxParallelConnections = 10
private let builtinToolNames: Set<String> = ["read", "bash", "edit", "write", "grep", "find", "ls", "mcp", "subagent"]

// MARK: - Direct Tool Spec

struct DirectToolSpec: Sendable {
    var prefixedName: String
    var originalName: String
    var serverName: String
    var description: String
    var inputSchema: AnyCodable?
    var resourceUri: String?
}

// MARK: - Public API

public enum McpAdapter {
    public static func register(api: HookAPI) {
        registerMcpAdapter(api)
    }

    public static func hookDefinition(path: String? = "mcp-adapter") -> HookDefinition {
        HookDefinition(path: path, factory: registerMcpAdapter)
    }
}

// MARK: - Registration

public func registerMcpAdapter(_ pi: HookAPI) {
    // Register --mcp-config flag
    pi.registerFlag("mcp-config", HookFlagOptions(
        description: "Path to MCP configuration file",
        type: .string,
        defaultValue: nil
    ))

    // State box: nil until session_start completes
    let stateBox = LockedState<McpExtensionState?>(nil)
    let initPromiseBox = LockedState<Task<McpExtensionState?, Never>?>(nil)

    // Helper: wait for state
    let getState: @Sendable () async -> McpExtensionState? = {
        if let s = stateBox.withLock({ $0 }) { return s }
        if let task = initPromiseBox.withLock({ $0 }) {
            return await task.value
        }
        return nil
    }

    // Early config + cache for direct tool registration
    let earlyConfigPath = findEarlyConfigPath()
    let earlyConfig = loadMcpConfig(overridePath: earlyConfigPath)
    let earlyCache = loadMetadataCache()
    let prefix = earlyConfig.settings?.toolPrefix ?? "server"

    // Resolve direct tools from cache
    let directSpecs = resolveDirectTools(config: earlyConfig, cache: earlyCache, prefix: prefix)

    // Register unified mcp proxy tool
    let proxyDescription = buildProxyDescription(config: earlyConfig, cache: earlyCache, directSpecs: directSpecs)
    registerProxyTool(pi, description: proxyDescription, getState: getState)

    // Register direct tools
    for spec in directSpecs {
        registerDirectTool(pi, spec: spec, getState: getState)
    }

    // Register /mcp command
    pi.registerCommand("mcp", description: "Show MCP server status") { args, ctx in
        guard let state = await getState() else {
            await ctx.ui.notify("MCP not initialized", .warning)
            return
        }
        let status = await buildStatusText(state)
        await ctx.ui.notify(status, .info)
    }

    // Register /mcp-auth command
    pi.registerCommand("mcp-auth", description: "Show OAuth setup instructions for an MCP server") { args, ctx in
        let serverName = args.trimmingCharacters(in: .whitespaces)
        if serverName.isEmpty {
            await ctx.ui.notify("Usage: /mcp-auth <server-name>", .warning)
            return
        }
        let instructions = buildAuthInstructions(serverName: serverName)
        await ctx.ui.notify(instructions, .info)
    }

    // session_start: non-blocking init
    pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) -> Any? in
        let task = Task { @Sendable () -> McpExtensionState? in
            do {
                let configPath = pi.getFlag("mcp-config").flatMap { flag -> String? in
                    if case .string(let s) = flag { return s }
                    return nil
                }
                let state = try await initializeMcp(configPath: configPath)
                stateBox.withLock { $0 = state }
                return state
            } catch {
                fputs("[mcp] Initialization failed: \(error)\n", stderr)
                return nil
            }
        }
        initPromiseBox.withLock { $0 = task }
        return nil
    }

    // session_shutdown: graceful shutdown + cache flush
    pi.on("session_shutdown") { (event: SessionShutdownEvent, ctx: HookContext) -> Any? in
        // Wait for init if still pending
        if let task = initPromiseBox.withLock({ $0 }) {
            let result = await task.value
            if stateBox.withLock({ $0 }) == nil {
                stateBox.withLock { $0 = result }
            }
        }

        if let state = stateBox.withLock({ $0 }) {
            flushMetadataCache(state)
            await state.lifecycle.gracefulShutdown()
            stateBox.withLock { $0 = nil }
        }
        return nil
    }
}

// MARK: - Proxy Tool Registration

private func registerProxyTool(_ pi: HookAPI, description: String, getState: @escaping @Sendable () async -> McpExtensionState?) {
    // We can't use pi.registerTool directly - we create an AgentTool-compatible definition
    // through the HookAPI event system. The proxy tool is registered as a command-driven tool.
    // For v1 integration, the tool is exposed through the extension system.

    // Note: Since HookAPI doesn't have registerTool(), the proxy tool and direct tools
    // are registered by the caller that integrates McpAdapter into the session creation.
    // This function is a placeholder for the integration point.
}

// MARK: - Proxy Tool Execution

func executeProxyTool(params: [String: AnyCodable], state: McpExtensionState) async throws -> AgentToolResult {
    let tool = params["tool"]?.value as? String
    let connect = params["connect"]?.value as? String
    let describe = params["describe"]?.value as? String
    let search = params["search"]?.value as? String
    let serverFilter = params["server"]?.value as? String

    // Mode resolution: tool > connect > describe > search > server > status
    if let toolName = tool {
        return try await executeToolCall(
            toolName: toolName,
            argsJson: params["args"]?.value as? String,
            serverFilter: serverFilter,
            state: state
        )
    }

    if let serverName = connect {
        return try await executeConnect(serverName: serverName, state: state)
    }

    if let toolName = describe {
        return executeDescribe(toolName: toolName, serverFilter: serverFilter, state: state)
    }

    if let query = search {
        let useRegex = params["regex"]?.value as? Bool ?? false
        let includeSchemas = params["includeSchemas"]?.value as? Bool ?? true
        return executeSearch(query: query, useRegex: useRegex, includeSchemas: includeSchemas, serverFilter: serverFilter, state: state)
    }

    if let serverName = serverFilter {
        return executeListServer(serverName: serverName, state: state)
    }

    return executeStatus(state: state)
}

// MARK: - Mode Implementations

private func executeToolCall(toolName: String, argsJson: String?, serverFilter: String?, state: McpExtensionState) async throws -> AgentToolResult {
    // Find the tool
    guard let (serverName, metadata) = findToolByName(toolName, serverFilter: serverFilter, state: state) else {
        return AgentToolResult(content: [.text(TextContent(text: "Tool not found: \(toolName). Use mcp({ search: \"...\" }) to find tools."))])
    }

    // Parse arguments
    var arguments: [String: AnyCodable] = [:]
    if let json = argsJson, !json.isEmpty {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AgentToolResult(content: [.text(TextContent(text: "Invalid JSON in args parameter"))])
        }
        arguments = parsed.mapValues { AnyCodable($0) }
    }

    // Check failure backoff
    let isBackoff = state.failureTracker.withLock { tracker in
        if let failedAt = tracker[serverName] {
            return Date().timeIntervalSince(failedAt) < failureBackoffSeconds
        }
        return false
    }
    if isBackoff {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" recently failed. Retry in \(Int(failureBackoffSeconds))s or use mcp({ connect: \"\(serverName)\" }) to reconnect."))])
    }

    // Lazy connect
    let definition = state.config.mcpServers[serverName]
    guard let definition else {
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" not found in config"))])
    }

    do {
        await state.manager.incrementInFlight(name: serverName)
        defer { Task { await state.manager.decrementInFlight(name: serverName) } }

        let isConnected = await state.manager.isConnected(name: serverName)
        if !isConnected {
            _ = try await state.manager.connect(name: serverName, definition: definition)
            // Update metadata
            if let conn = await state.manager.getConnection(name: serverName) {
                updateToolMetadata(state: state, serverName: serverName, connection: conn, definition: definition)
            }
        }

        await state.manager.touch(name: serverName)

        // Handle resource tools
        if let resourceUri = metadata.resourceUri {
            guard let conn = await state.manager.getConnection(name: serverName) else {
                throw McpError.connectionFailed("Not connected to \(serverName)")
            }
            let contents = try await conn.client.readResource(uri: resourceUri)
            let mcpContent = contents.map { c -> McpContent in
                McpContent(type: "resource", resource: c, uri: c.uri)
            }
            let blocks = transformMcpContent(mcpContent)
            return AgentToolResult(content: blocks)
        }

        // Call tool
        guard let conn = await state.manager.getConnection(name: serverName) else {
            throw McpError.connectionFailed("Not connected to \(serverName)")
        }
        let result = try await conn.client.callTool(name: metadata.originalName, arguments: arguments)
        let blocks = transformMcpContent(result.content)

        // Clear failure tracker on success
        state.failureTracker.withLock { $0.removeValue(forKey: serverName) }

        return AgentToolResult(content: blocks)

    } catch {
        state.failureTracker.withLock { $0[serverName] = Date() }
        return AgentToolResult(content: [.text(TextContent(text: "Error calling \(toolName): \(error)"))])
    }
}

private func executeConnect(serverName: String, state: McpExtensionState) async throws -> AgentToolResult {
    guard let definition = state.config.mcpServers[serverName] else {
        let available = state.config.mcpServers.keys.sorted().joined(separator: ", ")
        return AgentToolResult(content: [.text(TextContent(text: "Server \"\(serverName)\" not found. Available: \(available)"))])
    }

    do {
        let conn = try await state.manager.connect(name: serverName, definition: definition)
        updateToolMetadata(state: state, serverName: serverName, connection: conn, definition: definition)

        // Clear failure tracker
        state.failureTracker.withLock { $0.removeValue(forKey: serverName) }

        let toolCount = conn.tools.count
        let resourceCount = conn.resources.count
        var msg = "Connected to \"\(serverName)\": \(toolCount) tool(s)"
        if resourceCount > 0 { msg += ", \(resourceCount) resource(s)" }
        return AgentToolResult(content: [.text(TextContent(text: msg))])
    } catch {
        state.failureTracker.withLock { $0[serverName] = Date() }
        return AgentToolResult(content: [.text(TextContent(text: "Failed to connect to \"\(serverName)\": \(error)"))])
    }
}

private func executeDescribe(toolName: String, serverFilter: String?, state: McpExtensionState) -> AgentToolResult {
    guard let (serverName, metadata) = findToolByName(toolName, serverFilter: serverFilter, state: state) else {
        return AgentToolResult(content: [.text(TextContent(text: "Tool not found: \(toolName)"))])
    }

    var lines: [String] = []
    lines.append("Tool: \(metadata.name)")
    lines.append("Server: \(serverName)")
    lines.append("Original name: \(metadata.originalName)")
    lines.append("Description: \(metadata.description)")

    if let schema = metadata.inputSchema {
        if let data = try? JSONSerialization.data(withJSONObject: schema.value, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            lines.append("Parameters:")
            lines.append(json)
        }
    }

    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeSearch(query: String, useRegex: Bool, includeSchemas: Bool, serverFilter: String?, state: McpExtensionState) -> AgentToolResult {
    let allMetadata = state.toolMetadata.withLock { $0 }
    var results: [(server: String, tool: ToolMetadata)] = []

    let words = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }

    for (server, tools) in allMetadata {
        if let filter = serverFilter, server != filter { continue }
        for tool in tools {
            let matched: Bool
            if useRegex {
                let regex = try? NSRegularExpression(pattern: query, options: .caseInsensitive)
                let nameRange = NSRange(tool.name.startIndex..., in: tool.name)
                let descRange = NSRange(tool.description.startIndex..., in: tool.description)
                matched = regex?.firstMatch(in: tool.name, range: nameRange) != nil
                    || regex?.firstMatch(in: tool.description, range: descRange) != nil
            } else {
                let searchName = tool.name.lowercased()
                let searchDesc = tool.description.lowercased()
                matched = words.contains { searchName.contains($0) || searchDesc.contains($0) }
            }
            if matched {
                results.append((server, tool))
            }
        }
    }

    if results.isEmpty {
        return AgentToolResult(content: [.text(TextContent(text: "No tools found matching \"\(query)\""))])
    }

    var lines: [String] = ["Found \(results.count) tool(s):"]
    for (server, tool) in results {
        lines.append("")
        lines.append("  \(tool.name) (server: \(server))")
        lines.append("    \(tool.description)")
        if includeSchemas, let schema = tool.inputSchema,
           let data = try? JSONSerialization.data(withJSONObject: schema.value, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            lines.append("    Parameters: \(json)")
        }
    }

    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeListServer(serverName: String, state: McpExtensionState) -> AgentToolResult {
    let tools = state.toolMetadata.withLock { $0[serverName] } ?? []
    if tools.isEmpty {
        return AgentToolResult(content: [.text(TextContent(text: "No tools cached for server \"\(serverName)\". Use mcp({ connect: \"\(serverName)\" }) first."))])
    }

    var lines: [String] = ["Server \"\(serverName)\" tools (\(tools.count)):"]
    for tool in tools {
        lines.append("  \(tool.name): \(tool.description)")
    }
    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

private func executeStatus(state: McpExtensionState) -> AgentToolResult {
    var lines: [String] = ["MCP Status:"]
    let metadata = state.toolMetadata.withLock { $0 }

    for (name, _) in state.config.mcpServers.sorted(by: { $0.key < $1.key }) {
        let tools = metadata[name] ?? []
        let lifecycle = state.config.mcpServers[name]?.lifecycle ?? "lazy"
        lines.append("  \(name): \(tools.count) tool(s), lifecycle: \(lifecycle)")
    }

    let totalTools = metadata.values.reduce(0) { $0 + $1.count }
    lines.append("")
    lines.append("Total: \(state.config.mcpServers.count) server(s), \(totalTools) tool(s)")
    return AgentToolResult(content: [.text(TextContent(text: lines.joined(separator: "\n")))])
}

// MARK: - Direct Tool Registration

private func registerDirectTool(_ pi: HookAPI, spec: DirectToolSpec, getState: @escaping @Sendable () async -> McpExtensionState?) {
    // Direct tools are integrated via the AgentTool mechanism at session creation time
    // This is a no-op in the HookAPI registration phase
}

// MARK: - Tool Building

func buildMcpProxyTool(getState: @escaping @Sendable () async -> McpExtensionState?, description: String) -> AgentTool {
    AgentTool(
        label: "MCP",
        name: "mcp",
        description: description,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "tool": ["type": "string", "description": "Tool name to call (e.g., 'xcodebuild_list_sims')"] as [String: Any],
                "args": ["type": "string", "description": "Arguments as JSON string (e.g., '{\"key\": \"value\"}')"] as [String: Any],
                "connect": ["type": "string", "description": "Server name to connect (lazy connect + metadata refresh)"] as [String: Any],
                "describe": ["type": "string", "description": "Tool name to describe (shows parameters)"] as [String: Any],
                "search": ["type": "string", "description": "Search tools by name/description"] as [String: Any],
                "regex": ["type": "boolean", "description": "Treat search as regex (default: substring match)"] as [String: Any],
                "includeSchemas": ["type": "boolean", "description": "Include parameter schemas in search results (default: true)"] as [String: Any],
                "server": ["type": "string", "description": "Filter to specific server (also disambiguates tool calls)"] as [String: Any],
            ] as [String: Any]),
        ]
    ) { _, params, _, _ in
        guard let state = await getState() else {
            return AgentToolResult(content: [.text(TextContent(text: "MCP not initialized. Servers may still be connecting."))])
        }
        return try await executeProxyTool(params: params, state: state)
    }
}

func buildDirectTools(getState: @escaping @Sendable () async -> McpExtensionState?, config: McpConfig, cache: MetadataCache?, prefix: String) -> [AgentTool] {
    let specs = resolveDirectTools(config: config, cache: cache, prefix: prefix)
    return specs.map { spec in
        let schema = spec.inputSchema ?? AnyCodable(["type": "object", "properties": [:] as [String: Any]] as [String: Any])
        return AgentTool(
            label: "MCP: \(spec.originalName)",
            name: spec.prefixedName,
            description: spec.description,
            parameters: schemaToParameters(schema)
        ) { _, params, _, _ in
            guard let state = await getState() else {
                return AgentToolResult(content: [.text(TextContent(text: "MCP not initialized"))])
            }

            guard let definition = state.config.mcpServers[spec.serverName] else {
                return AgentToolResult(content: [.text(TextContent(text: "Server \"\(spec.serverName)\" not found"))])
            }

            do {
                await state.manager.incrementInFlight(name: spec.serverName)
                defer { Task { await state.manager.decrementInFlight(name: spec.serverName) } }

                let isConnected = await state.manager.isConnected(name: spec.serverName)
                if !isConnected {
                    _ = try await state.manager.connect(name: spec.serverName, definition: definition)
                }
                await state.manager.touch(name: spec.serverName)

                if let resourceUri = spec.resourceUri {
                    guard let conn = await state.manager.getConnection(name: spec.serverName) else {
                        throw McpError.connectionFailed("Not connected")
                    }
                    let contents = try await conn.client.readResource(uri: resourceUri)
                    let mcpContent = contents.map { McpContent(type: "resource", resource: $0, uri: $0.uri) }
                    return AgentToolResult(content: transformMcpContent(mcpContent))
                }

                guard let conn = await state.manager.getConnection(name: spec.serverName) else {
                    throw McpError.connectionFailed("Not connected")
                }
                let result = try await conn.client.callTool(name: spec.originalName, arguments: params)
                return AgentToolResult(content: transformMcpContent(result.content))
            } catch {
                return AgentToolResult(content: [.text(TextContent(text: "Error: \(error)"))])
            }
        }
    }
}

// MARK: - Initialization

private func initializeMcp(configPath: String?) async throws -> McpExtensionState {
    let config = loadMcpConfig(overridePath: configPath)
    let prefix = config.settings?.toolPrefix ?? "server"

    let manager = McpServerManager()
    let lifecycle = McpLifecycleManager()
    await lifecycle.setManager(manager)

    let state = McpExtensionState(manager: manager, lifecycle: lifecycle, config: config, prefix: prefix)

    // Set global idle timeout
    let globalIdleMinutes = config.settings?.idleTimeout ?? 10
    await lifecycle.setGlobalIdleTimeout(minutes: globalIdleMinutes)

    // Load or bootstrap metadata cache
    let existingCache = loadMetadataCache()
    let isFirstRun = existingCache == nil

    // Register servers with lifecycle
    for (name, definition) in config.mcpServers {
        let idleTimeout = getEffectiveIdleTimeoutMinutes(name: name, definition: definition, config: config)
        await lifecycle.registerServer(name: name, definition: definition, idleTimeout: idleTimeout)

        // Reconstruct metadata from cache
        if let cache = existingCache, let entry = cache.servers[name], isServerCacheValid(entry, definition) {
            let tools = reconstructToolMetadata(serverName: name, entry: entry, prefix: prefix, exposeResources: definition.exposeResources)
            state.toolMetadata.withLock { $0[name] = tools }
        }
    }

    // Determine startup servers
    var startupServers: [String] = []
    for (name, definition) in config.mcpServers {
        let lifecycle = definition.lifecycle ?? "lazy"
        if lifecycle == "eager" || lifecycle == "keep-alive" || isFirstRun {
            startupServers.append(name)
        }
    }

    // Connect startup servers in parallel (max 10 concurrent)
    await withTaskGroup(of: Void.self) { group in
        var inFlight = 0
        for name in startupServers {
            if inFlight >= maxParallelConnections {
                await group.next()
                inFlight -= 1
            }
            group.addTask {
                guard let definition = config.mcpServers[name] else { return }
                do {
                    let conn = try await manager.connect(name: name, definition: definition)
                    updateToolMetadata(state: state, serverName: name, connection: conn, definition: definition)
                } catch {
                    fputs("[mcp] Failed to connect to \"\(name)\": \(error)\n", stderr)
                }
            }
            inFlight += 1
        }
    }

    // Set lifecycle callbacks
    await lifecycle.setCallbacks(
        onReconnect: { name in
            guard let definition = config.mcpServers[name] else { return }
            if let conn = await manager.getConnection(name: name) {
                updateToolMetadata(state: state, serverName: name, connection: conn, definition: definition)
            }
        },
        onIdleShutdown: { name in
            fputs("[mcp] Idle shutdown: \(name)\n", stderr)
        }
    )

    await lifecycle.startHealthChecks()

    return state
}

// MARK: - Helpers

private func findEarlyConfigPath() -> String? {
    // Check command line for --mcp-config
    let args = CommandLine.arguments
    for (i, arg) in args.enumerated() {
        if arg == "--mcp-config" && i + 1 < args.count {
            return args[i + 1]
        }
        if arg.hasPrefix("--mcp-config=") {
            return String(arg.dropFirst("--mcp-config=".count))
        }
    }
    // Check env
    return ProcessInfo.processInfo.environment["MCP_CONFIG"]
}

private func findToolByName(_ name: String, serverFilter: String?, state: McpExtensionState) -> (server: String, metadata: ToolMetadata)? {
    let allMetadata = state.toolMetadata.withLock { $0 }
    let normalized = name.replacingOccurrences(of: "-", with: "_")

    var candidates: [(String, ToolMetadata)] = []

    for (server, tools) in allMetadata {
        if let filter = serverFilter, server != filter { continue }
        for tool in tools {
            if tool.name == name || tool.originalName == name {
                candidates.append((server, tool))
            } else {
                let toolNormalized = tool.name.replacingOccurrences(of: "-", with: "_")
                let origNormalized = tool.originalName.replacingOccurrences(of: "-", with: "_")
                if toolNormalized == normalized || origNormalized == normalized {
                    candidates.append((server, tool))
                }
            }
        }
    }

    if candidates.count == 1 { return candidates[0] }
    if candidates.isEmpty { return nil }

    // Prefer exact match
    if let exact = candidates.first(where: { $0.1.name == name || $0.1.originalName == name }) {
        return exact
    }
    return candidates.first
}

private func updateToolMetadata(state: McpExtensionState, serverName: String, connection: ServerConnection, definition: ServerEntry) {
    let prefix = state.prefix
    var tools: [ToolMetadata] = []

    for tool in connection.tools {
        let prefixed = formatToolName(tool.name, serverName: serverName, prefix: prefix)
        tools.append(ToolMetadata(
            name: prefixed,
            originalName: tool.name,
            description: tool.description ?? "(no description)",
            inputSchema: tool.inputSchema
        ))
    }

    if definition.exposeResources == true {
        for resource in connection.resources {
            let toolName = resourceNameToToolName(resource.name)
            let prefixed = formatToolName(toolName, serverName: serverName, prefix: prefix)
            tools.append(ToolMetadata(
                name: prefixed,
                originalName: toolName,
                description: resource.description ?? "Read resource: \(resource.uri)",
                resourceUri: resource.uri
            ))
        }
    }

    state.toolMetadata.withLock { $0[serverName] = tools }

    // Update metadata cache
    let entry = buildCacheEntry(from: connection, definition: definition)
    var cache = MetadataCache()
    cache.servers[serverName] = entry
    saveMetadataCache(cache)
}

private func flushMetadataCache(_ state: McpExtensionState) {
    // Nothing extra needed - updateToolMetadata already saves incrementally
}

func resolveDirectTools(config: McpConfig, cache: MetadataCache?, prefix: String) -> [DirectToolSpec] {
    // Check env override
    let envRaw = ProcessInfo.processInfo.environment["MCP_DIRECT_TOOLS"]
    if envRaw == "__none__" { return [] }

    let envFilter: [String]? = envRaw?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    var specs: [DirectToolSpec] = []
    var usedNames: Set<String> = Set(builtinToolNames)

    for (serverName, definition) in config.mcpServers {
        let shouldExpose: Bool
        var specificTools: [String]? = nil

        if let envFilter {
            // Env override
            let serverTools = envFilter.filter { $0.hasPrefix("\(serverName)/") }.map { String($0.dropFirst(serverName.count + 1)) }
            let includeAll = envFilter.contains(serverName)
            if !serverTools.isEmpty {
                shouldExpose = true
                specificTools = serverTools
            } else {
                shouldExpose = includeAll
            }
        } else {
            switch definition.directTools {
            case .enabled(true):
                shouldExpose = true
            case .tools(let names):
                shouldExpose = true
                specificTools = names
            case .enabled(false):
                shouldExpose = false
            case nil:
                shouldExpose = config.settings?.directTools ?? false
            }
        }

        guard shouldExpose else { continue }
        guard let cache, let entry = cache.servers[serverName], isServerCacheValid(entry, definition) else { continue }

        let tools = entry.tools.filter { tool in
            if let specific = specificTools {
                return specific.contains(tool.name)
            }
            return true
        }

        for tool in tools {
            let prefixedName = formatToolName(tool.name, serverName: serverName, prefix: prefix)
            guard !usedNames.contains(prefixedName) else { continue }
            usedNames.insert(prefixedName)

            specs.append(DirectToolSpec(
                prefixedName: prefixedName,
                originalName: tool.name,
                serverName: serverName,
                description: tool.description ?? "(no description)",
                inputSchema: tool.inputSchema
            ))
        }

        if definition.exposeResources == true {
            for resource in entry.resources {
                let toolName = resourceNameToToolName(resource.name)
                let prefixedName = formatToolName(toolName, serverName: serverName, prefix: prefix)
                guard !usedNames.contains(prefixedName) else { continue }
                usedNames.insert(prefixedName)

                specs.append(DirectToolSpec(
                    prefixedName: prefixedName,
                    originalName: toolName,
                    serverName: serverName,
                    description: resource.description ?? "Read resource: \(resource.uri)",
                    resourceUri: resource.uri
                ))
            }
        }
    }

    return specs
}

private func buildProxyDescription(config: McpConfig, cache: MetadataCache?, directSpecs: [DirectToolSpec]) -> String {
    var parts: [String] = []
    parts.append("MCP tool proxy. Connects to MCP servers and calls their tools.")
    parts.append("")

    // Direct tools summary
    if !directSpecs.isEmpty {
        let byServer = Dictionary(grouping: directSpecs, by: { $0.serverName })
        for (server, tools) in byServer.sorted(by: { $0.key < $1.key }) {
            parts.append("Direct tools from \(server): \(tools.map { $0.prefixedName }.joined(separator: ", "))")
        }
        parts.append("")
    }

    // Proxy-accessible servers
    var proxyServers: [String] = []
    for (name, _) in config.mcpServers.sorted(by: { $0.key < $1.key }) {
        let toolCount = cache?.servers[name]?.tools.count ?? 0
        if toolCount > 0 {
            proxyServers.append("\(name) (\(toolCount) tools)")
        } else {
            proxyServers.append("\(name) (not cached)")
        }
    }
    if !proxyServers.isEmpty {
        parts.append("Servers: \(proxyServers.joined(separator: ", "))")
        parts.append("")
    }

    parts.append("Usage:")
    parts.append("  Search: mcp({ search: \"query\" })")
    parts.append("  Call: mcp({ tool: \"name\", args: \"{...}\" })")
    parts.append("  Connect: mcp({ connect: \"server\" })")
    parts.append("  Describe: mcp({ describe: \"name\" })")
    parts.append("  Status: mcp({})")

    return parts.joined(separator: "\n")
}

private func schemaToParameters(_ schema: AnyCodable) -> [String: AnyCodable] {
    if let dict = schema.value as? [String: Any] {
        return dict.mapValues { AnyCodable($0) }
    }
    return ["type": AnyCodable("object"), "properties": AnyCodable([:] as [String: Any])]
}

private func getEffectiveIdleTimeoutMinutes(name: String, definition: ServerEntry, config: McpConfig) -> Int? {
    if let perServer = definition.idleTimeout { return perServer }
    if definition.lifecycle == "eager" { return 0 }
    return config.settings?.idleTimeout
}

private func buildStatusText(_ state: McpExtensionState) async -> String {
    let result = executeStatus(state: state)
    if case .text(let content) = result.content.first {
        return content.text
    }
    return "MCP status unavailable"
}

private func buildAuthInstructions(serverName: String) -> String {
    let tokenDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/mcp-oauth/\(serverName)")
    return """
    OAuth setup for "\(serverName)":

    1. Obtain an access token from the MCP server's OAuth provider
    2. Create the token file:
       mkdir -p "\(tokenDir)"
       echo '{"access_token": "YOUR_TOKEN", "token_type": "bearer"}' > "\(tokenDir)/tokens.json"
    3. Restart the session or run mcp({ connect: "\(serverName)" })
    """
}

// MARK: - Lifecycle Manager callback setter

extension McpLifecycleManager {
    func setCallbacks(
        onReconnect: @escaping @Sendable (String) async -> Void,
        onIdleShutdown: @escaping @Sendable (String) async -> Void
    ) {
        self.onReconnect = onReconnect
        self.onIdleShutdown = onIdleShutdown
    }
}
