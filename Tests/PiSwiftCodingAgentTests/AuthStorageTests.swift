import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func makeTempDir(_ prefix: String) -> String {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    return tempDir
}

private func writeAuthJson(_ path: String, data: [String: Any]) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload = (try? JSONSerialization.data(withJSONObject: data, options: [])) ?? Data()
    try? payload.write(to: url)
}

@Test func authStorageLiteralApiKeyReturned() async {
    let tempDir = makeTempDir("auth-storage-literal")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "sk-ant-literal-key"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "sk-ant-literal-key")
}

@Test func authStorageCommandApiKeyUsesStdout() async {
    let tempDir = makeTempDir("auth-storage-command")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo test-api-key-from-command"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "test-api-key-from-command")
}

@Test func authStorageCommandApiKeyTrimsWhitespace() async {
    let tempDir = makeTempDir("auth-storage-trim")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo '  spaced-key  '"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "spaced-key")
}

@Test func authStorageCommandApiKeyHandlesMultilineOutput() async {
    let tempDir = makeTempDir("auth-storage-multiline")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!printf 'line1\\nline2'"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "line1\nline2")
}

@Test func authStorageCommandApiKeyFailureReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-fail")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!exit 1"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageCommandApiKeyNonexistentCommandReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-missing")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!nonexistent-command-12345"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageCommandApiKeyEmptyOutputReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-empty")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!printf ''"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageEnvVarNameResolves() async {
    let tempDir = makeTempDir("auth-storage-env")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let envName = "TEST_AUTH_API_KEY_12345"
    let previous = ProcessInfo.processInfo.environment[envName]
    setenv(envName, "env-api-key-value", 1)
    defer {
        if let previous {
            setenv(envName, previous, 1)
        } else {
            unsetenv(envName)
        }
    }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": envName]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "env-api-key-value")
}

@Test func authStorageLiteralValueUsedWhenNotEnv() async {
    let tempDir = makeTempDir("auth-storage-literal-env")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    unsetenv("literal_api_key_value")

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "literal_api_key_value"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "literal_api_key_value")
}

@Test func authStorageCommandApiKeySupportsPipes() async {
    let tempDir = makeTempDir("auth-storage-pipes")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo 'hello world' | tr ' ' '-'"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "hello-world")
}

@Test func authStorageCommandCachingExecutesOnce() async {
    let tempDir = makeTempDir("auth-storage-cache")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); echo key-value'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage = AuthStorage(authPath)
    _ = await storage.getApiKey("anthropic")
    _ = await storage.getApiKey("anthropic")
    _ = await storage.getApiKey("anthropic")

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    #expect(count == 1)
}

@Test func authStorageCommandCachingPersistsAcrossInstances() async {
    let tempDir = makeTempDir("auth-storage-cache-instances")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); echo key-value'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage1 = AuthStorage(authPath)
    _ = await storage1.getApiKey("anthropic")

    let storage2 = AuthStorage(authPath)
    _ = await storage2.getApiKey("anthropic")

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    #expect(count == 1)
}

@Test func authStorageClearCacheAllowsCommandToRunAgain() async {
    let tempDir = makeTempDir("auth-storage-clear-cache")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); echo key-value'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage = AuthStorage(authPath)
    _ = await storage.getApiKey("anthropic")
    clearConfigValueCache()
    _ = await storage.getApiKey("anthropic")

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    #expect(count == 2)
}

@Test func authStorageCachesDifferentCommandsSeparately() async {
    let tempDir = makeTempDir("auth-storage-cache-separate")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "!echo key-anthropic"],
        "openai": ["type": "api_key", "key": "!echo key-openai"],
    ])

    let storage = AuthStorage(authPath)
    let keyA = await storage.getApiKey("anthropic")
    let keyB = await storage.getApiKey("openai")

    #expect(keyA == "key-anthropic")
    #expect(keyB == "key-openai")
}

@Test func authStorageFailedCommandsAreCached() async {
    let tempDir = makeTempDir("auth-storage-cache-fail")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); exit 1'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage = AuthStorage(authPath)
    let key1 = await storage.getApiKey("anthropic")
    let key2 = await storage.getApiKey("anthropic")

    #expect(key1 == nil)
    #expect(key2 == nil)

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    #expect(count == 1)
}

@Test func authStorageEnvVarsNotCached() async {
    let tempDir = makeTempDir("auth-storage-env-cache")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let envVarName = "TEST_AUTH_KEY_CACHE_TEST_98765"
    let previous = ProcessInfo.processInfo.environment[envVarName]
    defer {
        if let previous {
            setenv(envVarName, previous, 1)
        } else {
            unsetenv(envVarName)
        }
    }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": envVarName]])

    setenv(envVarName, "first-value", 1)
    let storage = AuthStorage(authPath)
    let key1 = await storage.getApiKey("anthropic")
    #expect(key1 == "first-value")

    setenv(envVarName, "second-value", 1)
    let key2 = await storage.getApiKey("anthropic")
    #expect(key2 == "second-value")
}

@Test func authStorageOAuthLockFailureAllowsLaterRetry() async {
    let tempDir = makeTempDir("auth-storage-oauth-lock")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": [
            "type": "oauth",
            "refresh": "refresh-token",
            "access": "expired-access-token",
            "expires": Double(now - 10_000),
        ],
    ])

    let storage = AuthStorage(authPath)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { _, _ in
            let creds = OAuthCredentials(
                refresh: "refresh-token",
                access: "refreshed-access-token",
                expires: Double(now + 60_000)
            )
            return (newCredentials: creds, apiKey: "Bearer refreshed-access-token")
        },
        oauthApiKey: nil
    ))

    storage.setAuthLockOptionsForTesting(AuthLockOptions(maxAttempts: 0, initialDelayMs: 1, maxDelayMs: 1))
    let firstTry = await storage.getApiKey("anthropic")
    #expect(firstTry == nil)

    storage.setAuthLockOptionsForTesting(nil)
    let secondTry = await storage.getApiKey("anthropic")
    #expect(secondTry == "Bearer refreshed-access-token")
}

@Test func authStorageRuntimeOverrideTakesPriority() async {
    let tempDir = makeTempDir("auth-storage-runtime")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo stored-key"]])

    let storage = AuthStorage(authPath)
    storage.setRuntimeApiKey("anthropic", "runtime-key")
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "runtime-key")
}

@Test func authStorageRuntimeOverrideRemovalFallsBack() async {
    let tempDir = makeTempDir("auth-storage-runtime-fallback")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    defer { clearConfigValueCache() }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo stored-key"]])

    let storage = AuthStorage(authPath)
    storage.setRuntimeApiKey("anthropic", "runtime-key")
    storage.removeRuntimeApiKey("anthropic")
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "stored-key")
}
