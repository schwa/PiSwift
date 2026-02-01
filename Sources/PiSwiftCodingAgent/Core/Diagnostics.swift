import Foundation

public struct ResourceCollision: Sendable {
    public var resourceType: String
    public var name: String
    public var winnerPath: String
    public var loserPath: String
    public var winnerSource: String?
    public var loserSource: String?

    public init(
        resourceType: String,
        name: String,
        winnerPath: String,
        loserPath: String,
        winnerSource: String? = nil,
        loserSource: String? = nil
    ) {
        self.resourceType = resourceType
        self.name = name
        self.winnerPath = winnerPath
        self.loserPath = loserPath
        self.winnerSource = winnerSource
        self.loserSource = loserSource
    }
}

public struct ResourceDiagnostic: Sendable {
    public var type: String
    public var message: String
    public var path: String?
    public var collision: ResourceCollision?

    public init(type: String, message: String, path: String? = nil, collision: ResourceCollision? = nil) {
        self.type = type
        self.message = message
        self.path = path
        self.collision = collision
    }
}
