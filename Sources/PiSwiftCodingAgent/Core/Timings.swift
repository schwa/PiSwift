import Foundation
import PiSwiftAI

private let timingsEnabled: Bool = {
    ProcessInfo.processInfo.environment["PI_TIMING"] == "1"
}()

private struct TimingState: Sendable {
    var timings: [(label: String, ms: Double)] = []
    var lastTime: TimeInterval = Date().timeIntervalSince1970
}

private let timingState = LockedState(TimingState())

public func time(_ label: String) {
    guard timingsEnabled else { return }
    let now = Date().timeIntervalSince1970
    timingState.withLock { state in
        let elapsed = (now - state.lastTime) * 1000.0
        state.timings.append((label: label, ms: elapsed))
        state.lastTime = now
    }
}

public func printTimings() {
    let entries = timingState.withLock { $0.timings }
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
