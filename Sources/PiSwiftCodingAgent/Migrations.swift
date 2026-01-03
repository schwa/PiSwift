import Foundation

public struct MigrationResult: Sendable {
    public var migratedAuthProviders: [String]

    public init(migratedAuthProviders: [String]) {
        self.migratedAuthProviders = migratedAuthProviders
    }
}

public func runMigrations() -> MigrationResult {
    let migratedAuthProviders = migrateAuthToAuthJson()
    migrateSessionsFromAgentRoot()
    return MigrationResult(migratedAuthProviders: migratedAuthProviders)
}

public func migrateAuthToAuthJson() -> [String] {
    let agentDir = getAgentDir()
    let authPath = (agentDir as NSString).appendingPathComponent("auth.json")
    let oauthPath = (agentDir as NSString).appendingPathComponent("oauth.json")
    let settingsPath = (agentDir as NSString).appendingPathComponent("settings.json")

    if FileManager.default.fileExists(atPath: authPath) {
        return []
    }

    var migrated: [String: Any] = [:]
    var providers: [String] = []

    if FileManager.default.fileExists(atPath: oauthPath) {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: oauthPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (provider, cred) in json {
                var entry: [String: Any] = ["type": "oauth"]
                if let credDict = cred as? [String: Any] {
                    for (key, value) in credDict {
                        entry[key] = value
                    }
                }
                migrated[provider] = entry
                providers.append(provider)
            }
            let migratedPath = oauthPath + ".migrated"
            try? FileManager.default.moveItem(atPath: oauthPath, toPath: migratedPath)
        }
    }

    if FileManager.default.fileExists(atPath: settingsPath) {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let apiKeys = json["apiKeys"] as? [String: Any] {
                for (provider, key) in apiKeys {
                    guard migrated[provider] == nil, let keyString = key as? String else { continue }
                    migrated[provider] = ["type": "api_key", "key": keyString]
                    providers.append(provider)
                }
                json.removeValue(forKey: "apiKeys")
                if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                    try? updated.write(to: URL(fileURLWithPath: settingsPath))
                }
            }
        }
    }

    guard !migrated.isEmpty else { return providers }

    let authDir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: migrated, options: [.prettyPrinted]) {
        if !FileManager.default.createFile(atPath: authPath, contents: data, attributes: [.posixPermissions: 0o600]) {
            try? data.write(to: URL(fileURLWithPath: authPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
        }
    }

    return providers
}

public func migrateSessionsFromAgentRoot() {
    let agentDir = getAgentDir()
    let fileManager = FileManager.default

    guard let contents = try? fileManager.contentsOfDirectory(atPath: agentDir) else {
        return
    }

    let files = contents.filter { $0.hasSuffix(".jsonl") }.map { (agentDir as NSString).appendingPathComponent($0) }
    guard !files.isEmpty else { return }

    for file in files {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        guard let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }

        guard let headerData = String(firstLine).data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let type = header["type"] as? String, type == "session",
              let cwd = header["cwd"] as? String else {
            continue
        }

        let safePath = "--" + cwd
            .replacingOccurrences(of: "\\\\", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + "--"
        let correctDir = URL(fileURLWithPath: agentDir).appendingPathComponent("sessions").appendingPathComponent(safePath).path
        try? fileManager.createDirectory(atPath: correctDir, withIntermediateDirectories: true)

        let fileName = (file as NSString).lastPathComponent
        let newPath = (correctDir as NSString).appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: newPath) {
            continue
        }

        try? fileManager.moveItem(atPath: file, toPath: newPath)
    }
}
