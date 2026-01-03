import Foundation

private let timingsEnabled: Bool = {
    ProcessInfo.processInfo.environment["PI_TIMING"] == "1"
}()

private final class TimingState: @unchecked Sendable {
    let lock = NSLock()
    var timings: [(label: String, ms: Double)] = []
    var lastTime: TimeInterval = Date().timeIntervalSince1970
}

private let timingState = TimingState()

public func time(_ label: String) {
    guard timingsEnabled else { return }
    let now = Date().timeIntervalSince1970
    timingState.lock.lock()
    let elapsed = (now - timingState.lastTime) * 1000.0
    timingState.timings.append((label: label, ms: elapsed))
    timingState.lastTime = now
    timingState.lock.unlock()
}

public func printTimings() {
    timingState.lock.lock()
    let entries = timingState.timings
    timingState.lock.unlock()
    guard timingsEnabled, !entries.isEmpty else { return }
    var output = "\n--- Startup Timings ---\n"
    var total: Double = 0
    for entry in entries {
        total += entry.ms
        output += "  \(entry.label): \(Int(entry.ms))ms\n"
    }
    output += "  TOTAL: \(Int(total))ms\n"
    output += "------------------------\n"

    if let data = output.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
