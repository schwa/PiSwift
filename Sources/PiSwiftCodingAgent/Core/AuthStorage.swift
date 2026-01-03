import Foundation

public struct ApiKeyCredential: Sendable {
    public var type: String = "api_key"
    public var key: String
}

public struct OAuthCredential: Sendable {
    public var type: String = "oauth"
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?
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
            } else if type == "oauth", let accessToken = dict["accessToken"] as? String {
                let refreshToken = dict["refreshToken"] as? String
                let expiresAt = dict["expiresAt"] as? Double
                loaded[provider] = .oauth(OAuthCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt))
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

    public func getAll() -> [String: AuthCredential] {
        data
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
                return oauth.accessToken
            }
        }

        let envKey = envKeyName(for: provider)
        if let envName = envKey, let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
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
                var entry: [String: Any] = ["type": "oauth", "accessToken": oauth.accessToken]
                if let refresh = oauth.refreshToken { entry["refreshToken"] = refresh }
                if let expires = oauth.expiresAt { entry["expiresAt"] = expires }
                json[provider] = entry
            }
        }

        let dir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: authPath))
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
