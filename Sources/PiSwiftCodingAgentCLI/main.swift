import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@main
struct PiCodingAgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pi-coding-agent",
        abstract: "AI coding assistant",
        helpNames: []
    )

    @Argument(parsing: .captureForPassthrough)
    var rawArgs: [String] = []

    mutating func run() async throws {
        time("start")
        let migrationResult = runMigrations()
        let migratedProviders = migrationResult.migratedAuthProviders
        time("runMigrations")

        var parsed = parseArgs(rawArgs)
        time("parseArgs")

        if parsed.help == true {
            printHelp()
            return
        }
        if parsed.version == true {
            print("\(APP_NAME) \(VERSION)")
            return
        }

        let cwd = FileManager.default.currentDirectoryPath
        let authStorage = AuthStorage(getAuthPath())
        let modelRegistry = ModelRegistry(authStorage, getAgentDir())
        time("discoverModels")

        if let listModelsOption = parsed.listModels {
            switch listModelsOption {
            case .all:
                await listModels(modelRegistry, nil)
            case .search(let pattern):
                await listModels(modelRegistry, pattern)
            }
            return
        }

        if let exportPath = parsed.export {
            do {
                let outputPath = parsed.messages.first
                let result = try exportFromFile(exportPath, outputPath)
                print("Exported to: \(result)")
                return
            } catch {
                let message = (error as NSError).localizedDescription
                fputs("Error: \(message)\n", stderr)
                Darwin.exit(1)
            }
        }

        if parsed.mode == .rpc, !parsed.fileArgs.isEmpty {
            fputs("Error: @file arguments are not supported in RPC mode\n", stderr)
            Darwin.exit(1)
        }

        let initialMessageResult = try prepareInitialMessage(&parsed)
        time("prepareInitialMessage")

        let settingsManager = SettingsManager.create(cwd, getAgentDir())
        time("SettingsManager.create")
        let themeName = settingsManager.getTheme()
        initTheme(themeName, enableWatcher: parsed.print != true && parsed.mode == nil)
        time("initTheme")

        var resumeSession: String? = nil
        if parsed.resume == true {
            let sessions = SessionManager.list(cwd, parsed.sessionDir)
            resumeSession = selectSession(sessions)
            if resumeSession == nil {
                print("No session selected")
                return
            }
        }

        let sessionManager = createSessionManager(parsed, cwd: cwd, resumeSession: resumeSession)
        time("createSessionManager")

        var scopedModels: [ScopedModel] = []
        let modelPatterns = parsed.models ?? settingsManager.getEnabledModels()
        if let patterns = modelPatterns, !patterns.isEmpty {
            scopedModels = await resolveModelScope(patterns, modelRegistry)
            time("resolveModelScope")
        }

        let isInteractive = parsed.print != true && parsed.mode == nil
        let mode = parsed.mode ?? .text
        let shouldPrintMessages = isInteractive

        var initialModel = await findInitialModelForSession(parsed, scopedModels, settingsManager, modelRegistry)
        var initialThinking: ThinkingLevel = .off

        if !scopedModels.isEmpty && parsed.continue != true && parsed.resume != true {
            initialThinking = scopedModels[0].thinkingLevel
        } else if let savedThinking = settingsManager.getDefaultThinkingLevel() {
            initialThinking = ThinkingLevel(rawValue: savedThinking) ?? .off
        }

        if !isInteractive && initialModel == nil {
            fputs("No models available.\n", stderr)
            fputs("Set an API key environment variable (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, etc.)\n", stderr)
            fputs("Or create \(getModelsPath())\n", stderr)
            Darwin.exit(1)
        }

        if !isInteractive, let model = initialModel {
            let apiKey: String?
            if let override = parsed.apiKey {
                apiKey = override
            } else {
                apiKey = await authStorage.getApiKey(model.provider)
            }
            if apiKey == nil {
                fputs("No API key found for \(model.provider)\n", stderr)
                Darwin.exit(1)
            }
        }

        var skillsSettings = settingsManager.getSkillsSettings()
        if parsed.noSkills == true {
            skillsSettings.enabled = false
        }
        if let includeSkills = parsed.skills {
            skillsSettings.includeSkills = includeSkills
        }

        let toolMap = createAllTools(cwd: cwd)
        let selectedToolNames = parsed.tools ?? [.read, .bash, .edit, .write]
        let selectedTools = selectedToolNames.compactMap { toolMap[$0] }

        var hookRunner: HookRunner? = nil
        let hookPaths = settingsManager.getHooks() + (parsed.hooks ?? [])
        let hookLoadResult = discoverAndLoadHooks(hookPaths, cwd, getAgentDir())
        time("discoverAndLoadHooks")
        for error in hookLoadResult.errors {
            fputs("Failed to load hook \"\(error.path)\": \(error.error)\n", stderr)
        }
        if !hookLoadResult.hooks.isEmpty {
            let runner = HookRunner(hookLoadResult.hooks, cwd, sessionManager, modelRegistry)
            hookRunner = runner
        }

        let customToolPaths = settingsManager.getCustomTools() + (parsed.customTools ?? [])
        let builtInToolNames = toolMap.keys.map { $0.rawValue }
        let customToolsResult = discoverAndLoadCustomTools(customToolPaths, cwd, builtInToolNames, getAgentDir())
        time("discoverAndLoadCustomTools")
        for error in customToolsResult.errors {
            fputs("Failed to load custom tool \"\(error.path)\": \(error.error)\n", stderr)
        }

        let contextProvider = CustomToolContextProvider(sessionManager: sessionManager, modelRegistry: modelRegistry)
        let wrappedCustomTools = wrapCustomTools(customToolsResult.tools) {
            contextProvider.buildContext()
        }
        var allTools = selectedTools + wrappedCustomTools
        if let hookRunner {
            allTools = wrapToolsWithHooks(allTools, hookRunner)
        }

        let systemPrompt = buildSystemPrompt(BuildSystemPromptOptions(
            customPrompt: parsed.systemPrompt,
            selectedTools: selectedToolNames,
            appendSystemPrompt: parsed.appendSystemPrompt,
            skillsSettings: skillsSettings,
            cwd: cwd,
            agentDir: getAgentDir()
        ))
        time("buildSystemPrompt")

        if parsed.continue == true || parsed.resume == true {
            let context = sessionManager.buildSessionContext()
            if !context.messages.isEmpty {
                initialThinking = ThinkingLevel(rawValue: context.thinkingLevel) ?? initialThinking
                if let modelInfo = context.model {
                    if let restored = modelRegistry.find(modelInfo.provider, modelInfo.modelId) {
                        initialModel = restored
                    } else if shouldPrintMessages {
                        print("Could not restore model \(modelInfo.provider)/\(modelInfo.modelId). Using fallback.")
                    }
                }
            }
        }

        if let cliThinking = parsed.thinking {
            initialThinking = cliThinking
        }

        let fallbackModel = initialModel ?? getModel(provider: .openai, modelId: "gpt-4o-mini")
        let createdAgent = Agent(AgentOptions(
            initialState: AgentState(
                systemPrompt: systemPrompt,
                model: fallbackModel,
                thinkingLevel: initialThinking,
                tools: allTools
            ),
            convertToLlm: { messages in
                convertToLlm(messages)
            },
            steeringMode: AgentSteeringMode(rawValue: settingsManager.getSteeringMode()),
            followUpMode: AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()),
            getApiKey: { provider in
                if let override = parsed.apiKey {
                    return override
                }
                return await authStorage.getApiKey(provider)
            }
        ))
        contextProvider.agent = createdAgent

        if initialThinking != .off && !createdAgent.state.model.reasoning {
            createdAgent.setThinkingLevel(.off)
        } else if initialThinking == .xhigh && !supportsXhigh(model: createdAgent.state.model) {
            createdAgent.setThinkingLevel(.high)
        }

        if parsed.continue == true || parsed.resume == true {
            let context = sessionManager.buildSessionContext()
            if !context.messages.isEmpty {
                createdAgent.replaceMessages(context.messages)
            }
        }

        if shouldPrintMessages && parsed.continue != true && parsed.resume != true {
            let contextFiles = loadProjectContextFiles(LoadContextFilesOptions(cwd: cwd, agentDir: getAgentDir()))
            if !contextFiles.isEmpty {
                print("Loaded project context from:")
                for file in contextFiles {
                    print("  - \(file.path)")
                }
            }
        }

        let fileCommands = loadSlashCommands(LoadSlashCommandsOptions(cwd: cwd, agentDir: getAgentDir()))
        let createdSession = AgentSession(config: AgentSessionConfig(
            agent: createdAgent,
            sessionManager: sessionManager,
            settingsManager: settingsManager,
            scopedModels: scopedModels,
            fileCommands: fileCommands,
            hookRunner: hookRunner,
            customTools: customToolsResult.tools,
            modelRegistry: modelRegistry,
            skillsSettings: skillsSettings
        ))
        contextProvider.session = createdSession

        if mode == .rpc {
            await runRpcMode(createdSession)
            return
        }

        if isInteractive {
            let changelogMarkdown = getChangelogForDisplay(parsed, settingsManager)

            if !migratedProviders.isEmpty {
                let list = migratedProviders.sorted().joined(separator: ", ")
                print("Migrated auth providers: \(list)")
            }

            if !scopedModels.isEmpty {
                let modelList = scopedModels.map { scoped in
                    let thinking = scoped.thinkingLevel == .off ? "" : ":\(scoped.thinkingLevel.rawValue)"
                    return "\(scoped.model.id)\(thinking)"
                }.joined(separator: ", ")
                print("Model scope: \(modelList) (Ctrl+P to cycle)")
            }

            let fdPath = await ensureTool("fd")
            time("ensureTool(fd)")
            printTimings()
            let interactiveMode = await MainActor.run {
                InteractiveMode(
                    session: createdSession,
                    version: VERSION,
                    changelogMarkdown: changelogMarkdown,
                    scopedModels: scopedModels,
                    customTools: customToolsResult.tools,
                    setToolUIContext: customToolsResult.setUIContext,
                    fdPath: fdPath
                )
            }
            await interactiveMode.start(
                initialMessages: parsed.messages,
                initialMessage: initialMessageResult.message,
                initialImages: initialMessageResult.images
            )
        } else {
            try await runPrintMode(
                createdSession,
                mode,
                parsed.messages,
                initialMessageResult.message,
                initialMessageResult.images
            )
        }
    }
}

private struct PreparedInitialMessage {
    var message: String?
    var images: [ImageContent]?
}

private func prepareInitialMessage(_ parsed: inout Args) throws -> PreparedInitialMessage {
    guard !parsed.fileArgs.isEmpty else {
        return PreparedInitialMessage(message: nil, images: nil)
    }

    let processed = try processFileArguments(parsed.fileArgs)
    let textContent = processed.textContent
    if parsed.messages.isEmpty {
        return PreparedInitialMessage(message: textContent, images: processed.imageAttachments.isEmpty ? nil : processed.imageAttachments)
    }

    let first = parsed.messages.removeFirst()
    return PreparedInitialMessage(
        message: textContent + first,
        images: processed.imageAttachments.isEmpty ? nil : processed.imageAttachments
    )
}

private func getChangelogForDisplay(_ parsed: Args, _ settingsManager: SettingsManager) -> String? {
    if parsed.continue == true || parsed.resume == true {
        return nil
    }

    let lastVersion = settingsManager.getLastChangelogVersion()
    let changelogPath = getChangelogPath()
    let entries = parseChangelog(changelogPath)

    if lastVersion == nil {
        if !entries.isEmpty {
            settingsManager.setLastChangelogVersion(VERSION)
            return entries.map { $0.content }.joined(separator: "\n\n")
        }
    } else if let lastVersion {
        let newEntries = getNewEntries(entries, lastVersion: lastVersion)
        if !newEntries.isEmpty {
            settingsManager.setLastChangelogVersion(VERSION)
            return newEntries.map { $0.content }.joined(separator: "\n\n")
        }
    }

    return nil
}

private func createSessionManager(_ parsed: Args, cwd: String, resumeSession: String?) -> SessionManager {
    if parsed.noSession == true {
        return SessionManager.inMemory(cwd)
    }
    if let resumeSession {
        return SessionManager.open(resumeSession, parsed.sessionDir)
    }
    if let session = parsed.session {
        return SessionManager.open(session, parsed.sessionDir)
    }
    if parsed.continue == true {
        return SessionManager.continueRecent(cwd, parsed.sessionDir)
    }
    if let sessionDir = parsed.sessionDir {
        return SessionManager.create(cwd, sessionDir)
    }
    return SessionManager.create(cwd, nil)
}

private func findInitialModelForSession(
    _ parsed: Args,
    _ scopedModels: [ScopedModel],
    _ settingsManager: SettingsManager,
    _ modelRegistry: ModelRegistry
) async -> Model? {
    if let provider = parsed.provider, let modelId = parsed.model {
        if let model = modelRegistry.find(provider, modelId) {
            return model
        }
        fputs("Model \(provider)/\(modelId) not found\n", stderr)
        Darwin.exit(1)
    }

    if !scopedModels.isEmpty && parsed.continue != true && parsed.resume != true {
        return scopedModels[0].model
    }

    if let provider = settingsManager.getDefaultProvider(),
       let modelId = settingsManager.getDefaultModel(),
       let model = modelRegistry.find(provider, modelId) {
        return model
    }

    let available = await modelRegistry.getAvailable()
    return available.first
}

private func runSimpleInteractiveLoop(
    _ session: AgentSession,
    initialMessages: [String],
    initialMessage: String?,
    initialImages: [ImageContent]?
) async throws {
    if let initialMessage {
        try await session.prompt(initialMessage, options: PromptOptions(expandSlashCommands: nil, images: initialImages))
        printAssistantOutput(session)
    }
    for message in initialMessages {
        try await session.prompt(message)
        printAssistantOutput(session)
    }

    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continue
        }
        try await session.prompt(line)
        printAssistantOutput(session)
    }
}

private func printAssistantOutput(_ session: AgentSession) {
    guard let last = session.agent.state.messages.last else { return }
    if case .assistant(let assistant) = last {
        if assistant.stopReason == .error || assistant.stopReason == .aborted {
            let message = assistant.errorMessage ?? "Request \(assistant.stopReason.rawValue)"
            fputs("\(message)\n", stderr)
            return
        }
        for block in assistant.content {
            if case .text(let text) = block {
                print(text.text)
            }
        }
    }
}

private final class CustomToolContextProvider: @unchecked Sendable {
    weak var agent: Agent?
    weak var session: AgentSession?
    private let sessionManager: SessionManager
    private let modelRegistry: ModelRegistry

    init(sessionManager: SessionManager, modelRegistry: ModelRegistry) {
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
    }

    func buildContext() -> CustomToolContext {
        CustomToolContext(
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: agent?.state.model,
            isIdle: { [weak self] in
                !(self?.session?.isStreaming ?? true)
            },
            hasPendingMessages: { [weak self] in
                (self?.session?.pendingMessageCount ?? 0) > 0
            },
            abort: { [weak self] in
                Task { await self?.session?.abort() }
            }
        )
    }
}
