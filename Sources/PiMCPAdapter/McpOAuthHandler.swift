import Foundation

// MARK: - OAuth Token Types

public struct OAuthTokens: Sendable {
    public var accessToken: String
    public var tokenType: String
    public var refreshToken: String?
    public var expiresIn: Int?

    public init(accessToken: String, tokenType: String = "bearer", refreshToken: String? = nil, expiresIn: Int? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

// MARK: - Token Storage

private func oauthDir(serverName: String) -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return ((agentDir as NSString).appendingPathComponent("mcp-oauth") as NSString).appendingPathComponent(serverName)
}

public func getStoredTokens(serverName: String) -> OAuthTokens? {
    let path = (oauthDir(serverName: serverName) as NSString).appendingPathComponent("tokens.json")
    guard let data = FileManager.default.contents(atPath: path) else { return nil }

    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let accessToken = dict["access_token"] as? String, !accessToken.isEmpty else { return nil }

    // Check expiration
    if let expiresAt = dict["expiresAt"] as? Double {
        if Date().timeIntervalSince1970 * 1000 > expiresAt {
            return nil
        }
    }

    return OAuthTokens(
        accessToken: accessToken,
        tokenType: dict["token_type"] as? String ?? "bearer",
        refreshToken: dict["refresh_token"] as? String,
        expiresIn: dict["expires_in"] as? Int
    )
}
