import Foundation
import PiSwiftAI

// MARK: - Server Connection

public struct ServerConnection: Sendable {
    public var client: McpClient
    public var tools: [McpTool]
    public var resources: [McpResource]
    public var lastUsedAt: Date
    public var inFlight: Int
    public var status: ConnectionStatus

    public enum ConnectionStatus: String, Sendable {
        case connected
        case connecting
        case disconnected
        case error
    }

    public init(client: McpClient, tools: [McpTool] = [], resources: [McpResource] = [], lastUsedAt: Date = Date(), inFlight: Int = 0, status: ConnectionStatus = .connected) {
        self.client = client
        self.tools = tools
        self.resources = resources
        self.lastUsedAt = lastUsedAt
        self.inFlight = inFlight
        self.status = status
    }
}

// MARK: - Server Manager

public actor McpServerManager {
    private var connections: [String: ServerConnection] = [:]
    private var npxCache: NpxCache?

    public init() {}

    public func connect(name: String, definition: ServerEntry) async throws -> ServerConnection {
        if let existing = connections[name], existing.status == .connected {
            return existing
        }

        connections[name] = ServerConnection(
            client: McpClient(),
            status: .connecting
        )

        do {
            let transport = try await createTransport(name: name, definition: definition)
            let client = McpClient()

            if let stdioTransport = transport as? StdioTransport {
                try await stdioTransport.start()
            }

            try await client.connect(transport: transport)

            let tools = try await client.listAllTools()
            let resources: [McpResource]
            if definition.exposeResources == true {
                resources = try await client.listAllResources()
            } else {
                resources = []
            }

            let conn = ServerConnection(
                client: client,
                tools: tools,
                resources: resources,
                lastUsedAt: Date(),
                status: .connected
            )
            connections[name] = conn
            return conn
        } catch {
            connections[name] = ServerConnection(client: McpClient(), status: .error)
            throw error
        }
    }

    public func close(name: String) async {
        guard let conn = connections[name] else { return }
        await conn.client.close()
        connections.removeValue(forKey: name)
    }

    public func closeAll() async {
        for (_, conn) in connections {
            await conn.client.close()
        }
        connections.removeAll()
    }

    public func getConnection(name: String) -> ServerConnection? {
        connections[name]
    }

    public func touch(name: String) {
        connections[name]?.lastUsedAt = Date()
    }

    public func incrementInFlight(name: String) {
        connections[name]?.inFlight += 1
        connections[name]?.lastUsedAt = Date()
    }

    public func decrementInFlight(name: String) {
        if let current = connections[name]?.inFlight, current > 0 {
            connections[name]?.inFlight = current - 1
        }
    }

    public func isIdle(name: String, timeoutMs: Int) -> Bool {
        guard let conn = connections[name],
              conn.status == .connected,
              conn.inFlight == 0 else {
            return false
        }
        let elapsed = Date().timeIntervalSince(conn.lastUsedAt) * 1000
        return elapsed > Double(timeoutMs)
    }

    public func isConnected(name: String) -> Bool {
        connections[name]?.status == .connected
    }

    public func allConnectionNames() -> [String] {
        Array(connections.keys)
    }

    // MARK: - Transport Creation

    private func createTransport(name: String, definition: ServerEntry) async throws -> any McpTransport {
        if let url = definition.url {
            guard let parsedUrl = URL(string: url) else {
                throw McpError.connectionFailed("Invalid URL: \(url)")
            }
            var headers = resolveHeaders(definition.headers)
            try applyAuth(name: name, definition: definition, headers: &headers)
            return HttpTransport(url: parsedUrl, headers: headers, debug: definition.debug ?? false)
        }

        guard let command = definition.command else {
            throw McpError.connectionFailed("Server \"\(name)\" has no command or url")
        }

        var resolvedCommand = command
        var resolvedArgs = definition.args ?? []

        // npx resolver optimization
        let lowerCommand = command.lowercased()
        if lowerCommand == "npx" || lowerCommand.hasSuffix("/npx") ||
           lowerCommand == "npm" || lowerCommand.hasSuffix("/npm") {
            if let resolution = await resolveNpxBinary(command: command, args: resolvedArgs) {
                if resolution.isJs {
                    resolvedCommand = "node"
                    resolvedArgs = [resolution.binPath] + resolution.extraArgs
                } else {
                    resolvedCommand = resolution.binPath
                    resolvedArgs = resolution.extraArgs
                }
            }
        }

        let env = resolveEnv(definition.env)
        return StdioTransport(
            command: resolvedCommand,
            args: resolvedArgs,
            env: env,
            cwd: definition.cwd,
            debug: definition.debug ?? false
        )
    }

    private func applyAuth(name: String, definition: ServerEntry, headers: inout [String: String]) throws {
        if definition.auth == "bearer" {
            let token = definition.bearerToken
                ?? definition.bearerTokenEnv.flatMap { ProcessInfo.processInfo.environment[$0] }
            if let token {
                headers["Authorization"] = "Bearer \(token)"
            }
        } else if definition.auth == "oauth" {
            guard let tokens = getStoredTokens(serverName: name) else {
                throw McpError.connectionFailed("No OAuth tokens for \"\(name)\". Run /mcp-auth \(name) to authenticate.")
            }
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
        }
    }
}

// MARK: - Environment / Header Interpolation

func resolveEnv(_ env: [String: String]?) -> [String: String]? {
    guard let env else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in env {
        resolved[key] = interpolateEnvVars(value)
    }
    return resolved
}

func resolveHeaders(_ headers: [String: String]?) -> [String: String] {
    guard let headers else { return [:] }
    var resolved: [String: String] = [:]
    for (key, value) in headers {
        resolved[key] = interpolateEnvVars(value)
    }
    return resolved
}

private func interpolateEnvVars(_ value: String) -> String {
    var result = value
    // Handle ${VAR} pattern
    let dollarBrace = try? NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
    if let matches = dollarBrace?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let varName = String(result[varRange])
            let envValue = ProcessInfo.processInfo.environment[varName] ?? ""
            result.replaceSubrange(fullRange, with: envValue)
        }
    }
    // Handle $env:VAR pattern
    let envColon = try? NSRegularExpression(pattern: #"\$env:([A-Za-z_][A-Za-z0-9_]*)"#)
    if let matches = envColon?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let varName = String(result[varRange])
            let envValue = ProcessInfo.processInfo.environment[varName] ?? ""
            result.replaceSubrange(fullRange, with: envValue)
        }
    }
    return result
}
