import Foundation
import PiSwiftAI

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
    public init(
        enabled: Bool? = nil,
        enableCodexUser: Bool? = nil,
        enableClaudeUser: Bool? = nil,
        enableClaudeProject: Bool? = nil,
        enablePiUser: Bool? = nil,
        enablePiProject: Bool? = nil,
        enableSkillCommands: Bool? = nil,
        customDirectories: [String]? = nil,
        ignoredSkills: [String]? = nil,
        includeSkills: [String]? = nil
    ) {
        self.enabled = enabled
        self.enableCodexUser = enableCodexUser
        self.enableClaudeUser = enableClaudeUser
        self.enableClaudeProject = enableClaudeProject
        self.enablePiUser = enablePiUser
        self.enablePiProject = enablePiProject
        self.enableSkillCommands = enableSkillCommands
        self.customDirectories = customDirectories
        self.ignoredSkills = ignoredSkills
        self.includeSkills = includeSkills
    }
    
    public var enabled: Bool?
    public var enableCodexUser: Bool?
    public var enableClaudeUser: Bool?
    public var enableClaudeProject: Bool?
    public var enablePiUser: Bool?
    public var enablePiProject: Bool?
    public var enableSkillCommands: Bool?
    public var customDirectories: [String]?
    public var ignoredSkills: [String]?
    public var includeSkills: [String]?
}

public struct TerminalSettings: Sendable {
    public var showImages: Bool?
}

public struct ImageSettings: Sendable {
    public var autoResize: Bool?
    public var blockImages: Bool?
}

public struct ThinkingBudgetsSettings: Sendable {
    public var minimal: Int?
    public var low: Int?
    public var medium: Int?
    public var high: Int?

    public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
        self.minimal = minimal
        self.low = low
        self.medium = medium
        self.high = high
    }
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
    public var packages: [PackageSource]?
    public var extensions: [String]?
    public var skillPaths: [String]?
    public var prompts: [String]?
    public var themes: [String]?
    public var enableSkillCommands: Bool?
    public var hooks: [String]?
    public var customTools: [String]?
    public var skills: SkillsSettings?
    public var terminal: TerminalSettings?
    public var images: ImageSettings?
    public var enabledModels: [String]?
    public var doubleEscapeAction: String?
    public var thinkingBudgets: ThinkingBudgetsSettings?

    public init() {}
}

public final class SettingsManager: Sendable {
    private struct State: Sendable {
        var settingsPath: String?
        var projectSettingsPath: String?
        var globalSettings: Settings
        var settings: Settings
    }

    private let state: LockedState<State>
    private let persist: Bool

    private var settingsPath: String? {
        get { state.withLock { $0.settingsPath } }
        set { state.withLock { $0.settingsPath = newValue } }
    }

    private var projectSettingsPath: String? {
        get { state.withLock { $0.projectSettingsPath } }
        set { state.withLock { $0.projectSettingsPath = newValue } }
    }

    private var globalSettings: Settings {
        get { state.withLock { $0.globalSettings } }
        set { state.withLock { $0.globalSettings = newValue } }
    }

    private var settings: Settings {
        get { state.withLock { $0.settings } }
        set { state.withLock { $0.settings = newValue } }
    }

    private init(settingsPath: String?, projectSettingsPath: String?, initial: Settings, persist: Bool) {
        self.persist = persist
        self.state = LockedState(State(
            settingsPath: settingsPath,
            projectSettingsPath: projectSettingsPath,
            globalSettings: initial,
            settings: initial
        ))
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

    public func getGlobalSettings() -> Settings {
        globalSettings
    }

    public func getProjectSettings() -> Settings {
        loadProjectSettings()
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

    public func getPackages() -> [PackageSource] {
        settings.packages ?? []
    }

    public func setPackages(_ packages: [PackageSource]) {
        globalSettings.packages = packages
        save()
    }

    public func setProjectPackages(_ packages: [PackageSource]) {
        var projectSettings = loadProjectSettings()
        projectSettings.packages = packages
        saveProjectSettings(projectSettings)
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func getExtensionPaths() -> [String] {
        settings.extensions ?? []
    }

    public func setExtensionPaths(_ paths: [String]) {
        globalSettings.extensions = paths
        save()
    }

    public func setProjectExtensionPaths(_ paths: [String]) {
        var projectSettings = loadProjectSettings()
        projectSettings.extensions = paths
        saveProjectSettings(projectSettings)
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func getSkillPaths() -> [String] {
        settings.skillPaths ?? []
    }

    public func setSkillPaths(_ paths: [String]) {
        globalSettings.skillPaths = paths
        save()
    }

    public func setProjectSkillPaths(_ paths: [String]) {
        var projectSettings = loadProjectSettings()
        projectSettings.skillPaths = paths
        saveProjectSettings(projectSettings)
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func getPromptTemplatePaths() -> [String] {
        settings.prompts ?? []
    }

    public func setPromptTemplatePaths(_ paths: [String]) {
        globalSettings.prompts = paths
        save()
    }

    public func setProjectPromptTemplatePaths(_ paths: [String]) {
        var projectSettings = loadProjectSettings()
        projectSettings.prompts = paths
        saveProjectSettings(projectSettings)
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func getThemePaths() -> [String] {
        settings.themes ?? []
    }

    public func setThemePaths(_ paths: [String]) {
        globalSettings.themes = paths
        save()
    }

    public func setProjectThemePaths(_ paths: [String]) {
        var projectSettings = loadProjectSettings()
        projectSettings.themes = paths
        saveProjectSettings(projectSettings)
        settings = mergeSettings(globalSettings, projectSettings)
    }

    public func getSkillsSettings() -> SkillsSettings {
        let skills = settings.skills ?? SkillsSettings()
        return SkillsSettings(
            enabled: skills.enabled ?? true,
            enableCodexUser: skills.enableCodexUser ?? true,
            enableClaudeUser: skills.enableClaudeUser ?? true,
            enableClaudeProject: skills.enableClaudeProject ?? true,
            enablePiUser: skills.enablePiUser ?? true,
            enablePiProject: skills.enablePiProject ?? true,
            enableSkillCommands: skills.enableSkillCommands ?? true,
            customDirectories: skills.customDirectories ?? [],
            ignoredSkills: skills.ignoredSkills ?? [],
            includeSkills: skills.includeSkills ?? []
        )
    }

    public func getEnableSkillCommands() -> Bool {
        settings.enableSkillCommands ?? settings.skills?.enableSkillCommands ?? true
    }

    public func setEnableSkillCommands(_ enabled: Bool) {
        globalSettings.enableSkillCommands = enabled
        save()
    }

    public func getEnabledModels() -> [String]? {
        settings.enabledModels
    }

    public func setEnabledModels(_ patterns: [String]?) {
        globalSettings.enabledModels = patterns
        save()
    }

    public func getDoubleEscapeAction() -> String {
        settings.doubleEscapeAction ?? "tree"
    }

    public func setDoubleEscapeAction(_ action: String) {
        globalSettings.doubleEscapeAction = action
        save()
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

    public func getBlockImages() -> Bool {
        settings.images?.blockImages ?? false
    }

    public func setBlockImages(_ blocked: Bool) {
        if globalSettings.images == nil { globalSettings.images = ImageSettings() }
        globalSettings.images?.blockImages = blocked
        if settings.images == nil { settings.images = ImageSettings() }
        settings.images?.blockImages = blocked
        save()
    }

    public func getThinkingBudgets() -> ThinkingBudgets? {
        guard let budgets = settings.thinkingBudgets else { return nil }
        var result: ThinkingBudgets = [:]
        if let minimal = budgets.minimal { result[.minimal] = minimal }
        if let low = budgets.low { result[.low] = low }
        if let medium = budgets.medium { result[.medium] = medium }
        if let high = budgets.high { result[.high] = high }
        return result.isEmpty ? nil : result
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

    private func saveProjectSettings(_ settings: Settings) {
        guard let projectPath = projectSettingsPath else { return }
        let dir = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        json["lastChangelogVersion"] = settings.lastChangelogVersion
        json["defaultProvider"] = settings.defaultProvider
        json["defaultModel"] = settings.defaultModel
        json["defaultThinkingLevel"] = settings.defaultThinkingLevel
        json["steeringMode"] = settings.steeringMode
        json["followUpMode"] = settings.followUpMode
        json["theme"] = settings.theme
        json["hideThinkingBlock"] = settings.hideThinkingBlock
        json["shellPath"] = settings.shellPath
        json["collapseChangelog"] = settings.collapseChangelog
        if let packages = settings.packages {
            json["packages"] = encodePackageSources(packages)
        }
        json["extensions"] = settings.extensions
        if let skillPaths = settings.skillPaths {
            json["skills"] = skillPaths
        }
        json["prompts"] = settings.prompts
        json["themes"] = settings.themes
        json["enableSkillCommands"] = settings.enableSkillCommands
        json["hooks"] = settings.hooks
        json["customTools"] = settings.customTools
        json["enabledModels"] = settings.enabledModels
        json["doubleEscapeAction"] = settings.doubleEscapeAction

        if let compaction = settings.compaction {
            json["compaction"] = [
                "enabled": compaction.enabled as Any,
                "reserveTokens": compaction.reserveTokens as Any,
                "keepRecentTokens": compaction.keepRecentTokens as Any,
            ]
        }

        if let branch = settings.branchSummary {
            json["branchSummary"] = ["reserveTokens": branch.reserveTokens as Any]
        }

        if let retry = settings.retry {
            json["retry"] = [
                "enabled": retry.enabled as Any,
                "maxRetries": retry.maxRetries as Any,
                "baseDelayMs": retry.baseDelayMs as Any,
            ]
        }

        if settings.skillPaths == nil, let skills = settings.skills {
            json["skills"] = [
                "enabled": skills.enabled as Any,
                "enableCodexUser": skills.enableCodexUser as Any,
                "enableClaudeUser": skills.enableClaudeUser as Any,
                "enableClaudeProject": skills.enableClaudeProject as Any,
                "enablePiUser": skills.enablePiUser as Any,
                "enablePiProject": skills.enablePiProject as Any,
                "enableSkillCommands": skills.enableSkillCommands as Any,
                "customDirectories": skills.customDirectories as Any,
                "ignoredSkills": skills.ignoredSkills as Any,
                "includeSkills": skills.includeSkills as Any,
            ]
        }

        if let terminal = settings.terminal {
            json["terminal"] = ["showImages": terminal.showImages as Any]
        }

        if let images = settings.images {
            json["images"] = [
                "autoResize": images.autoResize as Any,
                "blockImages": images.blockImages as Any,
            ]
        }

        if let budgets = settings.thinkingBudgets {
            json["thinkingBudgets"] = [
                "minimal": budgets.minimal as Any,
                "low": budgets.low as Any,
                "medium": budgets.medium as Any,
                "high": budgets.high as Any,
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: projectPath))
        }
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
        if let packages = json["packages"] as? [Any] {
            settings.packages = decodePackageSources(packages)
        }
        settings.extensions = json["extensions"] as? [String]
        settings.prompts = json["prompts"] as? [String]
        settings.themes = json["themes"] as? [String]
        settings.enableSkillCommands = json["enableSkillCommands"] as? Bool
        settings.hooks = json["hooks"] as? [String]
        settings.customTools = json["customTools"] as? [String]
        settings.enabledModels = json["enabledModels"] as? [String]
        settings.doubleEscapeAction = json["doubleEscapeAction"] as? String

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

        if let skillArray = json["skills"] as? [String] {
            settings.skillPaths = skillArray
        } else if let skills = json["skills"] as? [String: Any] {
            let enableSkillCommands = skills["enableSkillCommands"] as? Bool
            if settings.enableSkillCommands == nil, let enableSkillCommands {
                settings.enableSkillCommands = enableSkillCommands
            }
            if settings.skillPaths == nil, let custom = skills["customDirectories"] as? [String], !custom.isEmpty {
                settings.skillPaths = custom
            }
            settings.skills = SkillsSettings(
                enabled: skills["enabled"] as? Bool,
                enableCodexUser: skills["enableCodexUser"] as? Bool,
                enableClaudeUser: skills["enableClaudeUser"] as? Bool,
                enableClaudeProject: skills["enableClaudeProject"] as? Bool,
                enablePiUser: skills["enablePiUser"] as? Bool,
                enablePiProject: skills["enablePiProject"] as? Bool,
                enableSkillCommands: enableSkillCommands,
                customDirectories: skills["customDirectories"] as? [String],
                ignoredSkills: skills["ignoredSkills"] as? [String],
                includeSkills: skills["includeSkills"] as? [String]
            )
        }

        if let terminal = json["terminal"] as? [String: Any] {
            settings.terminal = TerminalSettings(showImages: terminal["showImages"] as? Bool)
        }

        if let images = json["images"] as? [String: Any] {
            settings.images = ImageSettings(
                autoResize: images["autoResize"] as? Bool,
                blockImages: images["blockImages"] as? Bool
            )
        }

        if let budgets = json["thinkingBudgets"] as? [String: Any] {
            settings.thinkingBudgets = ThinkingBudgetsSettings(
                minimal: budgets["minimal"] as? Int,
                low: budgets["low"] as? Int,
                medium: budgets["medium"] as? Int,
                high: budgets["high"] as? Int
            )
        }

        return settings
    }

    private static func decodePackageSources(_ array: [Any]) -> [PackageSource] {
        array.compactMap { decodePackageSource($0) }
    }

    private static func decodePackageSource(_ value: Any) -> PackageSource? {
        if let string = value as? String {
            return .simple(string)
        }
        if let dict = value as? [String: Any], let source = dict["source"] as? String {
            return .filtered(PackageFilterSource(
                source: source,
                extensions: dict["extensions"] as? [String],
                skills: dict["skills"] as? [String],
                prompts: dict["prompts"] as? [String],
                themes: dict["themes"] as? [String]
            ))
        }
        return nil
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
        if let packages = globalSettings.packages {
            json["packages"] = encodePackageSources(packages)
        }
        json["extensions"] = globalSettings.extensions
        if let skillPaths = globalSettings.skillPaths {
            json["skills"] = skillPaths
        }
        json["prompts"] = globalSettings.prompts
        json["themes"] = globalSettings.themes
        json["enableSkillCommands"] = globalSettings.enableSkillCommands
        json["hooks"] = globalSettings.hooks
        json["customTools"] = globalSettings.customTools
        json["enabledModels"] = globalSettings.enabledModels
        json["doubleEscapeAction"] = globalSettings.doubleEscapeAction

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

        if globalSettings.skillPaths == nil, let skills = globalSettings.skills {
            json["skills"] = [
                "enabled": skills.enabled as Any,
                "enableCodexUser": skills.enableCodexUser as Any,
                "enableClaudeUser": skills.enableClaudeUser as Any,
                "enableClaudeProject": skills.enableClaudeProject as Any,
                "enablePiUser": skills.enablePiUser as Any,
                "enablePiProject": skills.enablePiProject as Any,
                "enableSkillCommands": skills.enableSkillCommands as Any,
                "customDirectories": skills.customDirectories as Any,
                "ignoredSkills": skills.ignoredSkills as Any,
                "includeSkills": skills.includeSkills as Any,
            ]
        }

        if let terminal = globalSettings.terminal {
            json["terminal"] = ["showImages": terminal.showImages as Any]
        }

        if let images = globalSettings.images {
            json["images"] = [
                "autoResize": images.autoResize as Any,
                "blockImages": images.blockImages as Any,
            ]
        }

        if let budgets = globalSettings.thinkingBudgets {
            json["thinkingBudgets"] = [
                "minimal": budgets.minimal as Any,
                "low": budgets.low as Any,
                "medium": budgets.medium as Any,
                "high": budgets.high as Any,
            ]
        }

        let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }

        let projectSettings = loadProjectSettings()
        settings = mergeSettings(globalSettings, projectSettings)
    }

    private func encodePackageSources(_ packages: [PackageSource]) -> [Any] {
        packages.map { source in
            switch source {
            case .simple(let value):
                return value
            case .filtered(let value):
                var dict: [String: Any] = ["source": value.source]
                if let extensions = value.extensions { dict["extensions"] = extensions }
                if let skills = value.skills { dict["skills"] = skills }
                if let prompts = value.prompts { dict["prompts"] = prompts }
                if let themes = value.themes { dict["themes"] = themes }
                return dict
            }
        }
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
        if override.packages != nil { result.packages = override.packages }
        if override.extensions != nil { result.extensions = override.extensions }
        if override.skillPaths != nil { result.skillPaths = override.skillPaths }
        if override.prompts != nil { result.prompts = override.prompts }
        if override.themes != nil { result.themes = override.themes }
        if override.enableSkillCommands != nil { result.enableSkillCommands = override.enableSkillCommands }
        if override.hooks != nil { result.hooks = override.hooks }
        if override.customTools != nil { result.customTools = override.customTools }
        if override.skills != nil { result.skills = override.skills }
        if override.terminal != nil { result.terminal = override.terminal }
        if override.images != nil { result.images = override.images }
        if override.enabledModels != nil { result.enabledModels = override.enabledModels }
        if override.doubleEscapeAction != nil { result.doubleEscapeAction = override.doubleEscapeAction }
        if override.thinkingBudgets != nil { result.thinkingBudgets = override.thinkingBudgets }
        return result
    }
}
