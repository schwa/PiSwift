import Foundation
import PiSwiftAI

public struct ExecOptions: Sendable {
    public var signal: CancellationToken?
    public var timeout: TimeInterval?
    public var cwd: String?

    public init(signal: CancellationToken? = nil, timeout: TimeInterval? = nil, cwd: String? = nil) {
        self.signal = signal
        self.timeout = timeout
        self.cwd = cwd
    }
}

public struct ExecResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int
    public var killed: Bool

    public init(stdout: String, stderr: String, code: Int, killed: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
        self.killed = killed
    }
}

#if !canImport(UIKit)
public func execCommand(_ command: String, _ args: [String], _ cwd: String, _ options: ExecOptions? = nil) async -> ExecResult {
    let process = Process()

    #if os(Windows)
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    #else
    if command.contains("/") || command.contains("\\") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }
    #endif

    let directory = options?.cwd ?? cwd
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutBuffer = OutputBuffer()
    let stderrBuffer = OutputBuffer()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdoutBuffer.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderrBuffer.append(handle.availableData)
    }

    let killedFlag = ManagedAtomic(false)
    let cancellationTimer = DispatchSource.makeTimerSource()
    cancellationTimer.schedule(deadline: .now(), repeating: .milliseconds(50))
    cancellationTimer.setEventHandler {
        if options?.signal?.isCancelled == true {
            killedFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            cancellationTimer.cancel()
        }
    }
    cancellationTimer.resume()

    var timeoutTimer: DispatchSourceTimer?
    if let timeout = options?.timeout, timeout > 0 {
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            killedFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            timer.cancel()
        }
        timer.resume()
        timeoutTimer = timer
    }

    do {
        try process.run()
    } catch {
        cancellationTimer.cancel()
        timeoutTimer?.cancel()
        return ExecResult(stdout: "", stderr: error.localizedDescription, code: 1, killed: true)
    }

    let timeoutTimerRef = timeoutTimer
    return await withCheckedContinuation { continuation in
        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutBuffer.append(stdoutRemainder)
            stderrBuffer.append(stderrRemainder)
            cancellationTimer.cancel()
            timeoutTimerRef?.cancel()

            let stdoutText = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
            let stderrText = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)

            let killed = killedFlag.load()
            let code = Int(proc.terminationStatus)

            continuation.resume(returning: ExecResult(stdout: stdoutText, stderr: stderrText, code: code, killed: killed))
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

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
#endif
