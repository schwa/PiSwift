import Foundation

public struct CompactionSettingsOverrides: Sendable {
    public var enabled: Bool?
    public var reserveTokens: Int?
    public var keepRecentTokens: Int?

    public init(enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
    }
}

public struct BranchSummarySettings: Sendable {
    public var reserveTokens: Int?
}

public struct RetrySettings: Sendable {
    public var enabled: Bool?
    public var maxRetries: Int?
    public var baseDelayMs: Int?
}

public struct SkillsSettings: Sendable {
    public var enabled: Bool?
    public var enableCodexUser: Bool?
    public var enableClaudeUser: Bool?
    public var enableClaudeProject: Bool?
    public var enablePiUser: Bool?
    public var enablePiProject: Bool?
    public var customDirectories: [String]?
    public var ignoredSkills: [String]?
    public var includeSkills: [String]?
}

public struct TerminalSettings: Sendable {
    public var showImages: Bool?
}

public struct ImageSettings: Sendable {
    public var autoResize: Bool?
}

public struct Settings: Sendable {
    public var lastChangelogVersion: String?
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: String?
    public var steeringMode: String?
    public var followUpMode: String?
    public var theme: String?
    public var compaction: CompactionSettingsOverrides?
    public var branchSummary: BranchSummarySettings?
    public var retry: RetrySettings?
    public var hideThinkingBlock: Bool?
    public var shellPath: String?
    public var collapseChangelog: Bool?
    public var hooks: [String]?
    public var customTools: [String]?
    public var skills: SkillsSettings?
    public var terminal: TerminalSettings?
    public var images: ImageSettings?
    public var enabledModels: [String]?

    public init() {}
}

public final class SettingsManager: @unchecked Sendable {
    private var settingsPath: String?
    private var projectSettingsPath: String?
    private var globalSettings: Settings
    private var settings: Settings
    private let persist: Bool

    private init(settingsPath: String?, projectSettingsPath: String?, initial: Settings, persist: Bool) {
        self.settingsPath = settingsPath
        self.projectSettingsPath = projectSettingsPath
        self.globalSettings = initial
        self.settings = initial
        self.persist = persist
        let projectSettings = loadProjectSettings()
        self.settings = mergeSettings(globalSettings, projectSettings)
    }

    public static func create(_ cwd: String = FileManager.default.currentDirectoryPath, _ agentDir: String = getAgentDir()) -> SettingsManager {
        let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
        let projectSettingsPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json").path
        let globalSettings = loadFromFile(settingsPath)
        return SettingsManager(settingsPath: settingsPath, projectSettingsPath: projectSettingsPath, initial: globalSettings, persist: true)
    }

    public static func inMemory(_ settings: Settings = Settings()) -> SettingsManager {
        SettingsManager(settingsPath: nil, projectSettingsPath: nil, initial: settings, persist: false)
    }

    public func applyOverrides(_ overrides: Settings) {
        settings = mergeSettings(settings, overrides)
    }

    public func getLastChangelogVersion() -> String? {
        settings.lastChangelogVersion
    }

    public func setLastChangelogVersion(_ version: String) {
        globalSettings.lastChangelogVersion = version
        save()
    }

    public func getDefaultProvider() -> String? {
        settings.defaultProvider
    }

    public func getDefaultModel() -> String? {
        settings.defaultModel
    }

    public func setDefaultProvider(_ provider: String) {
        globalSettings.defaultProvider = provider
        save()
    }

    public func setDefaultModel(_ model: String) {
        globalSettings.defaultModel = model
        save()
    }

    public func setDefaultModelAndProvider(_ provider: String, _ model: String) {
        globalSettings.defaultProvider = provider
        globalSettings.defaultModel = model
        save()
    }

    public func getSteeringMode() -> String {
        settings.steeringMode ?? "one-at-a-time"
    }

    public func setSteeringMode(_ mode: String) {
        globalSettings.steeringMode = mode
        save()
    }

    public func getFollowUpMode() -> String {
        settings.followUpMode ?? "one-at-a-time"
    }

    public func setFollowUpMode(_ mode: String) {
        globalSettings.followUpMode = mode
        save()
    }

    public func getTheme() -> String? {
        settings.theme
    }

    public func setTheme(_ theme: String) {
        globalSettings.theme = theme
        save()
    }

    public func getDefaultThinkingLevel() -> String? {
        settings.defaultThinkingLevel
    }

    public func setDefaultThinkingLevel(_ level: String) {
        globalSettings.defaultThinkingLevel = level
        save()
    }

    public func getCompactionEnabled() -> Bool {
        settings.compaction?.enabled ?? true
    }

    public func setCompactionEnabled(_ enabled: Bool) {
        if globalSettings.compaction == nil { globalSettings.compaction = CompactionSettingsOverrides() }
        globalSettings.compaction?.enabled = enabled
        save()
    }

    public func getCompactionSettingsOverrides() -> CompactionSettingsOverrides {
        let compaction = settings.compaction ?? CompactionSettingsOverrides()
        return CompactionSettingsOverrides(
            enabled: compaction.enabled ?? true,
            reserveTokens: compaction.reserveTokens ?? 16384,
            keepRecentTokens: compaction.keepRecentTokens ?? 20000
        )
    }

    public func getCompactionSettings() -> CompactionSettings {
        let overrides = getCompactionSettingsOverrides()
        return CompactionSettings(
            enabled: overrides.enabled ?? true,
            reserveTokens: overrides.reserveTokens ?? 16384,
            keepRecentTokens: overrides.keepRecentTokens ?? 20000
        )
    }

    public func getBranchSummarySettings() -> BranchSummarySettings {
        let branch = settings.branchSummary ?? BranchSummarySettings()
        return BranchSummarySettings(reserveTokens: branch.reserveTokens ?? 16384)
    }

    public func getRetrySettings() -> RetrySettings {
        let retry = settings.retry ?? RetrySettings()
        return RetrySettings(
            enabled: retry.enabled ?? true,
            maxRetries: retry.maxRetries ?? 3,
            baseDelayMs: retry.baseDelayMs ?? 2000
        )
    }

    public func setRetryEnabled(_ enabled: Bool) {
        if globalSettings.retry == nil { globalSettings.retry = RetrySettings() }
        globalSettings.retry?.enabled = enabled
        save()
    }

    public func getHideThinkingBlock() -> Bool {
        settings.hideThinkingBlock ?? false
    }

    public func setHideThinkingBlock(_ hide: Bool) {
        globalSettings.hideThinkingBlock = hide
        save()
    }

    public func getShellPath() -> String? {
        settings.shellPath
    }

    public func setShellPath(_ path: String?) {
        globalSettings.shellPath = path
        save()
    }

    public func getCollapseChangelog() -> Bool {
        settings.collapseChangelog ?? false
    }

    public func setCollapseChangelog(_ collapse: Bool) {
        globalSettings.collapseChangelog = collapse
        save()
    }

    public func getHooks() -> [String] {
        settings.hooks ?? []
    }

    public func setHooks(_ paths: [String]) {
        globalSettings.hooks = paths
        save()
    }

    public func getCustomTools() -> [String] {
        settings.customTools ?? []
    }

    public func setCustomTools(_ paths: [String]) {
        globalSettings.customTools = paths
        save()
    }

    public func getSkillsSettings() -> SkillsSettings {
        settings.skills ?? SkillsSettings()
    }

    public func getEnabledModels() -> [String]? {
        settings.enabledModels
    }

    public func getTerminalSettings() -> TerminalSettings {
        settings.terminal ?? TerminalSettings()
    }

    public func getShowImages() -> Bool {
        settings.terminal?.showImages ?? true
    }

    public func setShowImages(_ show: Bool) {
        if globalSettings.terminal == nil { globalSettings.terminal = TerminalSettings() }
        globalSettings.terminal?.showImages = show
        save()
    }

    public func getAutoResizeImages() -> Bool {
        settings.images?.autoResize ?? true
    }

    public func setAutoResizeImages(_ enabled: Bool) {
        if globalSettings.images == nil { globalSettings.images = ImageSettings() }
        globalSettings.images?.autoResize = enabled
        save()
    }

    private static func loadFromFile(_ path: String) -> Settings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Settings()
        }
        return SettingsManager.decodeSettings(json)
    }

    private func loadProjectSettings() -> Settings {
        guard let projectPath = projectSettingsPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Settings()
        }
        return SettingsManager.decodeSettings(json)
    }

    private static func decodeSettings(_ json: [String: Any]) -> Settings {
        var settings = Settings()
        if let queueMode = json["queueMode"] as? String, json["steeringMode"] == nil {
            settings.steeringMode = queueMode
        }
        settings.lastChangelogVersion = json["lastChangelogVersion"] as? String
        settings.defaultProvider = json["defaultProvider"] as? String
        settings.defaultModel = json["defaultModel"] as? String
        settings.defaultThinkingLevel = json["defaultThinkingLevel"] as? String
        settings.steeringMode = json["steeringMode"] as? String ?? settings.steeringMode
        settings.followUpMode = json["followUpMode"] as? String
        settings.theme = json["theme"] as? String
        settings.hideThinkingBlock = json["hideThinkingBlock"] as? Bool
        settings.shellPath = json["shellPath"] as? String
        settings.collapseChangelog = json["collapseChangelog"] as? Bool
        settings.hooks = json["hooks"] as? [String]
        settings.customTools = json["customTools"] as? [String]
        settings.enabledModels = json["enabledModels"] as? [String]

        if let compaction = json["compaction"] as? [String: Any] {
            settings.compaction = CompactionSettingsOverrides(
                enabled: compaction["enabled"] as? Bool,
                reserveTokens: compaction["reserveTokens"] as? Int,
                keepRecentTokens: compaction["keepRecentTokens"] as? Int
            )
        }

        if let branch = json["branchSummary"] as? [String: Any] {
            settings.branchSummary = BranchSummarySettings(reserveTokens: branch["reserveTokens"] as? Int)
        }

        if let retry = json["retry"] as? [String: Any] {
            settings.retry = RetrySettings(
                enabled: retry["enabled"] as? Bool,
                maxRetries: retry["maxRetries"] as? Int,
                baseDelayMs: retry["baseDelayMs"] as? Int
            )
        }

        if let skills = json["skills"] as? [String: Any] {
            settings.skills = SkillsSettings(
                enabled: skills["enabled"] as? Bool,
                enableCodexUser: skills["enableCodexUser"] as? Bool,
                enableClaudeUser: skills["enableClaudeUser"] as? Bool,
                enableClaudeProject: skills["enableClaudeProject"] as? Bool,
                enablePiUser: skills["enablePiUser"] as? Bool,
                enablePiProject: skills["enablePiProject"] as? Bool,
                customDirectories: skills["customDirectories"] as? [String],
                ignoredSkills: skills["ignoredSkills"] as? [String],
                includeSkills: skills["includeSkills"] as? [String]
            )
        }

        if let terminal = json["terminal"] as? [String: Any] {
            settings.terminal = TerminalSettings(showImages: terminal["showImages"] as? Bool)
        }

        if let images = json["images"] as? [String: Any] {
            settings.images = ImageSettings(autoResize: images["autoResize"] as? Bool)
        }

        return settings
    }

    private func save() {
        guard persist, let settingsPath else { return }
        var json: [String: Any] = [:]
        json["lastChangelogVersion"] = globalSettings.lastChangelogVersion
        json["defaultProvider"] = globalSettings.defaultProvider
        json["defaultModel"] = globalSettings.defaultModel
        json["defaultThinkingLevel"] = globalSettings.defaultThinkingLevel
        json["steeringMode"] = globalSettings.steeringMode
        json["followUpMode"] = globalSettings.followUpMode
        json["theme"] = globalSettings.theme
        json["hideThinkingBlock"] = globalSettings.hideThinkingBlock
        json["shellPath"] = globalSettings.shellPath
        json["collapseChangelog"] = globalSettings.collapseChangelog
        json["hooks"] = globalSettings.hooks
        json["customTools"] = globalSettings.customTools
        json["enabledModels"] = globalSettings.enabledModels

        if let compaction = globalSettings.compaction {
            json["compaction"] = [
                "enabled": compaction.enabled as Any,
                "reserveTokens": compaction.reserveTokens as Any,
                "keepRecentTokens": compaction.keepRecentTokens as Any,
            ]
        }

        if let branch = globalSettings.branchSummary {
            json["branchSummary"] = ["reserveTokens": branch.reserveTokens as Any]
        }

        if let retry = globalSettings.retry {
            json["retry"] = [
                "enabled": retry.enabled as Any,
                "maxRetries": retry.maxRetries as Any,
                "baseDelayMs": retry.baseDelayMs as Any,
            ]
        }

        if let skills = globalSettings.skills {
            json["skills"] = [
                "enabled": skills.enabled as Any,
                "enableCodexUser": skills.enableCodexUser as Any,
                "enableClaudeUser": skills.enableClaudeUser as Any,
                "enableClaudeProject": skills.enableClaudeProject as Any,
                "enablePiUser": skills.enablePiUser as Any,
                "enablePiProject": skills.enablePiProject as Any,
                "customDirectories": skills.customDirectories as Any,
                "ignoredSkills": skills.ignoredSkills as Any,
                "includeSkills": skills.includeSkills as Any,
            ]
        }

        if let terminal = globalSettings.terminal {
            json["terminal"] = ["showImages": terminal.showImages as Any]
        }

        if let images = globalSettings.images {
            json["images"] = ["autoResize": images.autoResize as Any]
        }

        let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }

        let projectSettings = loadProjectSettings()
        settings = mergeSettings(globalSettings, projectSettings)
    }

    private func mergeSettings(_ base: Settings, _ override: Settings) -> Settings {
        var result = base
        if override.lastChangelogVersion != nil { result.lastChangelogVersion = override.lastChangelogVersion }
        if override.defaultProvider != nil { result.defaultProvider = override.defaultProvider }
        if override.defaultModel != nil { result.defaultModel = override.defaultModel }
        if override.defaultThinkingLevel != nil { result.defaultThinkingLevel = override.defaultThinkingLevel }
        if override.steeringMode != nil { result.steeringMode = override.steeringMode }
        if override.followUpMode != nil { result.followUpMode = override.followUpMode }
        if override.theme != nil { result.theme = override.theme }
        if override.compaction != nil { result.compaction = override.compaction }
        if override.branchSummary != nil { result.branchSummary = override.branchSummary }
        if override.retry != nil { result.retry = override.retry }
        if override.hideThinkingBlock != nil { result.hideThinkingBlock = override.hideThinkingBlock }
        if override.shellPath != nil { result.shellPath = override.shellPath }
        if override.collapseChangelog != nil { result.collapseChangelog = override.collapseChangelog }
        if override.hooks != nil { result.hooks = override.hooks }
        if override.customTools != nil { result.customTools = override.customTools }
        if override.skills != nil { result.skills = override.skills }
        if override.terminal != nil { result.terminal = override.terminal }
        if override.images != nil { result.images = override.images }
        if override.enabledModels != nil { result.enabledModels = override.enabledModels }
        return result
    }
}
