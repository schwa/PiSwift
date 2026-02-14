import Foundation
import PiSwiftAI

// MARK: - Transport

public enum McpTransportType: String, Codable, Sendable {
    case stdio
    case http
}

// MARK: - MCP Tool / Resource Definitions

public struct McpTool: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: AnyCodable?

    public init(name: String, title: String? = nil, description: String? = nil, inputSchema: AnyCodable? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct McpResource: Codable, Sendable {
    public var uri: String
    public var name: String
    public var description: String?
    public var mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

// MARK: - MCP Content Types (tool call responses)

public struct McpContent: Codable, Sendable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?
    public var resource: McpResourceContent?
    public var uri: String?
    public var name: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, resource: McpResourceContent? = nil, uri: String? = nil, name: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
        self.resource = resource
        self.uri = uri
        self.name = name
    }
}

public struct McpResourceContent: Codable, Sendable {
    public var uri: String
    public var text: String?
    public var blob: String?

    public init(uri: String, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.text = text
        self.blob = blob
    }
}

public struct McpToolResult: Sendable {
    public var content: [McpContent]
    public var isError: Bool

    public init(content: [McpContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

// MARK: - Server Configuration

public struct ServerEntry: Codable, Sendable {
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var cwd: String?
    public var url: String?
    public var headers: [String: String]?
    public var auth: String?
    public var bearerToken: String?
    public var bearerTokenEnv: String?
    public var lifecycle: String?
    public var idleTimeout: Int?
    public var exposeResources: Bool?
    public var directTools: DirectToolsConfig?
    public var debug: Bool?

    public init(
        command: String? = nil, args: [String]? = nil, env: [String: String]? = nil, cwd: String? = nil,
        url: String? = nil, headers: [String: String]? = nil, auth: String? = nil,
        bearerToken: String? = nil, bearerTokenEnv: String? = nil,
        lifecycle: String? = nil, idleTimeout: Int? = nil, exposeResources: Bool? = nil,
        directTools: DirectToolsConfig? = nil, debug: Bool? = nil
    ) {
        self.command = command; self.args = args; self.env = env; self.cwd = cwd
        self.url = url; self.headers = headers; self.auth = auth
        self.bearerToken = bearerToken; self.bearerTokenEnv = bearerTokenEnv
        self.lifecycle = lifecycle; self.idleTimeout = idleTimeout; self.exposeResources = exposeResources
        self.directTools = directTools; self.debug = debug
    }
}

public enum DirectToolsConfig: Codable, Sendable {
    case enabled(Bool)
    case tools([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .enabled(b)
        } else if let arr = try? container.decode([String].self) {
            self = .tools(arr)
        } else {
            throw DecodingError.typeMismatch(DirectToolsConfig.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected Bool or [String]"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled(let b): try container.encode(b)
        case .tools(let arr): try container.encode(arr)
        }
    }
}

public struct McpSettings: Codable, Sendable {
    public var toolPrefix: String?
    public var idleTimeout: Int?
    public var directTools: Bool?

    public init(toolPrefix: String? = nil, idleTimeout: Int? = nil, directTools: Bool? = nil) {
        self.toolPrefix = toolPrefix
        self.idleTimeout = idleTimeout
        self.directTools = directTools
    }
}

public struct McpConfig: Codable, Sendable {
    public var mcpServers: [String: ServerEntry]
    public var imports: [String]?
    public var settings: McpSettings?

    enum CodingKeys: String, CodingKey {
        case mcpServers
        case imports
        case settings
        // Accept hyphenated alternative
        case mcpServersHyphen = "mcp-servers"
    }

    public init(mcpServers: [String: ServerEntry] = [:], imports: [String]? = nil, settings: McpSettings? = nil) {
        self.mcpServers = mcpServers
        self.imports = imports
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let servers = try container.decodeIfPresent([String: ServerEntry].self, forKey: .mcpServers) {
            mcpServers = servers
        } else if let servers = try container.decodeIfPresent([String: ServerEntry].self, forKey: .mcpServersHyphen) {
            mcpServers = servers
        } else {
            mcpServers = [:]
        }
        imports = try container.decodeIfPresent([String].self, forKey: .imports)
        settings = try container.decodeIfPresent(McpSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encodeIfPresent(imports, forKey: .imports)
        try container.encodeIfPresent(settings, forKey: .settings)
    }
}

// MARK: - Tool Metadata

public struct ToolMetadata: Sendable {
    public var name: String
    public var originalName: String
    public var description: String
    public var resourceUri: String?
    public var inputSchema: AnyCodable?

    public init(name: String, originalName: String, description: String, resourceUri: String? = nil, inputSchema: AnyCodable? = nil) {
        self.name = name
        self.originalName = originalName
        self.description = description
        self.resourceUri = resourceUri
        self.inputSchema = inputSchema
    }
}

// MARK: - Server Provenance

public struct ServerProvenance: Sendable {
    public var source: String
    public var path: String

    public init(source: String, path: String) {
        self.source = source
        self.path = path
    }
}

// MARK: - Name Formatting

public func getServerPrefix(_ serverName: String, mode: String) -> String {
    if mode == "none" { return "" }
    if mode == "short" {
        var short = serverName
            .replacingOccurrences(of: #"-?mcp$"#, with: "", options: [.regularExpression, .caseInsensitive], range: serverName.startIndex..<serverName.endIndex)
            .replacingOccurrences(of: "-", with: "_")
        if short.isEmpty { short = "mcp" }
        return short
    }
    return serverName.replacingOccurrences(of: "-", with: "_")
}

public func formatToolName(_ toolName: String, serverName: String, prefix: String) -> String {
    let p = getServerPrefix(serverName, mode: prefix)
    return p.isEmpty ? toolName : "\(p)_\(toolName)"
}

public func resourceNameToToolName(_ name: String) -> String {
    var sanitized = name
        .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
        .lowercased()
    if let first = sanitized.first, first.isNumber {
        sanitized = "resource_\(sanitized)"
    }
    return "get_\(sanitized)"
}
