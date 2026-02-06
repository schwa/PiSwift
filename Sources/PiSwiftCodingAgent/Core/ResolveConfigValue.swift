import Foundation
import PiSwiftAI

private let commandResultCache = LockedState<[String: String?]>([:])

public func clearConfigValueCache() {
    commandResultCache.withLock { $0 = [:] }
}

public func resolveConfigValue(_ config: String) -> String? {
    if config.hasPrefix("!") {
        return executeCommand(config)
    }
    let envValue = ProcessInfo.processInfo.environment[config]
    if let envValue, !envValue.isEmpty {
        return envValue
    }
    return config
}

public func resolveHeaders(_ headers: [String: String]?) -> [String: String]? {
    guard let headers else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in headers {
        if let resolvedValue = resolveConfigValue(value), !resolvedValue.isEmpty {
            resolved[key] = resolvedValue
        }
    }
    return resolved.isEmpty ? nil : resolved
}

private func executeCommand(_ commandConfig: String) -> String? {
    if let cached = commandResultCache.withLock({ $0[commandConfig] }) {
        return cached
    }
    if commandResultCache.withLock({ $0.keys.contains(commandConfig) }) {
        return nil
    }

    let command = String(commandConfig.dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    var result: String? = nil
    do {
        try process.run()
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }
        if group.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            result = trimmed.isEmpty ? nil : trimmed
        }
    } catch {
        result = nil
    }

    commandResultCache.withLock { $0[commandConfig] = result }
    return result
}
