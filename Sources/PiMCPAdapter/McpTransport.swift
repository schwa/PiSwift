import Foundation
import PiSwiftAI

// MARK: - Transport Protocol

public protocol McpTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

// MARK: - Stdio Transport

public actor StdioTransport: McpTransport {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer: Data = Data()
    private var isClosed = false
    private var pendingReceive: CheckedContinuation<Data, any Error>?
    private var receivedChunks: [Data] = []
    private let chunkStore = ChunkStore()

    private let command: String
    private let args: [String]
    private let env: [String: String]?
    private let cwd: String?
    private let debug: Bool

    public init(command: String, args: [String] = [], env: [String: String]? = nil, cwd: String? = nil, debug: Bool = false) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.debug = debug
    }

    public func start() throws {
        let proc = Process()

        if command.contains("/") {
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [command] + args
        }

        if let cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (k, v) in env { environment[k] = v }
        }
        proc.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let store = self.chunkStore
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                store.enqueue(nil) // EOF signal
            } else {
                store.enqueue(data)
            }
        }

        if debug {
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    fputs("[mcp-stdio-stderr] \(text)", Foundation.stderr)
                }
            }
        } else {
            stderr.fileHandleForReading.readabilityHandler = { _ in }
        }

        proc.terminationHandler = { _ in
            store.enqueue(nil) // EOF
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
    }

    public func send(_ data: Data) async throws {
        guard !isClosed, let pipe = stdinPipe else {
            throw McpError.transportClosed
        }
        pipe.fileHandleForWriting.write(data)
    }

    public func receive() async throws -> Data {
        while true {
            // Check buffer for complete line
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                if lineData.isEmpty { continue }
                return Data(lineData)
            }

            // Wait for more data
            guard !isClosed else { throw McpError.transportClosed }
            guard let chunk = await chunkStore.dequeue() else {
                throw McpError.transportClosed
            }
            buffer.append(chunk)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        chunkStore.enqueue(nil)
        stdinPipe?.fileHandleForWriting.closeFile()
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
    }
}

// Thread-safe chunk queue for bridging readabilityHandler → async receive
private final class ChunkStore: Sendable {
    private let state = LockedState(ChunkState())

    struct ChunkState: Sendable {
        var chunks: [Data] = []
        var eof = false
        var waiters: [CheckedContinuation<Data?, Never>] = []
    }

    func enqueue(_ data: Data?) {
        state.withLock { s in
            if let data {
                if let waiter = s.waiters.first {
                    s.waiters.removeFirst()
                    waiter.resume(returning: data)
                } else {
                    s.chunks.append(data)
                }
            } else {
                s.eof = true
                for waiter in s.waiters {
                    waiter.resume(returning: nil)
                }
                s.waiters.removeAll()
            }
        }
    }

    func dequeue() async -> Data? {
        let immediate: Data? = state.withLock { s in
            if !s.chunks.isEmpty {
                return s.chunks.removeFirst()
            }
            if s.eof { return nil }
            return nil
        }

        if immediate != nil { return immediate }
        if state.withLock({ $0.eof }) { return nil }

        return await withCheckedContinuation { continuation in
            state.withLock { s in
                if !s.chunks.isEmpty {
                    let chunk = s.chunks.removeFirst()
                    continuation.resume(returning: chunk)
                } else if s.eof {
                    continuation.resume(returning: nil)
                } else {
                    s.waiters.append(continuation)
                }
            }
        }
    }
}

// MARK: - HTTP Transport (Streamable HTTP / SSE fallback)

public actor HttpTransport: McpTransport {
    private let url: URL
    private let headers: [String: String]
    private let debug: Bool
    private var sessionUrl: URL?
    private var isClosed = false
    private var pendingResponses: [CheckedContinuation<Data, any Error>] = []
    private var receivedMessages: [Data] = []
    private var sseTask: Task<Void, Never>?

    public init(url: URL, headers: [String: String] = [:], debug: Bool = false) {
        self.url = url
        self.headers = headers
        self.debug = debug
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw McpError.transportClosed }

        var request = URLRequest(url: sessionUrl ?? url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw McpError.protocolError("Non-HTTP response")
        }

        if httpResponse.statusCode == 202 {
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw McpError.protocolError("HTTP \(httpResponse.statusCode): \(body)")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            parseSSEData(responseData)
        } else {
            enqueueMessage(responseData)
        }
    }

    public func receive() async throws -> Data {
        guard !isClosed else { throw McpError.transportClosed }
        if !receivedMessages.isEmpty {
            return receivedMessages.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses.append(continuation)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        sseTask?.cancel()
        for cont in pendingResponses {
            cont.resume(throwing: McpError.transportClosed)
        }
        pendingResponses.removeAll()
    }

    private func enqueueMessage(_ data: Data) {
        if let cont = pendingResponses.first {
            pendingResponses.removeFirst()
            cont.resume(returning: data)
        } else {
            receivedMessages.append(data)
        }
    }

    private func parseSSEData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var eventData = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("data: ") {
                eventData += String(line.dropFirst(6))
            } else if line.isEmpty && !eventData.isEmpty {
                if let msgData = eventData.data(using: .utf8) {
                    enqueueMessage(msgData)
                }
                eventData = ""
            }
        }
        if !eventData.isEmpty, let msgData = eventData.data(using: .utf8) {
            enqueueMessage(msgData)
        }
    }
}
