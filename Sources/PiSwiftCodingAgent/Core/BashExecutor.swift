import Foundation
import PiSwiftAI

public struct BashExecutorOptions: Sendable {
    public var onChunk: (@Sendable (String) -> Void)?
    public var signal: CancellationToken?
    public var timeoutSeconds: Double?

    public init(onChunk: (@Sendable (String) -> Void)? = nil, signal: CancellationToken? = nil, timeoutSeconds: Double? = nil) {
        self.onChunk = onChunk
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BashResult: Sendable {
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?

    public init(output: String, exitCode: Int?, cancelled: Bool, truncated: Bool, fullOutputPath: String? = nil) {
        self.output = output
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.truncated = truncated
        self.fullOutputPath = fullOutputPath
    }
}


#if canImport(UIKit)
public func executeBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    return BashResult(output: "Not available on iOS", exitCode: 1, cancelled: false, truncated: false)
}
#else
public func executeBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    let process = Process()
    let shellConfig = try getShellConfig()
    process.executableURL = URL(fileURLWithPath: shellConfig.shell)
    process.arguments = shellConfig.args + [command]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let buffer = OutputBuffer()

    let appendData: @Sendable (Data) -> Void = { data in
        buffer.append(data, onChunk: options?.onChunk)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        appendData(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        appendData(handle.availableData)
    }

    try process.run()

    let cancelledFlag = ManagedAtomic(false)

    let cancellationTimer = DispatchSource.makeTimerSource()
    cancellationTimer.schedule(deadline: .now(), repeating: .milliseconds(50))
    cancellationTimer.setEventHandler {
        if options?.signal?.isCancelled == true {
            cancelledFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            cancellationTimer.cancel()
        }
    }
    cancellationTimer.resume()

    var timeoutTimer: DispatchSourceTimer?
    if let timeoutSeconds = options?.timeoutSeconds, timeoutSeconds > 0 {
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            if process.isRunning {
                cancelledFlag.store(true)
                killProcessTree(process.processIdentifier)
            }
            timer.cancel()
        }
        timer.resume()
        timeoutTimer = timer
    }

    let timeoutTimerRef = timeoutTimer
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            buffer.append(stdoutRemainder, onChunk: nil)
            buffer.append(stderrRemainder, onChunk: nil)
            cancellationTimer.cancel()
            timeoutTimerRef?.cancel()

            let combinedData = buffer.snapshot()

            var output = String(decoding: combinedData, as: UTF8.self)
            output = sanitizeBinaryOutput(output.replacingOccurrences(of: "\r", with: ""))

            var fullOutputPath: String? = nil
            var truncated = false

            if combinedData.count > DEFAULT_MAX_BYTES {
                truncated = true
                let tempPath = FileManager.default.temporaryDirectory.appendingPathComponent("pi-bash-\(UUID().uuidString).log")
                try? combinedData.write(to: tempPath)
                fullOutputPath = tempPath.path
                let truncation = truncateTail(output)
                output = truncation.content
            }

            let cancelled = cancelledFlag.load() || proc.terminationStatus == 9

            continuation.resume(returning: BashResult(
                output: output.isEmpty ? "" : output,
                exitCode: cancelled ? nil : Int(proc.terminationStatus),
                cancelled: cancelled,
                truncated: truncated,
                fullOutputPath: fullOutputPath
            ))
        }
    }
}

private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool) {
        value = initial
    }

    func store(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data, onChunk: (@Sendable (String) -> Void)?) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
        if let text = String(data: chunk, encoding: .utf8) {
            let sanitized = sanitizeBinaryOutput(text.replacingOccurrences(of: "\r", with: ""))
            onChunk?(sanitized)
        }
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
#endif
