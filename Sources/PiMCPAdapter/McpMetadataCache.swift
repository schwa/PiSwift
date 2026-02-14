import Foundation
import CryptoKit
import PiSwiftAI

// MARK: - Cache Types

public struct MetadataCache: Codable, Sendable {
    public var version: Int = 1
    public var servers: [String: ServerCacheEntry]

    public init(version: Int = 1, servers: [String: ServerCacheEntry] = [:]) {
        self.version = version
        self.servers = servers
    }
}

public struct ServerCacheEntry: Codable, Sendable {
    public var configHash: String
    public var tools: [CachedTool]
    public var resources: [CachedResource]
    public var cachedAt: Double

    public init(configHash: String, tools: [CachedTool], resources: [CachedResource], cachedAt: Double) {
        self.configHash = configHash
        self.tools = tools
        self.resources = resources
        self.cachedAt = cachedAt
    }
}

public struct CachedTool: Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: AnyCodable?

    public init(name: String, description: String? = nil, inputSchema: AnyCodable? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct CachedResource: Codable, Sendable {
    public var uri: String
    public var name: String
    public var description: String?

    public init(uri: String, name: String, description: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
    }
}

// MARK: - Cache File Path

private let cacheFileName = "mcp-cache.json"

func metadataCachePath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent(cacheFileName)
}

// MARK: - Load / Save

public func loadMetadataCache() -> MetadataCache? {
    let path = metadataCachePath()
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    do {
        let cache = try JSONDecoder().decode(MetadataCache.self, from: data)
        return cache.version == 1 ? cache : nil
    } catch {
        return nil
    }
}

public func saveMetadataCache(_ cache: MetadataCache) {
    let path = metadataCachePath()
    let dir = (path as NSString).deletingLastPathComponent

    // Ensure directory exists
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Read-merge-write for multi-session safety
    var merged = loadMetadataCache() ?? MetadataCache()
    for (name, entry) in cache.servers {
        merged.servers[name] = entry
    }

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)

        // Atomic write via temp file + rename
        let pid = ProcessInfo.processInfo.processIdentifier
        let tempPath = "\(path).\(pid).tmp"
        try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)

        // rename (atomic on same filesystem)
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    } catch {
        // Try direct write as fallback
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

// MARK: - Config Hashing

public func computeServerHash(_ definition: ServerEntry) -> String {
    // Hash only identity-affecting fields
    var components: [String: Any] = [:]
    if let c = definition.command { components["command"] = c }
    if let a = definition.args { components["args"] = a }
    if let e = definition.env { components["env"] = e }
    if let c = definition.cwd { components["cwd"] = c }
    if let u = definition.url { components["url"] = u }
    if let h = definition.headers { components["headers"] = h }
    if let a = definition.auth { components["auth"] = a }
    if let b = definition.bearerToken { components["bearerToken"] = b }
    if let b = definition.bearerTokenEnv { components["bearerTokenEnv"] = b }
    if let e = definition.exposeResources { components["exposeResources"] = e }

    // Stable JSON with sorted keys
    guard let data = try? JSONSerialization.data(
        withJSONObject: components,
        options: [.sortedKeys, .fragmentsAllowed]
    ) else {
        return ""
    }

    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Cache Validity

private let maxCacheAgeSeconds: Double = 7 * 24 * 60 * 60 // 7 days

public func isServerCacheValid(_ entry: ServerCacheEntry, _ definition: ServerEntry) -> Bool {
    guard entry.configHash == computeServerHash(definition) else { return false }
    let age = Date().timeIntervalSince1970 * 1000 - entry.cachedAt
    return age < maxCacheAgeSeconds * 1000
}

// MARK: - Metadata Reconstruction

public func reconstructToolMetadata(
    serverName: String,
    entry: ServerCacheEntry,
    prefix: String,
    exposeResources: Bool?
) -> [ToolMetadata] {
    var metadata: [ToolMetadata] = []

    for tool in entry.tools {
        let prefixed = formatToolName(tool.name, serverName: serverName, prefix: prefix)
        metadata.append(ToolMetadata(
            name: prefixed,
            originalName: tool.name,
            description: tool.description ?? "(no description)",
            inputSchema: tool.inputSchema
        ))
    }

    if exposeResources == true {
        for resource in entry.resources {
            let toolName = resourceNameToToolName(resource.name)
            let prefixed = formatToolName(toolName, serverName: serverName, prefix: prefix)
            metadata.append(ToolMetadata(
                name: prefixed,
                originalName: toolName,
                description: resource.description ?? "Read resource: \(resource.uri)",
                resourceUri: resource.uri
            ))
        }
    }

    return metadata
}

// MARK: - Build Cache Entry from Connection

public func buildCacheEntry(from connection: ServerConnection, definition: ServerEntry) -> ServerCacheEntry {
    ServerCacheEntry(
        configHash: computeServerHash(definition),
        tools: connection.tools.map { CachedTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) },
        resources: connection.resources.map { CachedResource(uri: $0.uri, name: $0.name, description: $0.description) },
        cachedAt: Date().timeIntervalSince1970 * 1000
    )
}
