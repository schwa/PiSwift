import Foundation
import PiSwiftAI

// MARK: - MCP Protocol Client

public actor McpClient {
    private var transport: (any McpTransport)?
    private var nextId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, any Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var serverCapabilities: AnyCodable?
    private var serverInfo: AnyCodable?

    public init() {}

    // MARK: - Connection

    public func connect(transport: any McpTransport) async throws {
        self.transport = transport

        // Start receive loop
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Send initialize
        let initResult = try await sendRequest("initialize", params: AnyCodable([
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "pi",
                "version": "1.0.0",
            ] as [String: Any],
        ] as [String: Any]))

        if let resultDict = initResult?.value as? [String: Any] {
            serverCapabilities = AnyCodable(resultDict["capabilities"] ?? NSNull())
            serverInfo = AnyCodable(resultDict["serverInfo"] ?? NSNull())
        }

        // Send initialized notification
        let notification = JsonRpcNotification(method: "notifications/initialized")
        let data = try JsonRpc.encodeNotificationToLine(notification)
        try await transport.send(data)
    }

    // MARK: - MCP Operations

    public func listTools(cursor: String? = nil) async throws -> (tools: [McpTool], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("tools/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        let toolsArray = dict["tools"] as? [[String: Any]] ?? []
        let tools = toolsArray.compactMap { toolDict -> McpTool? in
            guard let name = toolDict["name"] as? String else { return nil }
            return McpTool(
                name: name,
                title: toolDict["title"] as? String,
                description: toolDict["description"] as? String,
                inputSchema: toolDict["inputSchema"].map { AnyCodable($0) }
            )
        }

        let nextCursor = dict["nextCursor"] as? String
        return (tools, nextCursor)
    }

    public func listAllTools() async throws -> [McpTool] {
        var all: [McpTool] = []
        var cursor: String? = nil
        repeat {
            let page = try await listTools(cursor: cursor)
            all.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func callTool(name: String, arguments: [String: AnyCodable] = [:]) async throws -> McpToolResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments.mapValues { $0.value },
        ]
        let result = try await sendRequest("tools/call", params: AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return McpToolResult(content: [McpContent(type: "text", text: "(empty response)")])
        }

        let isError = dict["isError"] as? Bool ?? false
        let contentArray = dict["content"] as? [[String: Any]] ?? []
        let content = contentArray.map { c -> McpContent in
            McpContent(
                type: c["type"] as? String ?? "text",
                text: c["text"] as? String,
                data: c["data"] as? String,
                mimeType: c["mimeType"] as? String,
                resource: parseResourceContent(c["resource"]),
                uri: c["uri"] as? String,
                name: c["name"] as? String
            )
        }
        return McpToolResult(content: content, isError: isError)
    }

    public func listResources(cursor: String? = nil) async throws -> (resources: [McpResource], nextCursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        let result = try await sendRequest("resources/list", params: params.isEmpty ? nil : AnyCodable(params))
        guard let dict = result?.value as? [String: Any] else {
            return ([], nil)
        }

        let resourcesArray = dict["resources"] as? [[String: Any]] ?? []
        let resources = resourcesArray.compactMap { rDict -> McpResource? in
            guard let uri = rDict["uri"] as? String, let name = rDict["name"] as? String else { return nil }
            return McpResource(
                uri: uri,
                name: name,
                description: rDict["description"] as? String,
                mimeType: rDict["mimeType"] as? String
            )
        }

        let nextCursor = dict["nextCursor"] as? String
        return (resources, nextCursor)
    }

    public func listAllResources() async throws -> [McpResource] {
        var all: [McpResource] = []
        var cursor: String? = nil
        repeat {
            let page = try await listResources(cursor: cursor)
            all.append(contentsOf: page.resources)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func readResource(uri: String) async throws -> [McpResourceContent] {
        let result = try await sendRequest("resources/read", params: AnyCodable(["uri": uri]))
        guard let dict = result?.value as? [String: Any],
              let contentsArray = dict["contents"] as? [[String: Any]] else {
            return []
        }
        return contentsArray.map { c in
            McpResourceContent(
                uri: c["uri"] as? String ?? uri,
                text: c["text"] as? String,
                blob: c["blob"] as? String
            )
        }
    }

    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        for (_, cont) in pendingRequests {
            cont.resume(throwing: McpError.transportClosed)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Internals

    private func sendRequest(_ method: String, params: AnyCodable?) async throws -> AnyCodable? {
        guard let transport else { throw McpError.transportClosed }

        let id = nextId
        nextId += 1

        let request = JsonRpcRequest(id: id, method: method, params: params)
        let data = try JsonRpc.encodeToLine(request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task {
                do {
                    try await transport.send(data)
                } catch {
                    if let cont = pendingRequests.removeValue(forKey: id) {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func receiveLoop() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let transport = await self.transport else { break }
                    let data = try await transport.receive()
                    await self.handleMessage(data)
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            let response = try JsonRpc.decodeResponse(data)
            guard let id = response.id else {
                // Notification from server - ignore for now
                return
            }
            guard let cont = pendingRequests.removeValue(forKey: id) else { return }

            if let error = response.error {
                cont.resume(throwing: McpError.rpcError(code: error.code, message: error.message))
            } else {
                cont.resume(returning: response.result)
            }
        } catch {
            // Could be a notification or malformed data - ignore
        }
    }

    private func parseResourceContent(_ value: Any?) -> McpResourceContent? {
        guard let dict = value as? [String: Any], let uri = dict["uri"] as? String else { return nil }
        return McpResourceContent(uri: uri, text: dict["text"] as? String, blob: dict["blob"] as? String)
    }
}
