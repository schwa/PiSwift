import Foundation
import Darwin
import PiSwiftAI

public struct ApiKeyCredential: Sendable {
    public var type: String = "api_key"
    public var key: String
}

public struct OAuthCredential: Sendable {
    public var type: String = "oauth"
    public var access: String
    public var refresh: String?
    public var expires: Double?
    public var enterpriseUrl: String?
    public var projectId: String?
    public var email: String?
    public var accountId: String?

    public init(
        access: String,
        refresh: String?,
        expires: Double?,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
    }
}

public enum AuthCredential: Sendable {
    case apiKey(ApiKeyCredential)
    case oauth(OAuthCredential)
}

public final class AuthStorage: @unchecked Sendable {
    private var data: [String: AuthCredential] = [:]
    private var runtimeOverrides: [String: String] = [:]
    private var fallbackResolver: ((String) -> String?)?
    private let authPath: String

    public init(_ authPath: String) {
        self.authPath = authPath
        reload()
    }

    public func setRuntimeApiKey(_ provider: String, _ apiKey: String) {
        runtimeOverrides[provider] = apiKey
    }

    public func removeRuntimeApiKey(_ provider: String) {
        runtimeOverrides.removeValue(forKey: provider)
    }

    public func setFallbackResolver(_ resolver: @escaping (String) -> String?) {
        fallbackResolver = resolver
    }

    public func reload() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.data = [:]
            return
        }

        var loaded: [String: AuthCredential] = [:]
        for (provider, value) in json {
            guard let dict = value as? [String: Any],
                  let type = dict["type"] as? String else { continue }
            if type == "api_key", let key = dict["key"] as? String {
                loaded[provider] = .apiKey(ApiKeyCredential(key: key))
            } else if type == "oauth" {
                let access = (dict["access"] as? String) ?? (dict["accessToken"] as? String)
                guard let access else { continue }
                let refresh = (dict["refresh"] as? String) ?? (dict["refreshToken"] as? String)
                let expires = (dict["expires"] as? Double) ?? (dict["expiresAt"] as? Double)
                let enterpriseUrl = dict["enterpriseUrl"] as? String
                let projectId = dict["projectId"] as? String
                let email = dict["email"] as? String
                let accountId = dict["accountId"] as? String
                loaded[provider] = .oauth(OAuthCredential(
                    access: access,
                    refresh: refresh,
                    expires: expires,
                    enterpriseUrl: enterpriseUrl,
                    projectId: projectId,
                    email: email,
                    accountId: accountId
                ))
            }
        }
        self.data = loaded
    }

    public func get(_ provider: String) -> AuthCredential? {
        data[provider]
    }

    public func set(_ provider: String, credential: AuthCredential) {
        data[provider] = credential
        save()
    }

    public func remove(_ provider: String) {
        data.removeValue(forKey: provider)
        save()
    }

    public func list() -> [String] {
        Array(data.keys)
    }

    public func has(_ provider: String) -> Bool {
        data[provider] != nil
    }

    public func hasAuth(_ provider: String) -> Bool {
        if runtimeOverrides[provider] != nil {
            return true
        }
        if data[provider] != nil {
            return true
        }
        if getEnvApiKey(provider: provider) != nil {
            return true
        }
        if fallbackResolver?(provider) != nil {
            return true
        }
        return false
    }

    public func getAll() -> [String: AuthCredential] {
        data
    }

    public func login(_ provider: OAuthProvider, callbacks: OAuthLoginCallbacks) async throws {
        let credentials: OAuthCredentials
        switch provider {
        case .anthropic:
            credentials = try await loginAnthropic(callbacks)
        case .openAICodex:
            credentials = try await loginOpenAICodex(callbacks)
        case .githubCopilot, .googleGeminiCli, .googleAntigravity:
            throw OAuthError.notImplemented(provider.rawValue)
        }
        set(provider.rawValue, credential: .oauth(OAuthCredential(credentials)))
    }

    public func logout(_ provider: OAuthProvider) {
        remove(provider.rawValue)
    }

    public func getApiKey(_ provider: String) async -> String? {
        if let runtime = runtimeOverrides[provider] {
            return runtime
        }
        if let credential = data[provider] {
            switch credential {
            case .apiKey(let apiKey):
                return apiKey.key
            case .oauth(let oauth):
                let now = Date().timeIntervalSince1970 * 1000
                let needsRefresh = oauth.expires == nil || now >= (oauth.expires ?? 0)
                if needsRefresh,
                   let providerId = OAuthProvider(rawValue: provider),
                   oauth.refresh != nil {
                    do {
                        if let result = try await refreshOAuthTokenWithLock(providerId) {
                            return result.apiKey
                        }
                    } catch {
                        let message = error.localizedDescription
                        fputs("OAuth token refresh failed for \(provider): \(message)\n", stderr)
                    }
                }

                if let providerId = OAuthProvider(rawValue: provider) {
                    if let apiKey = try? oauthApiKey(provider: providerId, accessToken: oauth.access, projectId: oauth.projectId) {
                        return apiKey
                    }
                }
                return oauth.access
            }
        }

        if let envKey = getEnvApiKey(provider: provider) {
            return envKey
        }

        if let envName = envKeyName(for: provider),
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return value
        }

        return fallbackResolver?(provider)
    }

    private func save() {
        var json: [String: Any] = [:]
        for (provider, credential) in data {
            switch credential {
            case .apiKey(let apiKey):
                json[provider] = ["type": "api_key", "key": apiKey.key]
            case .oauth(let oauth):
                var entry: [String: Any] = ["type": "oauth", "access": oauth.access]
                if let refresh = oauth.refresh { entry["refresh"] = refresh }
                if let expires = oauth.expires { entry["expires"] = expires }
                if let enterpriseUrl = oauth.enterpriseUrl { entry["enterpriseUrl"] = enterpriseUrl }
                if let projectId = oauth.projectId { entry["projectId"] = projectId }
                if let email = oauth.email { entry["email"] = email }
                if let accountId = oauth.accountId { entry["accountId"] = accountId }
                json[provider] = entry
            }
        }

        let dir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: authPath))
            chmod(authPath, 0o600)
        }
    }

    private func refreshOAuthTokenWithLock(_ provider: OAuthProvider) async throws -> (apiKey: String, newCredentials: OAuthCredentials)? {
        try await withAuthLock {
            self.reload()

            guard case .oauth(let oauth) = self.data[provider.rawValue] else {
                return nil
            }

            let now = Date().timeIntervalSince1970 * 1000
            if let expires = oauth.expires, now < expires {
                let apiKey = try oauthApiKey(provider: provider, accessToken: oauth.access, projectId: oauth.projectId)
                if let creds = oauth.toOAuthCredentials() {
                    return (apiKey: apiKey, newCredentials: creds)
                }
                return (apiKey: apiKey, newCredentials: OAuthCredentials(
                    refresh: oauth.refresh ?? "",
                    access: oauth.access,
                    expires: expires,
                    enterpriseUrl: oauth.enterpriseUrl,
                    projectId: oauth.projectId,
                    email: oauth.email,
                    accountId: oauth.accountId
                ))
            }

            let oauthCreds = self.oauthCredentialsMap()
            let result = try await getOAuthApiKey(provider: provider, credentials: oauthCreds)
            if let result {
                self.data[provider.rawValue] = .oauth(OAuthCredential(result.newCredentials))
                self.save()
                return (apiKey: result.apiKey, newCredentials: result.newCredentials)
            }

            return nil
        }
    }

    private func oauthCredentialsMap() -> [String: OAuthCredentials] {
        var creds: [String: OAuthCredentials] = [:]
        for (provider, credential) in data {
            guard case .oauth(let oauth) = credential,
                  let refresh = oauth.refresh else { continue }
            let expires = oauth.expires ?? 0
            creds[provider] = OAuthCredentials(
                refresh: refresh,
                access: oauth.access,
                expires: expires,
                enterpriseUrl: oauth.enterpriseUrl,
                projectId: oauth.projectId,
                email: oauth.email,
                accountId: oauth.accountId
            )
        }
        return creds
    }

    private func withAuthLock<T>(_ body: @escaping () async throws -> T) async throws -> T {
        ensureAuthFileExists()

        let fd = open(authPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OAuthError.refreshFailed("failed to open auth.json")
        }
        defer { close(fd) }

        var delayMs = 100
        var locked = false
        for _ in 0..<10 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            delayMs = min(delayMs * 2, 10_000)
        }

        guard locked else {
            throw OAuthError.refreshFailed("failed to acquire auth.json lock")
        }

        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private func ensureAuthFileExists() {
        let dir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if !FileManager.default.fileExists(atPath: authPath) {
            let empty = Data("{}".utf8)
            FileManager.default.createFile(atPath: authPath, contents: empty, attributes: [.posixPermissions: 0o600])
        }
    }

    private func envKeyName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "anthropic":
            return "ANTHROPIC_API_KEY"
        case "openai":
            return "OPENAI_API_KEY"
        case "google", "google-gemini-cli", "google-antigravity":
            return "GEMINI_API_KEY"
        case "openrouter":
            return "OPENROUTER_API_KEY"
        case "groq":
            return "GROQ_API_KEY"
        case "cerebras":
            return "CEREBRAS_API_KEY"
        case "xai":
            return "XAI_API_KEY"
        case "zai":
            return "ZAI_API_KEY"
        default:
            return nil
        }
    }
}

private extension OAuthCredential {
    init(_ credentials: OAuthCredentials) {
        self.init(
            access: credentials.access,
            refresh: credentials.refresh,
            expires: credentials.expires,
            enterpriseUrl: credentials.enterpriseUrl,
            projectId: credentials.projectId,
            email: credentials.email,
            accountId: credentials.accountId
        )
    }

    func toOAuthCredentials() -> OAuthCredentials? {
        guard let refresh else { return nil }
        let expiry = expires ?? 0
        return OAuthCredentials(
            refresh: refresh,
            access: access,
            expires: expiry,
            enterpriseUrl: enterpriseUrl,
            projectId: projectId,
            email: email,
            accountId: accountId
        )
    }
}
