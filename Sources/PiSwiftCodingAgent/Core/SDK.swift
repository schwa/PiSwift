import Foundation
import PiSwiftAI
import PiSwiftAgent

public typealias HookFactory = @Sendable (HookAPI) -> Void
public typealias CustomTool = Tool

public struct HookDefinition: Sendable {
    public var path: String?
    public var factory: HookFactory

    public init(path: String? = nil, factory: @escaping HookFactory) {
        self.path = path
        self.factory = factory
    }
}

public struct CustomToolDefinition: Sendable {
    public var path: String?
    public var tool: Tool

    public init(path: String? = nil, tool: Tool) {
        self.path = path
        self.tool = tool
    }
}

public struct LoadedCustomTool: Sendable {
    public var path: String
    public var resolvedPath: String
    public var tool: Tool

    public init(path: String, resolvedPath: String, tool: Tool) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.tool = tool
    }
}

public struct CustomToolLoadError: Sendable {
    public var path: String
    public var error: String

    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

public struct CustomToolsLoadResult: @unchecked Sendable {
    public var tools: [LoadedCustomTool]
    public var errors: [CustomToolLoadError]
    public var setUIContext: (@Sendable (_ hasUI: Bool) -> Void)

    public init(
        tools: [LoadedCustomTool],
        errors: [CustomToolLoadError],
        setUIContext: @escaping @Sendable (_ hasUI: Bool) -> Void = { _ in }
    ) {
        self.tools = tools
        self.errors = errors
        self.setUIContext = setUIContext
    }
}

public enum SystemPromptInput: @unchecked Sendable {
    case text(String)
    case builder(@Sendable (String) -> String)
}

public struct CreateAgentSessionOptions: @unchecked Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var authStorage: AuthStorage?
    public var modelRegistry: ModelRegistry?
    public var model: Model?
    public var thinkingLevel: ThinkingLevel?
    public var scopedModels: [ScopedModel]?
    public var systemPrompt: SystemPromptInput?
    public var tools: [Tool]?
    public var customTools: [CustomToolDefinition]?
    public var additionalCustomToolPaths: [String]?
    public var hooks: [HookDefinition]?
    public var additionalHookPaths: [String]?
    public var skills: [Skill]?
    public var contextFiles: [ContextFile]?
    public var slashCommands: [FileSlashCommand]?
    public var sessionManager: SessionManager?
    public var settingsManager: SettingsManager?

    public init(
        cwd: String? = nil,
        agentDir: String? = nil,
        authStorage: AuthStorage? = nil,
        modelRegistry: ModelRegistry? = nil,
        model: Model? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        scopedModels: [ScopedModel]? = nil,
        systemPrompt: SystemPromptInput? = nil,
        tools: [Tool]? = nil,
        customTools: [CustomToolDefinition]? = nil,
        additionalCustomToolPaths: [String]? = nil,
        hooks: [HookDefinition]? = nil,
        additionalHookPaths: [String]? = nil,
        skills: [Skill]? = nil,
        contextFiles: [ContextFile]? = nil,
        slashCommands: [FileSlashCommand]? = nil,
        sessionManager: SessionManager? = nil,
        settingsManager: SettingsManager? = nil
    ) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.authStorage = authStorage
        self.modelRegistry = modelRegistry
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.scopedModels = scopedModels
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.customTools = customTools
        self.additionalCustomToolPaths = additionalCustomToolPaths
        self.hooks = hooks
        self.additionalHookPaths = additionalHookPaths
        self.skills = skills
        self.contextFiles = contextFiles
        self.slashCommands = slashCommands
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
    }
}

public struct CreateAgentSessionResult: Sendable {
    public var session: AgentSession
    public var customToolsResult: CustomToolsLoadResult
    public var modelFallbackMessage: String?

    public init(session: AgentSession, customToolsResult: CustomToolsLoadResult, modelFallbackMessage: String?) {
        self.session = session
        self.customToolsResult = customToolsResult
        self.modelFallbackMessage = modelFallbackMessage
    }
}

public struct SettingsSnapshot: Sendable {
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: String?
    public var steeringMode: String
    public var followUpMode: String
    public var theme: String?
    public var compaction: CompactionSettings
    public var retry: RetrySettings
    public var hideThinkingBlock: Bool
    public var shellPath: String?
    public var collapseChangelog: Bool
    public var hooks: [String]
    public var customTools: [String]
    public var skills: SkillsSettings
    public var terminal: TerminalSettings
    public var enabledModels: [String]?

    public init(
        defaultProvider: String?,
        defaultModel: String?,
        defaultThinkingLevel: String?,
        steeringMode: String,
        followUpMode: String,
        theme: String?,
        compaction: CompactionSettings,
        retry: RetrySettings,
        hideThinkingBlock: Bool,
        shellPath: String?,
        collapseChangelog: Bool,
        hooks: [String],
        customTools: [String],
        skills: SkillsSettings,
        terminal: TerminalSettings,
        enabledModels: [String]?
    ) {
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
        self.defaultThinkingLevel = defaultThinkingLevel
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.theme = theme
        self.compaction = compaction
        self.retry = retry
        self.hideThinkingBlock = hideThinkingBlock
        self.shellPath = shellPath
        self.collapseChangelog = collapseChangelog
        self.hooks = hooks
        self.customTools = customTools
        self.skills = skills
        self.terminal = terminal
        self.enabledModels = enabledModels
    }
}

private func writeStderr(_ message: String) {
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

public func discoverAuthStorage(agentDir: String = getAgentDir()) -> AuthStorage {
    AuthStorage((agentDir as NSString).appendingPathComponent("auth.json"))
}

public func discoverModels(authStorage: AuthStorage, agentDir: String = getAgentDir()) -> ModelRegistry {
    ModelRegistry(authStorage, agentDir)
}

public func discoverHooks(cwd: String? = nil, agentDir: String? = nil) async -> [HookDefinition] {
    let _ = cwd
    let _ = agentDir
    return []
}

public func discoverCustomTools(cwd: String? = nil, agentDir: String? = nil) async -> [CustomToolDefinition] {
    let _ = cwd
    let _ = agentDir
    return []
}

public func discoverSkills(cwd: String? = nil, agentDir: String? = nil, settings: SkillsSettings? = nil) -> [Skill] {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = agentDir ?? getAgentDir()
    let settings = settings ?? SkillsSettings()
    return loadSkills(LoadSkillsOptions(
        cwd: resolvedCwd,
        agentDir: resolvedAgentDir,
        enableCodexUser: settings.enableCodexUser,
        enableClaudeUser: settings.enableClaudeUser,
        enableClaudeProject: settings.enableClaudeProject,
        enablePiUser: settings.enablePiUser,
        enablePiProject: settings.enablePiProject,
        customDirectories: settings.customDirectories,
        ignoredSkills: settings.ignoredSkills,
        includeSkills: settings.includeSkills
    )).skills
}

public func discoverContextFiles(cwd: String? = nil, agentDir: String? = nil) -> [ContextFile] {
    loadProjectContextFiles(LoadContextFilesOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir()
    ))
}

public func discoverSlashCommands(cwd: String? = nil, agentDir: String? = nil) -> [FileSlashCommand] {
    loadSlashCommands(LoadSlashCommandsOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir()
    ))
}

public func loadSettings(cwd: String? = nil, agentDir: String? = nil) -> SettingsSnapshot {
    let manager = SettingsManager.create(cwd ?? FileManager.default.currentDirectoryPath, agentDir ?? getAgentDir())
    return SettingsSnapshot(
        defaultProvider: manager.getDefaultProvider(),
        defaultModel: manager.getDefaultModel(),
        defaultThinkingLevel: manager.getDefaultThinkingLevel(),
        steeringMode: manager.getSteeringMode(),
        followUpMode: manager.getFollowUpMode(),
        theme: manager.getTheme(),
        compaction: manager.getCompactionSettings(),
        retry: manager.getRetrySettings(),
        hideThinkingBlock: manager.getHideThinkingBlock(),
        shellPath: manager.getShellPath(),
        collapseChangelog: manager.getCollapseChangelog(),
        hooks: manager.getHooks(),
        customTools: manager.getCustomTools(),
        skills: manager.getSkillsSettings(),
        terminal: manager.getTerminalSettings(),
        enabledModels: manager.getEnabledModels()
    )
}

private func createLoadedHooksFromDefinitions(_ definitions: [HookDefinition]) -> [LoadedHook] {
    definitions.map { definition in
        let api = HookAPI()
        definition.factory(api)
        let path = definition.path ?? "<inline>"
        return LoadedHook(path: path, resolvedPath: path, handlers: api.handlers)
    }
}

private func customToolsNotImplementedErrors(_ paths: [String]) -> [CustomToolLoadError] {
    paths.map { path in
        CustomToolLoadError(path: path, error: "Custom tool loading is not implemented in Swift yet")
    }
}

public func createAgentSession(_ options: CreateAgentSessionOptions = CreateAgentSessionOptions()) async -> CreateAgentSessionResult {
    let cwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let agentDir = options.agentDir ?? getAgentDir()

    let authStorage = options.authStorage ?? discoverAuthStorage(agentDir: agentDir)
    let modelRegistry = options.modelRegistry ?? discoverModels(authStorage: authStorage, agentDir: agentDir)
    time("discoverModels")

    let settingsManager = options.settingsManager ?? SettingsManager.create(cwd, agentDir)
    time("settingsManager")
    let sessionManager = options.sessionManager ?? SessionManager.create(cwd, nil)
    time("sessionManager")

    let existingSession = sessionManager.buildSessionContext()
    time("loadSession")
    let hasExistingSession = !existingSession.messages.isEmpty

    var model = options.model
    var modelFallbackMessage: String?

    if model == nil, hasExistingSession, let existingModel = existingSession.model {
        if let restored = modelRegistry.find(existingModel.provider, existingModel.modelId),
           await modelRegistry.getApiKey(restored.provider) != nil {
            model = restored
        }
        if model == nil {
            modelFallbackMessage = "Could not restore model \(existingModel.provider)/\(existingModel.modelId)"
        }
    }

    if model == nil {
        if let provider = settingsManager.getDefaultProvider(),
           let modelId = settingsManager.getDefaultModel(),
           let settingsModel = modelRegistry.find(provider, modelId),
           await modelRegistry.getApiKey(settingsModel.provider) != nil {
            model = settingsModel
        }
    }

    if model == nil {
        let available = await modelRegistry.getAvailable()
        for candidate in available {
            if await modelRegistry.getApiKey(candidate.provider) != nil {
                model = candidate
                break
            }
        }
        time("findAvailableModel")

        if model == nil {
            modelFallbackMessage = "No models available. Use /login or set an API key environment variable."
        } else if let existingMessage = modelFallbackMessage {
            modelFallbackMessage = "\(existingMessage). Using \(model!.provider)/\(model!.id)"
        }
    }

    let resolvedModel = model ?? getModel(provider: .openai, modelId: "gpt-4o-mini")

    var thinkingLevel = options.thinkingLevel
    if thinkingLevel == nil, hasExistingSession {
        thinkingLevel = ThinkingLevel(rawValue: existingSession.thinkingLevel) ?? .off
    }
    if thinkingLevel == nil {
        thinkingLevel = ThinkingLevel(rawValue: settingsManager.getDefaultThinkingLevel() ?? "off") ?? .off
    }

    if !resolvedModel.reasoning {
        thinkingLevel = .off
    } else if thinkingLevel == .xhigh && !supportsXhigh(model: resolvedModel) {
        thinkingLevel = .high
    }

    let skills = options.skills ?? discoverSkills(cwd: cwd, agentDir: agentDir, settings: settingsManager.getSkillsSettings())
    time("discoverSkills")

    let contextFiles = options.contextFiles ?? discoverContextFiles(cwd: cwd, agentDir: agentDir)
    time("discoverContextFiles")

    let builtInTools = options.tools ?? createCodingTools(cwd: cwd)
    time("createCodingTools")

    var customToolsResult: CustomToolsLoadResult
    if let customTools = options.customTools {
        let loadedTools = customTools.map { definition in
            LoadedCustomTool(
                path: definition.path ?? "<inline>",
                resolvedPath: definition.path ?? "<inline>",
                tool: definition.tool
            )
        }
        customToolsResult = CustomToolsLoadResult(tools: loadedTools, errors: [])
    } else {
        let configuredPaths = settingsManager.getCustomTools() + (options.additionalCustomToolPaths ?? [])
        let errors = customToolsNotImplementedErrors(configuredPaths)
        customToolsResult = CustomToolsLoadResult(tools: [], errors: errors)
        for error in errors {
            writeStderr("Failed to load custom tool \"\(error.path)\": \(error.error)\n")
        }
    }

    var hookRunner: HookRunner? = nil
    if let hooks = options.hooks {
        if !hooks.isEmpty {
            let loadedHooks = createLoadedHooksFromDefinitions(hooks)
            hookRunner = HookRunner(loadedHooks, cwd, sessionManager, modelRegistry)
        }
    } else {
        let hookPaths = settingsManager.getHooks() + (options.additionalHookPaths ?? [])
        if !hookPaths.isEmpty {
            for path in hookPaths {
                writeStderr("Failed to load hook \"\(path)\": hook loading is not implemented in Swift yet\n")
            }
        }
    }

    let customTools = customToolsResult.tools.map { $0.tool }
    let allTools = builtInTools + customTools
    time("combineTools")

    let defaultPrompt = buildSystemPrompt(BuildSystemPromptOptions(
        cwd: cwd,
        agentDir: agentDir,
        contextFiles: contextFiles,
        skills: skills
    ))
    time("buildSystemPrompt")

    let systemPrompt: String
    if let systemPromptInput = options.systemPrompt {
        switch systemPromptInput {
        case .text(let text):
            systemPrompt = buildSystemPrompt(BuildSystemPromptOptions(
                customPrompt: text,
                cwd: cwd,
                agentDir: agentDir,
                contextFiles: contextFiles,
                skills: skills
            ))
        case .builder(let builder):
            systemPrompt = builder(defaultPrompt)
        }
    } else {
        systemPrompt = defaultPrompt
    }

    let slashCommands = options.slashCommands ?? discoverSlashCommands(cwd: cwd, agentDir: agentDir)
    time("discoverSlashCommands")

    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: systemPrompt,
            model: resolvedModel,
            thinkingLevel: thinkingLevel ?? .off,
            tools: allTools
        ),
        convertToLlm: { messages in
            convertToLlm(messages)
        },
        steeringMode: AgentSteeringMode(rawValue: settingsManager.getSteeringMode()),
        followUpMode: AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()),
        getApiKey: { provider in
            await modelRegistry.getApiKey(provider)
        }
    ))
    time("createAgent")

    if hasExistingSession {
        agent.replaceMessages(existingSession.messages)
    } else {
        sessionManager.appendModelChange(resolvedModel.provider, resolvedModel.id)
        sessionManager.appendThinkingLevelChange((thinkingLevel ?? .off).rawValue)
    }

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        scopedModels: options.scopedModels,
        fileCommands: slashCommands,
        hookRunner: hookRunner,
        modelRegistry: modelRegistry,
        skillsSettings: settingsManager.getSkillsSettings()
    ))
    time("createAgentSession")

    return CreateAgentSessionResult(session: session, customToolsResult: customToolsResult, modelFallbackMessage: modelFallbackMessage)
}
