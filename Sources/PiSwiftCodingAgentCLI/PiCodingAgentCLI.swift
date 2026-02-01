import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

@main
struct PiCodingAgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pi-coding-agent",
        abstract: "AI coding assistant",
        discussion: Self.helpDiscussion(),
        version: VERSION
    )

    @OptionGroup var cli: CLIOptions

    mutating func run() async throws {
        time("start")
        let migrationResult = runMigrations()
        let migratedProviders = migrationResult.migratedAuthProviders
        time("runMigrations")

        var parsed = cli.toArgs()
        time("parseArgs")

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

        let settingsManager = SettingsManager.create(cwd, getAgentDir())
        time("SettingsManager.create")
        let themeName = settingsManager.getTheme()
        initTheme(themeName, enableWatcher: parsed.print != true && parsed.mode == nil)
        time("initTheme")

        let initialMessageResult = try prepareInitialMessage(
            &parsed,
            autoResizeImages: settingsManager.getAutoResizeImages(),
            blockImages: settingsManager.getBlockImages()
        )
        time("prepareInitialMessage")

        var resumeSession: String? = nil
        if parsed.resume == true {
            _ = KeybindingsManager.create()
            let sessionDir = parsed.sessionDir
            let cwdValue = cwd
            resumeSession = await selectSession(
                currentSessionsLoader: { onProgress in
                    await SessionManager.list(cwdValue, sessionDir, onProgress)
                },
                allSessionsLoader: { onProgress in
                    await SessionManager.listAll(onProgress)
                }
            )
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

        if let apiKey = parsed.apiKey {
            let apiKeyModel: Model? = {
                if let provider = parsed.provider, let modelId = parsed.model {
                    return modelRegistry.find(provider, modelId)
                }
                if !scopedModels.isEmpty && parsed.continue != true && parsed.resume != true {
                    return scopedModels[0].model
                }
                return nil
            }()

            guard let apiKeyModel else {
                fputs("--api-key requires a model to be specified via --provider/--model or -m/--models\n", stderr)
                Darwin.exit(1)
            }

            authStorage.setRuntimeApiKey(apiKeyModel.provider, apiKey)
        }

        if !isInteractive, let model = initialModel {
            let apiKey = await authStorage.getApiKey(model.provider)
            if apiKey == nil {
                fputs("No API key found for \(model.provider)\n", stderr)
                Darwin.exit(1)
            }
        }

        var skillsSettings = settingsManager.getSkillsSettings()
        if parsed.noSkills == true {
            skillsSettings.enabled = false
        }

        let resourceLoader = DefaultResourceLoader(DefaultResourceLoaderOptions(
            cwd: cwd,
            agentDir: getAgentDir(),
            settingsManager: settingsManager,
            additionalSkillPaths: parsed.skills ?? [],
            noExtensions: parsed.noExtensions ?? false,
            noSkills: parsed.noSkills ?? false,
            systemPrompt: parsed.systemPrompt,
            appendSystemPrompt: parsed.appendSystemPrompt
        ))
        await resourceLoader.reload()
        time("resourceLoader.reload")

        let allBuiltInToolsMap = createAllTools(
            cwd: cwd,
            options: ToolsOptions(read: ReadToolOptions(
                autoResizeImages: settingsManager.getAutoResizeImages(),
                blockImages: settingsManager.getBlockImages()
            ))
        )
        let selectedToolNames: [ToolName]
        if parsed.noTools == true {
            selectedToolNames = parsed.tools ?? []
        } else {
            selectedToolNames = parsed.tools ?? [.read, .bash, .edit, .write]
        }
        let eventBus = createEventBus()

        var hookRunner: HookRunner? = nil
        let baseHookPaths = parsed.noExtensions == true ? [] : settingsManager.getHooks()
        let hookPaths = baseHookPaths + (parsed.hooks ?? [])
        let hookLoadResult = parsed.noExtensions == true
            ? loadHooks(hookPaths, cwd: cwd, eventBus: eventBus)
            : discoverAndLoadHooks(hookPaths, cwd, getAgentDir(), eventBus)
        time("discoverAndLoadHooks")
        for error in hookLoadResult.errors {
            fputs("Failed to load hook \"\(error.path)\": \(error.error)\n", stderr)
        }
        if !hookLoadResult.hooks.isEmpty {
            let runner = HookRunner(hookLoadResult.hooks, cwd, sessionManager, modelRegistry)
            hookRunner = runner
        }

        let baseCustomToolPaths = parsed.noExtensions == true ? [] : settingsManager.getCustomTools()
        let customToolPaths = baseCustomToolPaths + (parsed.customTools ?? [])
        let builtInToolNames = allBuiltInToolsMap.keys.map { $0.rawValue }
        let customToolsResult = parsed.noExtensions == true
            ? loadCustomTools(customToolPaths, cwd, builtInToolNames, eventBus)
            : discoverAndLoadCustomTools(customToolPaths, cwd, builtInToolNames, getAgentDir(), eventBus)
        time("discoverAndLoadCustomTools")
        for error in customToolsResult.errors {
            fputs("Failed to load custom tool \"\(error.path)\": \(error.error)\n", stderr)
        }

        let agentBox = LockedState<Agent?>(nil)
        let sessionBox = LockedState<AgentSession?>(nil)
        let sendMessageHandlerBox = LockedState<HookSendMessageHandler>({ _, _ in })
        let wrappedCustomTools = wrapCustomTools(customToolsResult.tools) {
            let agent = agentBox.withLock { $0 }
            let session = sessionBox.withLock { $0 }
            let handler = sendMessageHandlerBox.withLock { $0 }
            return CustomToolContext(
                sessionManager: sessionManager,
                modelRegistry: modelRegistry,
                model: agent?.state.model,
                isIdle: {
                    !(session?.isStreaming ?? true)
                },
                hasPendingMessages: {
                    (session?.pendingMessageCount ?? 0) > 0
                },
                abort: {
                    Task { await session?.abort() }
                },
                events: eventBus,
                sendMessage: { message, options in
                    handler(message, options)
                }
            )
        }

        let selectedToolNameSet = Set(selectedToolNames.map { $0.rawValue })
        let customToolsByName = Dictionary(uniqueKeysWithValues: wrappedCustomTools.map { ($0.name, $0) })
        let selectedTools = selectedToolNames.compactMap { name in
            customToolsByName[name.rawValue] ?? allBuiltInToolsMap[name]
        }
        let extraCustomTools = wrappedCustomTools.filter { !selectedToolNameSet.contains($0.name) }

        var toolRegistry: [String: AgentTool] = [:]
        for (name, tool) in allBuiltInToolsMap {
            toolRegistry[name.rawValue] = tool
        }
        for tool in wrappedCustomTools {
            toolRegistry[tool.name] = tool
        }

        let initialActiveToolNames = selectedToolNames.map { $0.rawValue } + extraCustomTools.map { $0.name }
        var allTools = selectedTools + extraCustomTools
        if let hookRunner {
            allTools = wrapToolsWithHooks(allTools, hookRunner)
            let registryTools = Array(toolRegistry.values)
            let wrappedRegistry = wrapToolsWithHooks(registryTools, hookRunner)
            toolRegistry = Dictionary(uniqueKeysWithValues: wrappedRegistry.map { ($0.name, $0) })
        }

        let loaderSystemPrompt = resourceLoader.getSystemPrompt()
        let loaderAppend = resourceLoader.getAppendSystemPrompt()
        let appendSystemPrompt = loaderAppend.isEmpty ? nil : loaderAppend.joined(separator: "\n\n")
        let rebuildSystemPrompt: @Sendable ([String]) -> String = { toolNames in
            let validToolNames = toolNames.compactMap { ToolName(rawValue: $0) }
            return buildSystemPrompt(BuildSystemPromptOptions(
                customPrompt: loaderSystemPrompt,
                selectedTools: validToolNames,
                appendSystemPrompt: appendSystemPrompt,
                cwd: cwd,
                agentDir: getAgentDir(),
                contextFiles: resourceLoader.getAgentsFiles(),
                skills: resourceLoader.getSkills().skills
            ))
        }

        let systemPrompt = rebuildSystemPrompt(initialActiveToolNames)
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
        let blockImages = settingsManager.getBlockImages()
        let convertToLlmWithBlockImages: @Sendable ([AgentMessage]) -> [Message] = { messages in
            let converted = convertToLlm(messages)
            guard blockImages else { return converted }
            let filtered = filterImagesFromMessages(converted)
            if filtered.filtered > 0 {
                if let data = "[blockImages] Defense-in-depth: filtered \(filtered.filtered) image(s) at convertToLlm layer\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            }
            return filtered.messages
        }
        let createdAgent = Agent(AgentOptions(
            initialState: AgentState(
                systemPrompt: systemPrompt,
                model: fallbackModel,
                thinkingLevel: initialThinking,
                tools: allTools
            ),
            convertToLlm: { messages in
                convertToLlmWithBlockImages(messages)
            },
            steeringMode: AgentSteeringMode(rawValue: settingsManager.getSteeringMode()),
            followUpMode: AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()),
            sessionId: sessionManager.getSessionId(),
            thinkingBudgets: settingsManager.getThinkingBudgets(),
            getApiKey: { provider in
                return await authStorage.getApiKey(provider)
            }
        ))
        agentBox.withLock { $0 = createdAgent }

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
            let contextFiles = resourceLoader.getAgentsFiles()
            if !contextFiles.isEmpty {
                print("Loaded project context from:")
                for file in contextFiles {
                    print("  - \(file.path)")
                }
            }
        }

        let fileCommands = loadSlashCommands(LoadSlashCommandsOptions(cwd: cwd, agentDir: getAgentDir()))
        let promptTemplates = resourceLoader.getPrompts().prompts
        let createdSession = AgentSession(config: AgentSessionConfig(
            agent: createdAgent,
            sessionManager: sessionManager,
            settingsManager: settingsManager,
            resourceLoader: resourceLoader,
            scopedModels: scopedModels,
            fileCommands: fileCommands,
            promptTemplates: promptTemplates,
            hookRunner: hookRunner,
            customTools: customToolsResult.tools,
            modelRegistry: modelRegistry,
            skillsSettings: skillsSettings,
            eventBus: eventBus,
            toolRegistry: toolRegistry,
            rebuildSystemPrompt: rebuildSystemPrompt
        ))
        sessionBox.withLock { $0 = createdSession }
        let sendMessageHandler: HookSendMessageHandler = { [weak createdSession] message, options in
            guard let session = createdSession else { return }
            Task {
                await session.sendHookMessage(message, options: options)
            }
        }
        customToolsResult.setSendMessageHandler(sendMessageHandler)
        sendMessageHandlerBox.withLock { $0 = sendMessageHandler }

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
                    setToolSendMessageHandler: customToolsResult.setSendMessageHandler,
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

    static func main() async {
        let processed = Self.preprocessArguments(Array(CommandLine.arguments.dropFirst()))
        await self.main(processed)
    }

    private static func helpDiscussion() -> String {
        let toolNames = ToolName.allCases.map { $0.rawValue }.joined(separator: ", ")
        return """
Examples:
  # Interactive mode
  \(APP_NAME)

  # Interactive mode with initial prompt
  \(APP_NAME) "List all .ts files in src/"

  # Include files in initial message
  \(APP_NAME) @prompt.md @image.png "What color is the sky?"

  # Non-interactive mode (process and exit)
  \(APP_NAME) -p "List all .ts files in src/"

  # Continue previous session
  \(APP_NAME) --continue "What did we discuss?"

  # Use different model
  \(APP_NAME) --provider openai --model gpt-4o-mini "Help me refactor this code"

  # Limit model cycling to specific models
  \(APP_NAME) --models claude-sonnet,claude-haiku,gpt-4o

  # Limit to a specific provider with glob pattern
  \(APP_NAME) --models "github-copilot/*"

  # Cycle models with fixed thinking levels
  \(APP_NAME) --models sonnet:high,haiku:low

  # Start with a specific thinking level
  \(APP_NAME) --thinking high "Solve this complex problem"

  # Read-only mode (no file modifications possible)
  \(APP_NAME) --tools read,grep,find,ls -p "Review the code in src/"

  # Export a session file to HTML
  \(APP_NAME) --export ~/\(CONFIG_DIR_NAME)/agent/sessions/--path--/session.jsonl
  \(APP_NAME) --export session.jsonl output.html

Environment Variables:
  ANTHROPIC_API_KEY       - Anthropic Claude API key
  ANTHROPIC_OAUTH_TOKEN   - Anthropic OAuth token (alternative to API key)
  OPENAI_API_KEY          - OpenAI GPT API key
  GEMINI_API_KEY          - Google Gemini API key
  GROQ_API_KEY            - Groq API key
  CEREBRAS_API_KEY        - Cerebras API key
  XAI_API_KEY             - xAI Grok API key
  OPENROUTER_API_KEY      - OpenRouter API key
  ZAI_API_KEY             - ZAI API key
  \(ENV_AGENT_DIR) - Session storage directory (default: ~/\(CONFIG_DIR_NAME)/agent)

Available Tools (default: read, bash, edit, write):
  \(toolNames)
"""
    }

    static func preprocessArguments(_ args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--list-models" {
                result.append(arg)
                if i + 1 < args.count {
                    let next = args[i + 1]
                    if !next.hasPrefix("-") && !next.hasPrefix("@") {
                        result.append("--list-models-search")
                        result.append(next)
                        i += 2
                        continue
                    }
                }
                i += 1
                continue
            }
            if arg.hasPrefix("--list-models=") {
                let value = String(arg.dropFirst("--list-models=".count))
                result.append("--list-models")
                if !value.isEmpty {
                    result.append("--list-models-search")
                    result.append(value)
                }
                i += 1
                continue
            }
            result.append(arg)
            i += 1
        }
        return result
    }
}

private struct PreparedInitialMessage {
    var message: String?
    var images: [ImageContent]?
}

private func prepareInitialMessage(
    _ parsed: inout Args,
    autoResizeImages: Bool,
    blockImages: Bool
) throws -> PreparedInitialMessage {
    guard !parsed.fileArgs.isEmpty else {
        return PreparedInitialMessage(message: nil, images: nil)
    }

    let processed = try processFileArguments(
        parsed.fileArgs,
        options: ProcessFileOptions(autoResizeImages: autoResizeImages, blockImages: blockImages)
    )
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
        settingsManager.setLastChangelogVersion(VERSION)
        return nil
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
