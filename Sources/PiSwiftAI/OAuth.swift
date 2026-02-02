import Foundation
import Dispatch
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif

public struct OAuthCredentials: Sendable, Codable {
    public var refresh: String
    public var access: String
    public var expires: Double
    public var enterpriseUrl: String?
    public var projectId: String?
    public var email: String?
    public var accountId: String?

    public init(
        refresh: String,
        access: String,
        expires: Double,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil
    ) {
        self.refresh = refresh
        self.access = access
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
    }
}

public enum OAuthProvider: String, Sendable, CaseIterable {
    case anthropic = "anthropic"
    case githubCopilot = "github-copilot"
    case googleGeminiCli = "google-gemini-cli"
    case googleAntigravity = "google-antigravity"
    case openAICodex = "openai-codex"
}

public struct OAuthPrompt: Sendable {
    public var message: String
    public var placeholder: String?
    public var allowEmpty: Bool

    public init(message: String, placeholder: String? = nil, allowEmpty: Bool = false) {
        self.message = message
        self.placeholder = placeholder
        self.allowEmpty = allowEmpty
    }
}

public struct OAuthAuthInfo: Sendable {
    public var url: String
    public var instructions: String?

    public init(url: String, instructions: String? = nil) {
        self.url = url
        self.instructions = instructions
    }
}

public struct OAuthProviderInfo: Sendable {
    public var id: OAuthProvider
    public var name: String
    public var available: Bool

    public init(id: OAuthProvider, name: String, available: Bool) {
        self.id = id
        self.name = name
        self.available = available
    }
}

public struct OAuthLoginCallbacks: Sendable {
    public var onAuth: @MainActor @Sendable (OAuthAuthInfo) -> Void
    public var onPrompt: @MainActor @Sendable (OAuthPrompt) async throws -> String
    public var onProgress: (@MainActor @Sendable (String) -> Void)?
    public var onManualCodeInput: (@MainActor @Sendable () async throws -> String?)?
    public var signal: CancellationToken?

    public init(
        onAuth: @escaping @MainActor @Sendable (OAuthAuthInfo) -> Void,
        onPrompt: @escaping @MainActor @Sendable (OAuthPrompt) async throws -> String,
        onProgress: (@MainActor @Sendable (String) -> Void)? = nil,
        onManualCodeInput: (@MainActor @Sendable () async throws -> String?)? = nil,
        signal: CancellationToken? = nil
    ) {
        self.onAuth = onAuth
        self.onPrompt = onPrompt
        self.onProgress = onProgress
        self.onManualCodeInput = onManualCodeInput
        self.signal = signal
    }
}

public enum OAuthError: Error, LocalizedError {
    case missingCredentials(String)
    case missingProjectId(String)
    case missingAuthorizationCode
    case stateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case invalidToken
    case unsupportedPlatform(String)
    case notImplemented(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider):
            return "No OAuth credentials found for \(provider)"
        case .missingProjectId(let provider):
            return "\(provider) OAuth credentials missing projectId"
        case .missingAuthorizationCode:
            return "Missing authorization code"
        case .stateMismatch:
            return "State mismatch"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .refreshFailed(let message):
            return "OAuth token refresh failed: \(message)"
        case .invalidToken:
            return "OAuth token response missing required fields"
        case .unsupportedPlatform(let message):
            return "OAuth not supported on this platform: \(message)"
        case .notImplemented(let provider):
            return "OAuth provider not implemented: \(provider)"
        case .cancelled:
            return "Login cancelled"
        }
    }
}

public func getOAuthProviders() -> [OAuthProviderInfo] {
    [
        OAuthProviderInfo(id: .anthropic, name: "Anthropic (Claude Pro/Max)", available: true),
        OAuthProviderInfo(id: .openAICodex, name: "ChatGPT Plus/Pro (Codex Subscription)", available: true),
        OAuthProviderInfo(id: .githubCopilot, name: "GitHub Copilot", available: false),
        OAuthProviderInfo(id: .googleGeminiCli, name: "Google Cloud Code Assist (Gemini CLI)", available: false),
        OAuthProviderInfo(id: .googleAntigravity, name: "Antigravity (Gemini 3, Claude, GPT-OSS)", available: false),
    ]
}

public func refreshOAuthToken(provider: OAuthProvider, credentials: OAuthCredentials) async throws -> OAuthCredentials {
    switch provider {
    case .anthropic:
        return try await refreshAnthropicToken(credentials.refresh)
    case .githubCopilot:
        throw OAuthError.notImplemented(provider.rawValue)
    case .googleGeminiCli:
        throw OAuthError.notImplemented(provider.rawValue)
    case .googleAntigravity:
        throw OAuthError.notImplemented(provider.rawValue)
    case .openAICodex:
        return try await refreshOpenAICodexToken(credentials.refresh)
    }
}

public func getOAuthApiKey(
    provider: OAuthProvider,
    credentials: [String: OAuthCredentials]
) async throws -> (newCredentials: OAuthCredentials, apiKey: String)? {
    guard var creds = credentials[provider.rawValue] else {
        return nil
    }

    if nowMs() >= creds.expires {
        creds = try await refreshOAuthToken(provider: provider, credentials: creds)
    }

    let apiKey = try oauthApiKey(provider: provider, accessToken: creds.access, projectId: creds.projectId)
    return (creds, apiKey)
}

public func oauthApiKey(provider: OAuthProvider, accessToken: String, projectId: String?) throws -> String {
    if requiresProjectId(provider) {
        guard let projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        let payload: [String: String] = ["token": accessToken, "projectId": projectId]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? accessToken
    }
    return accessToken
}

public func oauthApiKey(provider: OAuthProvider, credentials: OAuthCredentials) throws -> String {
    try oauthApiKey(provider: provider, accessToken: credentials.access, projectId: credentials.projectId)
}

public func loginAnthropic(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let pkce = try generatePKCE()
    let authUrl = anthropicAuthorizeUrl(verifier: pkce.verifier, challenge: pkce.challenge)
    await callbacks.onAuth(OAuthAuthInfo(url: authUrl))

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    let authCode = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code:"))
    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }
    let parts = authCode.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let code = parts.first.map(String.init) ?? ""
    let state = parts.count > 1 ? String(parts[1]) : nil

    let token = try await exchangeAnthropicCode(code: code, state: state, verifier: pkce.verifier)
    return token
}

public func refreshAnthropicToken(_ refreshToken: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    let body: [String: Any] = [
        "grant_type": "refresh_token",
        "client_id": anthropicClientId(),
        "refresh_token": refreshToken,
    ]
    let response = try await postJson(url: url, body: body)
    let token: AnthropicTokenResponse = try decodeJson(response.data)
    return OAuthCredentials(
        refresh: token.refresh_token,
        access: token.access_token,
        expires: nowMs() + token.expires_in * 1000 - 5 * 60 * 1000
    )
}

public func loginOpenAICodex(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let flow = try createOpenAICodexAuthorizationFlow()
    let server = await OpenAICodexCallbackServer.start(state: flow.state)

    await callbacks.onAuth(OAuthAuthInfo(
        url: flow.url,
        instructions: "A browser window should open. Complete login to finish."
    ))

    defer {
        if let server {
            Task { await server.close() }
        }
    }

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    var code: String?
    if let server {
        code = await server.waitForCode(timeoutSeconds: 60, signal: callbacks.signal)
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
    }

    if code == nil, let manualInput = callbacks.onManualCodeInput {
        let value = try await manualInput()
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        if let value {
            let parsed = parseAuthorizationInput(value)
            if let parsedState = parsed.state, parsedState != flow.state {
                throw OAuthError.stateMismatch
            }
            code = parsed.code
        }
    }

    if code == nil {
        let input = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code (or full redirect URL):"))
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        let parsed = parseAuthorizationInput(input)
        if let parsedState = parsed.state, parsedState != flow.state {
            throw OAuthError.stateMismatch
        }
        code = parsed.code
    }

    guard let code, !code.isEmpty else {
        throw OAuthError.missingAuthorizationCode
    }

    let token = try await exchangeOpenAICode(code: code, verifier: flow.verifier)
    guard let accountId = openAICodexAccountId(from: token.access) else {
        throw OAuthError.invalidToken
    }

    return OAuthCredentials(
        refresh: token.refresh,
        access: token.access,
        expires: token.expires,
        accountId: accountId
    )
}

public func refreshOpenAICodexToken(_ refreshToken: String) async throws -> OAuthCredentials {
    let token = try await refreshOpenAICode(refreshToken: refreshToken)
    guard let accountId = openAICodexAccountId(from: token.access) else {
        throw OAuthError.invalidToken
    }
    return OAuthCredentials(
        refresh: token.refresh,
        access: token.access,
        expires: token.expires,
        accountId: accountId
    )
}

private struct PKCEPair {
    let verifier: String
    let challenge: String
}

private func generatePKCE() throws -> PKCEPair {
    let verifierBytes = randomBytes(count: 32)
    let verifier = base64UrlEncode(verifierBytes)

    let challengeData = try sha256(Data(verifier.utf8))
    let challenge = base64UrlEncode(challengeData)
    return PKCEPair(verifier: verifier, challenge: challenge)
}

private func sha256(_ data: Data) throws -> Data {
#if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    return Data(digest)
#else
    throw OAuthError.unsupportedPlatform("CryptoKit SHA256 not available")
#endif
}

private func base64UrlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64UrlDecode(_ input: String) -> Data? {
    var base64 = input
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let remainder = base64.count % 4
    if remainder == 2 {
        base64 += "=="
    } else if remainder == 3 {
        base64 += "="
    } else if remainder == 1 {
        return nil
    }

    return Data(base64Encoded: base64)
}

private func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}

private func randomBytes(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var rng = SystemRandomNumberGenerator()
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &rng)
    }
    return Data(bytes)
}

private func randomHex(count: Int) -> String {
    let bytes = randomBytes(count: count)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func requiresProjectId(_ provider: OAuthProvider) -> Bool {
    provider == .googleGeminiCli || provider == .googleAntigravity
}

private func anthropicClientId() -> String {
    let encoded = "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl"
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private func anthropicAuthorizeUrl(verifier: String, challenge: String) -> String {
    var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
    components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: anthropicClientId()),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: "https://console.anthropic.com/oauth/code/callback"),
        URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: verifier),
    ]
    return components.url?.absoluteString ?? "https://claude.ai/oauth/authorize"
}

private struct AnthropicTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
}

private func exchangeAnthropicCode(code: String, state: String?, verifier: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    var body: [String: Any] = [
        "grant_type": "authorization_code",
        "client_id": anthropicClientId(),
        "code": code,
        "redirect_uri": "https://console.anthropic.com/oauth/code/callback",
        "code_verifier": verifier,
    ]
    if let state {
        body["state"] = state
    }
    let response = try await postJson(url: url, body: body)
    let token: AnthropicTokenResponse = try decodeJson(response.data)
    return OAuthCredentials(
        refresh: token.refresh_token,
        access: token.access_token,
        expires: nowMs() + token.expires_in * 1000 - 5 * 60 * 1000
    )
}

private struct HttpResponse {
    let data: Data
    let status: Int
}

private func postJson(url: URL, body: [String: Any]) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw OAuthError.tokenExchangeFailed(message)
    }
    return HttpResponse(data: data, status: status)
}

private func postForm(url: URL, params: [String: String]) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let form = params
        .map { "\($0.key)=\(urlEncode($0.value))" }
        .joined(separator: "&")
    request.httpBody = form.data(using: .utf8)

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw OAuthError.tokenExchangeFailed(message)
    }
    return HttpResponse(data: data, status: status)
}

private func urlEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private func decodeJson<T: Decodable>(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}

private struct OpenAITokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
}

private struct OpenAICodexToken {
    let access: String
    let refresh: String
    let expires: Double
}

private func createOpenAICodexAuthorizationFlow() throws -> (verifier: String, state: String, url: String) {
    let pkce = try generatePKCE()
    let state = randomHex(count: 16)

    var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
    components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
        URLQueryItem(name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
        URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        URLQueryItem(name: "originator", value: "codex_cli_rs"),
    ]
    let url = components.url?.absoluteString ?? "https://auth.openai.com/oauth/authorize"
    return (pkce.verifier, state, url)
}

private func exchangeOpenAICode(code: String, verifier: String) async throws -> OpenAICodexToken {
    let url = URL(string: "https://auth.openai.com/oauth/token")!
    let response = try await postForm(
        url: url,
        params: [
            "grant_type": "authorization_code",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": "http://localhost:1455/auth/callback",
        ]
    )
    let token: OpenAITokenResponse = try decodeJson(response.data)
    return OpenAICodexToken(
        access: token.access_token,
        refresh: token.refresh_token,
        expires: nowMs() + token.expires_in * 1000
    )
}

private func refreshOpenAICode(refreshToken: String) async throws -> OpenAICodexToken {
    let url = URL(string: "https://auth.openai.com/oauth/token")!
    let response = try await postForm(
        url: url,
        params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        ]
    )
    let token: OpenAITokenResponse = try decodeJson(response.data)
    return OpenAICodexToken(
        access: token.access_token,
        refresh: token.refresh_token,
        expires: nowMs() + token.expires_in * 1000
    )
}

private func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (nil, nil) }

    if let url = URL(string: trimmed),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        let code = components.queryItems?.first { $0.name == "code" }?.value
        let state = components.queryItems?.first { $0.name == "state" }?.value
        if code != nil || state != nil {
            return (code, state)
        }
    }

    if trimmed.contains("#") {
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = parts.first.map(String.init)
        let state = parts.count > 1 ? String(parts[1]) : nil
        return (code, state)
    }

    if trimmed.contains("code=") {
        let prefixed = "https://localhost/?" + trimmed
        if let url = URL(string: prefixed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let code = components.queryItems?.first { $0.name == "code" }?.value
            let state = components.queryItems?.first { $0.name == "state" }?.value
            return (code, state)
        }
    }

    return (trimmed, nil)
}

private func openAICodexAccountId(from accessToken: String) -> String? {
    guard let payload = decodeJwt(accessToken) else { return nil }
    guard let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
    let accountId = auth["chatgpt_account_id"] as? String
    return (accountId?.isEmpty == false) ? accountId : nil
}

private func decodeJwt(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    guard let data = base64UrlDecode(String(parts[1])) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

#if canImport(Network)
private actor OpenAICodexCallbackServer {
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "pi.oauth.openai-codex")
    private var code: String?
    private var cancelled = false

    private init(listener: NWListener, state: String) {
        self.listener = listener
        self.state = state
    }

    static func start(state: String) async -> OpenAICodexCallbackServer? {
        guard let port = NWEndpoint.Port(rawValue: 1455) else { return nil }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            return nil
        }

        let server = OpenAICodexCallbackServer(listener: listener, state: state)
        let ready = await server.startListener()
        return ready ? server : nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if let code { return code }
            if cancelled { return nil }
            if signal?.isCancelled == true {
                cancelled = true
                return nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return code
    }

    func cancelWait() {
        cancelled = true
    }

    func close() {
        listener.cancel()
    }

    private func startListener() async -> Bool {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: true)
                case .failed:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private final class ConnectionState: Sendable {
        let buffer = LockedState(Data())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = ConnectionState()
        scheduleReceive(connection, state: state)
    }

    private func scheduleReceive(_ connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            var requestLine: String?
            state.buffer.withLock { buffer in
                if let data {
                    buffer.append(data)
                }
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    requestLine = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                }
            }
            if let requestLine {
                Task { await self?.handleRequestLine(requestLine, connection: connection) }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            Task { await self?.scheduleReceive(connection, state: state) }
        }
    }

    private func handleRequestLine(_ line: String, connection: NWConnection) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        let pathPart = String(parts[1])
        guard let url = URL(string: "http://localhost\(pathPart)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        guard components.path == "/auth/callback" else {
            sendResponse(connection, status: 404, body: "Not found")
            return
        }

        let receivedState = components.queryItems?.first { $0.name == "state" }?.value
        if receivedState != state {
            sendResponse(connection, status: 400, body: "State mismatch")
            return
        }

        guard let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value, !codeParam.isEmpty else {
            sendResponse(connection, status: 400, body: "Missing authorization code")
            return
        }

        code = codeParam
        sendResponse(connection, status: 200, body: openAICodexSuccessHtml())
    }

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText = status == 200 ? "OK" : "Error"
        let headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Pragma: no-cache",
            "",
            ""
        ]
        let header = headerLines.joined(separator: "\r\n")
        let responseData = header.data(using: .utf8, allowLossyConversion: false) ?? Data()
        connection.send(content: responseData + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#else
private final class OpenAICodexCallbackServer {
    static func start(state: String) async -> OpenAICodexCallbackServer? {
        nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        nil
    }

    func cancelWait() {}

    func close() {}
}
#endif

private func openAICodexSuccessHtml() -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Authentication successful</title>
    </head>
    <body>
      <p>Authentication successful. Return to your terminal to continue.</p>
    </body>
    </html>
    """
}
