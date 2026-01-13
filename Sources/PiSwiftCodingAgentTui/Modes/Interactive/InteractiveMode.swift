import Foundation
import Dispatch
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import Darwin
import PiSwiftCodingAgent

@MainActor
public protocol RenderRequesting: AnyObject {
    func requestRender()
}

@MainActor
private final class TuiRenderAdapter: RenderRequesting {
    private let tui: TUI

    init(_ tui: TUI) {
        self.tui = tui
    }

    func requestRender() {
        tui.requestRender()
    }
}

@MainActor
private final class NullRenderRequester: RenderRequesting {
    func requestRender() {}
}

@MainActor
private struct InteractiveHookUIContext: HookUIContext {
    private let selectHandler: (String, [String]) async -> String?
    private let confirmHandler: (String, String) async -> Bool
    private let inputHandler: (String, String?) async -> String?
    private let notifyHandler: (String, HookNotificationType?) -> Void
    private let setStatusHandler: (String, String?) -> Void
    private let setWidgetHandler: (String, HookWidgetContent?) -> Void
    private let setTitleHandler: (String) -> Void
    private let customHandler: (@escaping HookCustomFactory) async -> HookCustomResult?
    private let setEditorTextHandler: (String) -> Void
    private let getEditorTextHandler: () -> String
    private let editorHandler: (String, String?) async -> String?
    private let themeProvider: () -> Theme

    init(
        select: @escaping (String, [String]) async -> String?,
        confirm: @escaping (String, String) async -> Bool,
        input: @escaping (String, String?) async -> String?,
        notify: @escaping (String, HookNotificationType?) -> Void,
        setStatus: @escaping (String, String?) -> Void,
        setWidget: @escaping (String, HookWidgetContent?) -> Void,
        setTitle: @escaping (String) -> Void,
        custom: @escaping (@escaping HookCustomFactory) async -> HookCustomResult?,
        setEditorText: @escaping (String) -> Void,
        getEditorText: @escaping () -> String,
        editor: @escaping (String, String?) async -> String?,
        themeProvider: @escaping () -> Theme
    ) {
        self.selectHandler = select
        self.confirmHandler = confirm
        self.inputHandler = input
        self.notifyHandler = notify
        self.setStatusHandler = setStatus
        self.setWidgetHandler = setWidget
        self.setTitleHandler = setTitle
        self.customHandler = custom
        self.setEditorTextHandler = setEditorText
        self.getEditorTextHandler = getEditorText
        self.editorHandler = editor
        self.themeProvider = themeProvider
    }

    func select(_ title: String, _ options: [String]) async -> String? {
        await selectHandler(title, options)
    }

    func confirm(_ title: String, _ message: String) async -> Bool {
        await confirmHandler(title, message)
    }

    func input(_ title: String, _ placeholder: String?) async -> String? {
        await inputHandler(title, placeholder)
    }

    func notify(_ message: String, _ type: HookNotificationType?) {
        notifyHandler(message, type)
    }

    func setStatus(_ key: String, _ text: String?) {
        setStatusHandler(key, text)
    }

    func setWidget(_ key: String, _ content: HookWidgetContent?) {
        setWidgetHandler(key, content)
    }

    func setTitle(_ title: String) {
        setTitleHandler(title)
    }

    func custom(_ factory: @escaping HookCustomFactory) async -> HookCustomResult? {
        await customHandler(factory)
    }

    func setEditorText(_ text: String) {
        setEditorTextHandler(text)
    }

    func getEditorText() -> String {
        getEditorTextHandler()
    }

    func editor(_ title: String, _ prefill: String?) async -> String? {
        await editorHandler(title, prefill)
    }

    var theme: Theme {
        themeProvider()
    }
}

@MainActor
public final class InteractiveMode {
    public var chatContainer: Container
    public var ui: RenderRequesting
    public var lastStatusSpacer: Spacer?
    public var lastStatusText: Text?

    private var session: AgentSession?
    private var tui: TUI?
    private var version: String = VERSION
    private var changelogMarkdown: String?
    private var scopedModels: [ScopedModel] = []
    private var fdPath: String?

    private var pendingMessagesContainer: Container?
    private var statusContainer: Container?
    private var widgetContainer: Container?
    private var editor: CustomEditor?
    private var editorContainer: Container?
    private var footer: FooterComponent?
    private var hookSelector: HookSelectorComponent?
    private var hookInput: HookInputComponent?
    private var hookEditor: HookEditorComponent?
    private var hookWidgets: [String: Component] = [:]
    private var hookWidgetOrder: [String] = []
    private var baseSlashCommands: [SlashCommand] = []
    private var customTools: [String: LoadedCustomTool] = [:]
    private var hookShortcuts: [KeyId: HookShortcut] = [:]
    private var keybindings: KeybindingsManager = KeybindingsManager.inMemory()
    private var selectorCancel: (() -> Void)?
    private var setToolUIContext: (HookUIContext, Bool) -> Void = { _, _ in }
    private var setToolSendMessageHandler: (@Sendable (_ handler: @escaping HookSendMessageHandler) -> Void) = { _ in }

    private var isInitialized = false
    private var loadingAnimation: Loader?
    private var lastSigintTime: TimeInterval = 0
    private var lastEscapeTime: TimeInterval = 0

    private var streamingComponent: AssistantMessageComponent?
    private var streamingMessage: AssistantMessage?
    private var pendingTools: [String: ToolExecutionComponent] = [:]
    private var toolOutputExpanded = false
    private var hideThinkingBlock = false

    private var isBashMode = false
    private var bashComponent: BashExecutionComponent?
    private var bashAbort: CancellationToken?
    private var pendingBashComponents: [BashExecutionComponent] = []
    private var pendingBashMessages: [BashExecutionMessage] = []

    private var pendingSteeringMessages: [String] = []
    private var pendingFollowUpMessages: [String] = []

    private static let maxWidgetLines = 10

    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var unsubscribe: (() -> Void)?
    private var sigcontSource: DispatchSourceSignal?

    public init(chatContainer: Container = Container(), ui: RenderRequesting) {
        self.chatContainer = chatContainer
        self.ui = ui
    }

    public convenience init(
        session: AgentSession,
        version: String,
        changelogMarkdown: String? = nil,
        scopedModels: [ScopedModel] = [],
        customTools: [LoadedCustomTool] = [],
        setToolUIContext: @escaping (HookUIContext, Bool) -> Void = { _, _ in },
        setToolSendMessageHandler: @escaping @Sendable (_ handler: @escaping HookSendMessageHandler) -> Void = { _ in },
        fdPath: String? = nil
    ) {
        self.init(chatContainer: Container(), ui: NullRenderRequester())
        self.session = session
        self.version = version
        self.changelogMarkdown = changelogMarkdown
        self.scopedModels = scopedModels
        self.customTools = Dictionary(uniqueKeysWithValues: customTools.map { ($0.tool.name, $0) })
        self.setToolUIContext = setToolUIContext
        self.setToolSendMessageHandler = setToolSendMessageHandler
        self.fdPath = fdPath
    }

    public func start(
        initialMessages: [String] = [],
        initialMessage: String? = nil,
        initialImages: [ImageContent]? = nil
    ) async {
        await initializeIfNeeded()
        renderInitialMessages()

        if let initialMessage {
            await prompt(initialMessage, images: initialImages)
        }
        for message in initialMessages {
            await prompt(message, images: nil)
        }

        await withCheckedContinuation { continuation in
            self.exitContinuation = continuation
        }
    }

    private func initializeIfNeeded() async {
        guard !isInitialized, let session else { return }

        keybindings = KeybindingsManager.create()

        if tui == nil {
            let created = TUI(terminal: ProcessTerminal())
            tui = created
            ui = TuiRenderAdapter(created)
        }
        guard let tui else { return }

        tui.onGlobalInput = { [weak self] data in
            guard let self else { return false }
            if self.keybindings.matches(data, .suspend) {
                self.handleCtrlZ()
                return true
            }
            if self.keybindings.matches(data, .clear) {
                if let selectorCancel = self.selectorCancel {
                    selectorCancel()
                } else {
                    self.handleCtrlC()
                }
                return true
            }
            return false
        }

        let settingsManager = session.settingsManager
        hideThinkingBlock = settingsManager.getHideThinkingBlock()

        initTheme(settingsManager.getTheme(), enableWatcher: true)

        let header = buildHeaderText()
        let pendingMessages = Container()
        let status = Container()
        let widgets = Container()
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: keybindings)
        let editorContainer = Container()
        let footer = FooterComponent(session: session)

        editorContainer.addChild(editor)

        pendingMessagesContainer = pendingMessages
        statusContainer = status
        widgetContainer = widgets
        self.editor = editor
        self.editorContainer = editorContainer
        self.footer = footer

        let slashCommands: [SlashCommand] = [
            SlashCommand(name: "settings", description: "Open settings menu"),
            SlashCommand(name: "model", description: "Select model"),
            SlashCommand(name: "theme", description: "Select theme"),
            SlashCommand(name: "login", description: "Login with OAuth provider"),
            SlashCommand(name: "logout", description: "Logout from OAuth provider"),
            SlashCommand(name: "templates", description: "List prompt templates"),
            SlashCommand(name: "export", description: "Export session to HTML"),
            SlashCommand(name: "copy", description: "Copy last assistant message"),
            SlashCommand(name: "session", description: "Show session info"),
            SlashCommand(name: "changelog", description: "Show changelog"),
            SlashCommand(name: "hotkeys", description: "Show shortcuts"),
            SlashCommand(name: "debug", description: "Show theme diagnostics"),
            SlashCommand(name: "branch", description: "Branch from a user message"),
            SlashCommand(name: "tree", description: "Navigate session tree"),
            SlashCommand(name: "new", description: "Start a new session"),
            SlashCommand(name: "compact", description: "Compact session"),
            SlashCommand(name: "resume", description: "Resume a session"),
            SlashCommand(name: "quit", description: "Exit the agent"),
            SlashCommand(name: "exit", description: "Exit the agent"),
        ]

        baseSlashCommands = slashCommands
        let templateCommands = session.promptTemplates.map { template in
            SlashCommand(name: template.name, description: template.description)
        }
        setAutocompleteCommands(slashCommands + templateCommands)

        tui.addChild(Spacer(1))
        tui.addChild(Text(header, paddingX: 1, paddingY: 0))
        tui.addChild(Spacer(1))

        if let changelogMarkdown, !changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tui.addChild(DynamicBorder())
            if settingsManager.getCollapseChangelog() {
                let condensed = "Updated. Use /changelog to view details."
                tui.addChild(Text(condensed, paddingX: 1, paddingY: 0))
            } else {
                tui.addChild(Text(theme.bold(theme.fg(.accent, "What's New")), paddingX: 1, paddingY: 0))
                tui.addChild(Spacer(1))
                tui.addChild(Markdown(changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines), paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
                tui.addChild(Spacer(1))
            }
            tui.addChild(DynamicBorder())
        }

        tui.addChild(chatContainer)
        tui.addChild(pendingMessages)
        tui.addChild(status)
        tui.addChild(widgets)
        tui.addChild(Spacer(1))
        tui.addChild(editorContainer)
        tui.addChild(footer)
        tui.setFocus(editor)
        tui.start()

        await initializeHooksAndCustomTools()
        configureKeyHandlers()
        subscribeToAgent()

        onThemeChange { [weak self] in
            Task { @MainActor in
                self?.updateEditorBorderColor()
                self?.tui?.invalidate()
                self?.tui?.requestRender()
            }
        }

        if let cwdBase = FileManager.default.currentDirectoryPath.split(separator: "/").last {
            tui.terminal.setTitle("pi - \(cwdBase)")
        }

        isInitialized = true
    }

    @MainActor
    private func setAutocompleteCommands(_ commands: [SlashCommand]) {
        guard let editor else { return }
        let autocompleteProvider = CombinedAutocompleteProvider(
            commands: commands,
            items: [],
            basePath: FileManager.default.currentDirectoryPath,
            fdPath: fdPath
        )
        editor.setAutocompleteProvider(autocompleteProvider)
    }

    @MainActor
    private func initializeHooksAndCustomTools() async {
        guard let session else { return }

        let uiContext = InteractiveHookUIContext(
            select: { [weak self] title, options in
                guard let self else { return nil }
                return await self.showHookSelector(title, options)
            },
            confirm: { [weak self] title, message in
                guard let self else { return false }
                return await self.showHookConfirm(title, message)
            },
            input: { [weak self] title, placeholder in
                guard let self else { return nil }
                return await self.showHookInput(title, placeholder)
            },
            notify: { [weak self] message, type in
                Task { @MainActor in
                    self?.showHookNotify(message, type)
                }
            },
            setStatus: { [weak self] key, text in
                Task { @MainActor in
                    self?.setHookStatus(key, text)
                }
            },
            setWidget: { [weak self] key, content in
                Task { @MainActor in
                    self?.setHookWidget(key, content)
                }
            },
            setTitle: { [weak self] title in
                Task { @MainActor in
                    self?.tui?.terminal.setTitle(title)
                }
            },
            custom: { [weak self] factory in
                guard let self else { return nil }
                return await self.showHookCustom(factory)
            },
            setEditorText: { [weak self] text in
                Task { @MainActor in
                    self?.editor?.setText(text)
                }
            },
            getEditorText: { [weak self] in
                guard let self else { return "" }
                return self.editor?.getText() ?? ""
            },
            editor: { [weak self] title, prefill in
                guard let self else { return nil }
                return await self.showHookEditor(title, prefill)
            },
            themeProvider: { theme }
        )

        if !customTools.isEmpty {
            let list = customTools.values.map { tool in
                theme.fg(.dim, "  \(tool.tool.name) (\(tool.path))")
            }.joined(separator: "\n")
            chatContainer.addChild(Text(theme.fg(.muted, "Loaded custom tools:\n") + list, paddingX: 0, paddingY: 0))
            chatContainer.addChild(Spacer(1))
            scheduleRender()
        }

        setToolUIContext(uiContext, true)
        setToolSendMessageHandler { [weak session, weak self] message, options in
            guard let session else { return }
            let shouldRefresh = !session.isStreaming
                && options?.triggerTurn != true
                && options?.deliverAs != .nextTurn
                && message.display
            Task {
                await session.sendHookMessage(message, options: options)
                if shouldRefresh {
                    Task { @MainActor [weak self] in
                        self?.renderInitialMessages()
                    }
                }
            }
        }
        await session.emitCustomToolSessionEvent(.start, previousSessionFile: nil)

        guard let hookRunner = session.hookRunner else { return }

        hookRunner.initialize(
            getModel: { [weak session] in session?.agent.state.model },
            sendMessageHandler: { [weak session, weak self] message, options in
                guard let session else { return }
                let shouldRefresh = !session.isStreaming
                    && options?.triggerTurn != true
                    && options?.deliverAs != .nextTurn
                    && message.display
                Task {
                    await session.sendHookMessage(message, options: options)
                    if shouldRefresh {
                        Task { @MainActor [weak self] in
                            self?.renderInitialMessages()
                        }
                    }
                }
            },
            appendEntryHandler: { [weak session] customType, data in
                session?.sessionManager.appendCustomEntry(customType, data)
            },
            getActiveToolsHandler: { [weak session] in
                session?.getActiveToolNames() ?? []
            },
            getAllToolsHandler: { [weak session] in
                session?.getAllToolNames() ?? []
            },
            setActiveToolsHandler: { [weak session] toolNames in
                session?.setActiveToolsByName(toolNames)
            },
            newSessionHandler: { [weak self] options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookNewSession(options)
            },
            branchHandler: { [weak self] entryId in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookBranch(entryId)
            },
            navigateTreeHandler: { [weak self] targetId, options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookNavigateTree(targetId, options: options)
            },
            isIdle: { [weak session] in
                !(session?.isStreaming ?? true)
            },
            waitForIdle: { [weak session] in
                await session?.agent.waitForIdle()
            },
            abort: { [weak session] in
                Task {
                    await session?.abort()
                }
            },
            hasPendingMessages: { [weak session] in
                (session?.pendingMessageCount ?? 0) > 0
            },
            uiContext: uiContext,
            hasUI: true
        )

        _ = hookRunner.onError { [weak self] error in
            Task { @MainActor in
                self?.showHookError(error.hookPath, error.error, error.stack)
            }
        }

        setupHookShortcuts(hookRunner)

        _ = await hookRunner.emit(SessionStartEvent())

        let templateCommands = session.promptTemplates.map { template in
            SlashCommand(name: template.name, description: template.description)
        }
        let hookCommands = hookRunner.getRegisteredCommands().map { command in
            SlashCommand(name: command.name, description: command.description ?? "(hook command)")
        }
        setAutocompleteCommands(baseSlashCommands + templateCommands + hookCommands)

        let hookPaths = hookRunner.getHookPaths()
        if !hookPaths.isEmpty {
            let list = hookPaths.map { theme.fg(.dim, "  \($0)") }.joined(separator: "\n")
            chatContainer.addChild(Text(theme.fg(.muted, "Loaded hooks:\n") + list, paddingX: 0, paddingY: 0))
            chatContainer.addChild(Spacer(1))
            scheduleRender()
        }
    }

    @MainActor
    private func handleHookNewSession(_ options: HookNewSessionOptions?) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }

        loadingAnimation?.stop()
        loadingAnimation = nil
        statusContainer?.clear()

        _ = session.sessionManager.newSession(NewSessionOptions(parentSession: options?.parentSession))
        session.agent.replaceMessages([])

        if let setup = options?.setup {
            await setup(session.sessionManager)
        }

        chatContainer.clear()
        pendingMessagesContainer?.clear()
        streamingComponent = nil
        streamingMessage = nil
        pendingTools.removeAll()

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.fg(.accent, "✓ New session started"), paddingX: 1, paddingY: 0))
        scheduleRender()

        return HookCommandResult(cancelled: false)
    }

    @MainActor
    private func handleHookBranch(_ entryId: String) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }

        do {
            let result = try await session.branch(entryId)
            if result.cancelled {
                return HookCommandResult(cancelled: true)
            }

            chatContainer.clear()
            renderInitialMessages()
            editor?.setText(result.selectedText)
            showStatus("Branched to new session")
            return HookCommandResult(cancelled: false)
        } catch {
            showHookError("branch", error.localizedDescription)
            return HookCommandResult(cancelled: true)
        }
    }

    @MainActor
    private func handleHookNavigateTree(_ targetId: String, options: HookNavigateTreeOptions?) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }

        let result = await session.navigateTree(targetId, summarize: options?.summarize ?? false)
        if result.cancelled {
            return HookCommandResult(cancelled: true)
        }

        chatContainer.clear()
        renderInitialMessages()
        if let editorText = result.editorText {
            editor?.setText(editorText)
        }
        showStatus("Navigated to selected point")
        return HookCommandResult(cancelled: false)
    }

    @MainActor
    private func showHookSelector(_ title: String, _ options: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            showSelector { done in
                let selector = HookSelectorComponent(
                    title: title,
                    options: options,
                    onSelect: { [weak self] option in
                        self?.hookSelector = nil
                        done()
                        continuation.resume(returning: option)
                    },
                    onCancel: { [weak self] in
                        self?.hookSelector = nil
                        done()
                        continuation.resume(returning: nil)
                    }
                )
                self.hookSelector = selector
                return (component: selector, focus: selector)
            }
        }
    }

    @MainActor
    private func showHookConfirm(_ title: String, _ message: String) async -> Bool {
        let choice = await showHookSelector("\(title)\n\(message)", ["Yes", "No"])
        return choice == "Yes"
    }

    @MainActor
    private func showHookInput(_ title: String, _ placeholder: String?) async -> String? {
        await withCheckedContinuation { continuation in
            showSelector { done in
                let input = HookInputComponent(
                    title: title,
                    placeholder: placeholder,
                    onSubmit: { [weak self] value in
                        self?.hookInput = nil
                        done()
                        continuation.resume(returning: value)
                    },
                    onCancel: { [weak self] in
                        self?.hookInput = nil
                        done()
                        continuation.resume(returning: nil)
                    }
                )
                self.hookInput = input
                return (component: input, focus: input)
            }
        }
    }

    @MainActor
    private func showHookEditor(_ title: String, _ prefill: String?) async -> String? {
        await withCheckedContinuation { continuation in
            guard let tui else {
                continuation.resume(returning: nil)
                return
            }
            showSelector { done in
                let editor = HookEditorComponent(
                    tui: tui,
                    title: title,
                    prefill: prefill,
                    onSubmit: { [weak self] value in
                        self?.hookEditor = nil
                        done()
                        continuation.resume(returning: value)
                    },
                    onCancel: { [weak self] in
                        self?.hookEditor = nil
                        done()
                        continuation.resume(returning: nil)
                    }
                )
                self.hookEditor = editor
                return (component: editor, focus: editor)
            }
        }
    }

    @MainActor
    private func showHookCustom(_ factory: @escaping HookCustomFactory) async -> HookCustomResult? {
        guard let tui, let editor, let editorContainer else { return nil }
        let savedText = editor.getText()

        return await withCheckedContinuation { continuation in
            var component: Component?

            let close: HookCustomClose = { result in
                if let disposable = component as? HookDisposableComponent {
                    disposable.dispose()
                }
                editorContainer.clear()
                editorContainer.addChild(editor)
                editor.setText(savedText)
                tui.setFocus(editor)
                tui.requestRender()
                continuation.resume(returning: result.map(HookCustomResult.init))
            }

            Task { @MainActor in
                let created = await factory(tui, theme, close)
                if let createdComponent = created as? Component {
                    component = createdComponent
                    editorContainer.clear()
                    editorContainer.addChild(createdComponent)
                    tui.setFocus(createdComponent)
                    tui.requestRender()
                }
            }
        }
    }

    @MainActor
    private func showHookNotify(_ message: String, _ type: HookNotificationType?) {
        switch type {
        case .error:
            showError(message)
        case .warning:
            showWarning(message)
        case .info, .none:
            showStatus(message)
        }
    }

    @MainActor
    private func setHookStatus(_ key: String, _ text: String?) {
        footer?.setHookStatus(key, text)
        scheduleRender()
    }

    @MainActor
    private func setupHookShortcuts(_ hookRunner: HookRunner) {
        hookShortcuts = hookRunner.getShortcuts()
        guard let editor else { return }
        if hookShortcuts.isEmpty {
            editor.onHookShortcut = nil
            return
        }
        editor.onHookShortcut = { [weak self, weak hookRunner] data in
            guard let self, let hookRunner else { return false }
            for (key, shortcut) in self.hookShortcuts {
                if matchesKey(data, key) {
                    Task { @MainActor in
                        let context = hookRunner.createShortcutContext()
                        await shortcut.handler(context)
                    }
                    return true
                }
            }
            return false
        }
    }

    @MainActor
    private func setHookWidget(_ key: String, _ content: HookWidgetContent?) {
        if let existing = hookWidgets[key] {
            if let disposable = existing as? HookDisposableComponent {
                disposable.dispose()
            }
        }

        if content == nil {
            hookWidgets.removeValue(forKey: key)
            hookWidgetOrder.removeAll { $0 == key }
            renderWidgets()
            return
        }

        guard let tui else { return }

        if hookWidgets[key] == nil {
            hookWidgetOrder.append(key)
        }

        switch content {
        case .lines(let lines):
            let container = Container()
            let limitedLines = Array(lines.prefix(Self.maxWidgetLines))
            for line in limitedLines {
                container.addChild(Text(line, paddingX: 1, paddingY: 0))
            }
            if lines.count > Self.maxWidgetLines {
                container.addChild(Text(theme.fg(.muted, "... (widget truncated)"), paddingX: 1, paddingY: 0))
            }
            hookWidgets[key] = container
        case .component(let factory):
            if let component = factory(tui, theme) as? Component {
                hookWidgets[key] = component
            }
        case .none:
            break
        }

        renderWidgets()
    }

    @MainActor
    private func renderWidgets() {
        guard let widgetContainer else { return }
        widgetContainer.clear()

        for key in hookWidgetOrder {
            if let component = hookWidgets[key] {
                widgetContainer.addChild(component)
            }
        }

        scheduleRender()
    }

    @MainActor
    private func showHookError(_ hookPath: String, _ error: String, _ stack: String? = nil) {
        let errorText = Text(theme.fg(.error, "Hook \"\(hookPath)\" error: \(error)"), paddingX: 1, paddingY: 0)
        chatContainer.addChild(errorText)
        if let stack, !stack.isEmpty {
            let lines = stack.split(separator: "\n").dropFirst()
            if !lines.isEmpty {
                let formatted = lines.map { theme.fg(.dim, "  \($0.trimmingCharacters(in: .whitespaces))") }.joined(separator: "\n")
                chatContainer.addChild(Text(formatted, paddingX: 1, paddingY: 0))
            }
        }
        scheduleRender()
    }

    @MainActor
    private func configureKeyHandlers() {
        guard let editor else { return }

        editor.onEscape = { [weak self] in
            self?.handleEscape()
        }
        editor.onCtrlD = { [weak self] in
            self?.handleCtrlD()
        }
        editor.onAction(.clear) { [weak self] in
            self?.handleCtrlC()
        }
        editor.onAction(.suspend) { [weak self] in
            self?.handleCtrlZ()
        }
        editor.onAction(.cycleThinkingLevel) { [weak self] in
            self?.cycleThinkingLevel()
        }
        editor.onAction(.cycleModelForward) { [weak self] in
            Task { @MainActor in
                await self?.cycleModel(direction: .forward)
            }
        }
        editor.onAction(.cycleModelBackward) { [weak self] in
            Task { @MainActor in
                await self?.cycleModel(direction: .backward)
            }
        }
        editor.onAction(.selectModel) { [weak self] in
            Task { @MainActor in
                self?.showModelSelector()
            }
        }
        editor.onAction(.expandTools) { [weak self] in
            Task { @MainActor in
                self?.toggleToolOutputExpansion()
            }
        }
        editor.onAction(.toggleThinking) { [weak self] in
            Task { @MainActor in
                self?.toggleThinkingBlockVisibility()
            }
        }
        editor.onAction(.externalEditor) { [weak self] in
            Task { await self?.openExternalEditor() }
        }
        editor.onAction(.followUp) { [weak self] in
            Task { @MainActor in
                await self?.handleAltEnter()
            }
        }
        editor.onAction(.dequeue) { [weak self] in
            Task { @MainActor in
                self?.handleDequeue()
            }
        }

        editor.onChange = { [weak self] text in
            guard let self else { return }
            let wasBash = self.isBashMode
            self.isBashMode = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!")
            if wasBash != self.isBashMode {
                Task { @MainActor in
                    self.updateEditorBorderColor()
                }
            }
        }

        editor.onPasteImage = { [weak self] in
            Task { @MainActor in
                self?.handleClipboardImagePaste()
            }
        }

        editor.onSubmit = { [weak self] text in
            Task { @MainActor in
                await self?.handleEditorSubmit(text)
            }
        }

        tui?.onDebug = { [weak self] in
            Task { @MainActor in
                self?.handleDebugCommand()
            }
        }

        Task { @MainActor in
            self.updateEditorBorderColor()
        }
    }

    private func subscribeToAgent() {
        guard let session else { return }
        unsubscribe = session.subscribe { [weak self] event in
            Task { @MainActor in
                self?.handleSessionEvent(event)
            }
        }
    }

    @MainActor
    private func handleSessionEvent(_ event: AgentSessionEvent) {
        footer?.invalidate()

        switch event {
        case .agent(let agentEvent):
            handleAgentEvent(agentEvent)
        case .autoCompactionStart:
            showStatus("Auto-compaction started")
        case .autoCompactionEnd(let result, let aborted, _):
            if aborted {
                showStatus("Auto-compaction cancelled")
            } else if let result {
                chatContainer.clear()
                renderInitialMessages()
                let compactionMessage = CompactionSummaryMessage(summary: result.summary, tokensBefore: result.tokensBefore, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
                let component = CompactionSummaryMessageComponent(message: compactionMessage)
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                showStatus("Compaction completed")
            }
        case .autoRetryStart(let attempt, let maxAttempts, _, let errorMessage):
            showStatus("Retrying (\(attempt)/\(maxAttempts)): \(errorMessage)")
        case .autoRetryEnd(let success, let attempt, let finalError):
            if !success {
                showError("Retry failed after \(attempt) attempts: \(finalError ?? "Unknown error")")
            }
        }
    }

    @MainActor
    private func handleAgentEvent(_ event: AgentEvent) {
        guard let session, let statusContainer, let tui else { return }

        switch event {
        case .agentStart:
            loadingAnimation?.stop()
            statusContainer.clear()
            let loader = Loader(
                ui: tui,
                spinnerColorFn: { theme.fg(.accent, $0) },
                messageColorFn: { theme.fg(.muted, $0) },
                message: "Working... (esc to interrupt)"
            )
            loadingAnimation = loader
            statusContainer.addChild(loader)
            scheduleRender()

        case .messageStart(let message):
            if message.role == "user" {
                let text = extractUserMessageText(message)
                if let idx = pendingSteeringMessages.firstIndex(of: text) {
                    pendingSteeringMessages.remove(at: idx)
                } else if let idx = pendingFollowUpMessages.firstIndex(of: text) {
                    pendingFollowUpMessages.remove(at: idx)
                }
                addMessageToChat(message)
                editor?.setText("")
                updatePendingMessagesDisplay()
                scheduleRender()
            } else if case .assistant(let assistant) = message {
                streamingComponent = AssistantMessageComponent(hideThinkingBlock: hideThinkingBlock)
                streamingMessage = assistant
                if let streamingComponent {
                    chatContainer.addChild(streamingComponent)
                    streamingComponent.updateContent(assistant)
                }
                scheduleRender()
            } else if message.role == "hookMessage" {
                addMessageToChat(message)
                scheduleRender()
            }

        case .messageUpdate(let message, _):
            if case .assistant(let assistant) = message {
                streamingMessage = assistant
                streamingComponent?.updateContent(assistant)
                for block in assistant.content {
                    if case .toolCall(let call) = block {
                        if pendingTools[call.id] == nil {
                            let component = ToolExecutionComponent(
                                toolName: call.name,
                                args: call.arguments,
                                options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages()),
                                customTool: customTools[call.name]?.tool,
                                ui: tui
                            )
                            component.setExpanded(toolOutputExpanded)
                            chatContainer.addChild(component)
                            pendingTools[call.id] = component
                        } else {
                            pendingTools[call.id]?.updateArgs(call.arguments)
                        }
                    }
                }
                scheduleRender()
            }

        case .messageEnd(let message):
            if case .assistant(let assistant) = message {
                streamingComponent?.updateContent(assistant)
                if assistant.stopReason == .aborted || assistant.stopReason == .error {
                    let errorMessage = assistant.errorMessage ?? "Request failed"
                    for component in pendingTools.values {
                        let result = ToolResultMessage(toolCallId: "", toolName: "", content: [.text(TextContent(text: errorMessage))], details: nil, isError: true)
                        component.updateResult(result, isPartial: false)
                    }
                    pendingTools.removeAll()
                } else {
                    for component in pendingTools.values {
                        component.setArgsComplete()
                    }
                }
                streamingComponent = nil
                streamingMessage = nil
            }
            scheduleRender()

        case .toolExecutionStart(let toolCallId, let toolName, let args):
            if pendingTools[toolCallId] == nil {
                let component = ToolExecutionComponent(
                    toolName: toolName,
                    args: args,
                    options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages()),
                    customTool: customTools[toolName]?.tool,
                    ui: tui
                )
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                pendingTools[toolCallId] = component
                scheduleRender()
            }

        case .toolExecutionUpdate(let toolCallId, let toolName, _, let partialResult):
            if let component = pendingTools[toolCallId] {
                let result = ToolResultMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    content: partialResult.content,
                    details: partialResult.details,
                    isError: false
                )
                component.updateResult(result, isPartial: true)
                scheduleRender()
            }

        case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError):
            if let component = pendingTools[toolCallId] {
                let message = ToolResultMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    content: result.content,
                    details: result.details,
                    isError: isError
                )
                component.updateResult(message, isPartial: false)
                pendingTools.removeValue(forKey: toolCallId)
                scheduleRender()
            }

        case .agentEnd:
            loadingAnimation?.stop()
            loadingAnimation = nil
            statusContainer.clear()
            if let streamingComponent {
                chatContainer.removeChild(streamingComponent)
                self.streamingComponent = nil
                streamingMessage = nil
            }
            pendingTools.removeAll()
            scheduleRender()

        case .turnStart, .turnEnd:
            break
        }
    }

    @MainActor
    private func renderInitialMessages() {
        guard let session, let tui else { return }
        chatContainer.clear()
        pendingTools.removeAll()
        var toolCalls: [String: (name: String, args: [String: AnyCodable])] = [:]

        let context = session.sessionManager.buildSessionContext()
        for message in context.messages {
            switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    if case .toolCall(let call) = block {
                        toolCalls[call.id] = (name: call.name, args: call.arguments)
                    }
                }
                addMessageToChat(message)
            case .toolResult(let toolResult):
                let toolInfo = toolCalls[toolResult.toolCallId]
                let component = ToolExecutionComponent(
                    toolName: toolInfo?.name ?? toolResult.toolName,
                    args: toolInfo?.args ?? [:],
                    options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages()),
                    customTool: customTools[toolInfo?.name ?? toolResult.toolName]?.tool,
                    ui: tui
                )
                component.setExpanded(toolOutputExpanded)
                component.updateResult(toolResult, isPartial: false)
                chatContainer.addChild(component)
            default:
                addMessageToChat(message)
            }
        }

        let compactionCount = session.sessionManager.getEntries().filter { if case .compaction = $0 { return true } else { return false } }.count
        if compactionCount > 0 {
            let times = compactionCount == 1 ? "1 time" : "\(compactionCount) times"
            showStatus("Session compacted \(times)")
        }

        scheduleRender()
    }

    @MainActor
    private func addMessageToChat(_ message: AgentMessage) {
        switch message {
        case .user(let user):
            let text = extractUserContentText(user.content)
            chatContainer.addChild(UserMessageComponent(text: text))
        case .assistant(let assistant):
            let component = AssistantMessageComponent(message: assistant, hideThinkingBlock: hideThinkingBlock)
            chatContainer.addChild(component)
        case .toolResult:
            break
        case .custom(let custom):
            switch custom.role {
            case "bashExecution":
                if let bash = decodeBashExecutionMessage(custom) {
                    if let tui {
                        let component = BashExecutionComponent(command: bash.command, ui: tui)
                        component.appendOutput(bash.output)
                        let truncation = bash.truncated ? truncateTail(bash.output) : nil
                        component.setComplete(exitCode: bash.exitCode, cancelled: bash.cancelled, truncationResult: truncation, fullOutputPath: bash.fullOutputPath)
                        component.setExpanded(toolOutputExpanded)
                        chatContainer.addChild(component)
                    }
                }
            case "branchSummary":
                if let summary = decodeBranchSummaryMessage(custom) {
                    let component = BranchSummaryMessageComponent(message: summary)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            case "compactionSummary":
                if let summary = decodeCompactionSummaryMessage(custom) {
                    let component = CompactionSummaryMessageComponent(message: summary)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            case "hookMessage":
                if let hook = decodeHookMessage(custom), hook.display {
                    let renderer = session?.hookRunner?.getMessageRenderer(hook.customType)
                    let component = HookMessageComponent(message: hook, customRenderer: renderer)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            default:
                break
            }
        }
    }

    private func scheduleRender(force: Bool = false) {
        if let tui {
            tui.requestRender(force: force)
        } else {
            ui.requestRender()
        }
    }

    private func buildHeaderText() -> String {
        let logo = theme.bold(theme.fg(.accent, APP_NAME)) + theme.fg(.dim, " v\(version)")
        let deleteToLineEnd = formatKeyDisplay(getEditorKeybindings().getKeys(.deleteToLineEnd))
        let interrupt = formatKeyDisplay(keybindings.getDisplayString(.interrupt))
        let clear = formatKeyDisplay(keybindings.getDisplayString(.clear))
        let exit = formatKeyDisplay(keybindings.getDisplayString(.exit))
        let suspend = formatKeyDisplay(keybindings.getDisplayString(.suspend))
        let cycleThinkingLevel = formatKeyDisplay(keybindings.getDisplayString(.cycleThinkingLevel))
        let cycleModelForward = formatKeyDisplay(keybindings.getDisplayString(.cycleModelForward))
        let cycleModelBackward = formatKeyDisplay(keybindings.getDisplayString(.cycleModelBackward))
        let selectModel = formatKeyDisplay(keybindings.getDisplayString(.selectModel))
        let expandTools = formatKeyDisplay(keybindings.getDisplayString(.expandTools))
        let toggleThinking = formatKeyDisplay(keybindings.getDisplayString(.toggleThinking))
        let externalEditor = formatKeyDisplay(keybindings.getDisplayString(.externalEditor))
        let followUp = formatKeyDisplay(keybindings.getDisplayString(.followUp))
        let dequeue = formatKeyDisplay(keybindings.getDisplayString(.dequeue))
        let instructions = [
            theme.fg(.dim, interrupt) + theme.fg(.muted, " to interrupt"),
            theme.fg(.dim, clear) + theme.fg(.muted, " to clear"),
            theme.fg(.dim, "\(clear) twice") + theme.fg(.muted, " to exit"),
            theme.fg(.dim, exit) + theme.fg(.muted, " to exit (empty)"),
            theme.fg(.dim, suspend) + theme.fg(.muted, " to suspend"),
            theme.fg(.dim, deleteToLineEnd) + theme.fg(.muted, " to delete line"),
            theme.fg(.dim, cycleThinkingLevel) + theme.fg(.muted, " to cycle thinking"),
            theme.fg(.dim, "\(cycleModelForward)/\(cycleModelBackward)") + theme.fg(.muted, " to cycle models"),
            theme.fg(.dim, selectModel) + theme.fg(.muted, " to select model"),
            theme.fg(.dim, expandTools) + theme.fg(.muted, " to expand tools"),
            theme.fg(.dim, toggleThinking) + theme.fg(.muted, " to toggle thinking"),
            theme.fg(.dim, externalEditor) + theme.fg(.muted, " for external editor"),
            theme.fg(.dim, "/") + theme.fg(.muted, " for commands"),
            theme.fg(.dim, "!") + theme.fg(.muted, " to run bash"),
            theme.fg(.dim, followUp) + theme.fg(.muted, " to queue follow-up"),
            theme.fg(.dim, dequeue) + theme.fg(.muted, " to restore queued messages"),
            theme.fg(.dim, "ctrl+v") + theme.fg(.muted, " to paste image"),
        ].joined(separator: "\n")
        return "\(logo)\n\(instructions)"
    }

    private func extractUserMessageText(_ message: AgentMessage) -> String {
        switch message {
        case .user(let user):
            return extractUserContentText(user.content)
        default:
            return ""
        }
    }

    private func extractUserContentText(_ content: UserContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let text) = block {
                    return text.text
                }
                return nil
            }.joined()
        }
    }

    @MainActor
    private func updatePendingMessagesDisplay() {
        guard let pendingMessagesContainer else { return }
        pendingMessagesContainer.clear()

        if pendingSteeringMessages.isEmpty && pendingFollowUpMessages.isEmpty && pendingBashComponents.isEmpty {
            return
        }

        pendingMessagesContainer.addChild(Spacer(1))
        for message in pendingSteeringMessages {
            let text = theme.fg(.dim, "Steering: \(message)")
            pendingMessagesContainer.addChild(TruncatedText(text, paddingX: 1, paddingY: 0))
        }
        for message in pendingFollowUpMessages {
            let text = theme.fg(.dim, "Follow-up: \(message)")
            pendingMessagesContainer.addChild(TruncatedText(text, paddingX: 1, paddingY: 0))
        }
        for component in pendingBashComponents {
            pendingMessagesContainer.addChild(component)
        }
    }

    @MainActor
    private func flushPendingBashComponents() {
        guard let session else { return }
        for component in pendingBashComponents {
            pendingMessagesContainer?.removeChild(component)
            chatContainer.addChild(component)
        }
        pendingBashComponents.removeAll()
        updatePendingMessagesDisplay()

        for message in pendingBashMessages {
            let agentMessage = makeBashExecutionAgentMessage(message)
            session.agent.appendMessage(agentMessage)
            _ = session.sessionManager.appendMessage(agentMessage)
        }
        pendingBashMessages.removeAll()
    }

    @MainActor
    private func updateEditorBorderColor() {
        guard let editor, let session else { return }
        if isBashMode {
            editor.borderColor = { @Sendable text in
                theme.getBashModeBorderColor()(text)
            }
        } else {
            let level = session.agent.state.thinkingLevel.rawValue
            editor.borderColor = { @Sendable text in
                theme.getThinkingBorderColor(level)(text)
            }
        }
    }

    @MainActor
    private func handleEscape() {
        if loadingAnimation != nil {
            _ = restoreQueuedMessagesToEditor(abort: true)
            return
        }

        if bashAbort != nil {
            bashAbort?.cancel()
            return
        }

        if isBashMode {
            editor?.setText("")
            isBashMode = false
            updateEditorBorderColor()
            return
        }

        if editor?.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            let now = Date().timeIntervalSince1970
            if now - lastEscapeTime < 0.5 {
                showUserMessageSelector()
                lastEscapeTime = 0
            } else {
                lastEscapeTime = now
            }
        }
    }

    @MainActor
    private func handleCtrlC() {
        let now = Date().timeIntervalSince1970
        if now - lastSigintTime < 0.5 {
            shutdown()
            return
        }
        lastSigintTime = now
        editor?.setText("")
        scheduleRender()
    }

    @MainActor
    private func handleCtrlD() {
        if editor?.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            shutdown()
        }
    }

    @MainActor
    private func handleCtrlZ() {
        guard let tui else { return }
        let signalSource = DispatchSource.makeSignalSource(signal: SIGCONT, queue: .main)
        signal(SIGCONT, SIG_IGN)
        signalSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tui?.start()
                self?.tui?.requestRender(force: true)
            }
            signalSource.cancel()
            self?.sigcontSource = nil
        }
        signalSource.resume()
        sigcontSource = signalSource

        tui.stop()
        kill(getpid(), SIGTSTP)
    }

    @MainActor
    private func shutdown() {
        if let session {
            Task { [session] in
                if let hookRunner = session.hookRunner {
                    _ = await hookRunner.emit(SessionShutdownEvent())
                }
                await session.emitCustomToolSessionEvent(.shutdown)
            }
        }
        unsubscribe?()
        unsubscribe = nil
        tui?.stop()
        if let continuation = exitContinuation {
            exitContinuation = nil
            continuation.resume()
        }
    }

    @MainActor
    private func handleAltEnter() async {
        guard let editor, let session else { return }
        let text = editor.getText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if session.isStreaming {
            session.followUp(text)
            pendingFollowUpMessages.append(text)
            updatePendingMessagesDisplay()
            editor.addToHistory(text)
            editor.setText("")
            scheduleRender()
        } else {
            await handleEditorSubmit(text)
        }
    }

    @MainActor
    private func handleDequeue() {
        let restored = restoreQueuedMessagesToEditor()
        if restored == 0 {
            showStatus("No queued messages to restore")
        } else {
            let suffix = restored == 1 ? "" : "s"
            showStatus("Restored \(restored) queued message\(suffix) to editor")
        }
    }

    @MainActor
    private func restoreQueuedMessagesToEditor(abort: Bool = false, currentText: String? = nil) -> Int {
        guard let session else { return 0 }
        let queued = session.clearQueue()
        let allQueued = queued.steering + queued.followUp

        pendingSteeringMessages.removeAll()
        pendingFollowUpMessages.removeAll()

        if allQueued.isEmpty {
            updatePendingMessagesDisplay()
            if abort {
                Task { await session.abort() }
            }
            return 0
        }

        let queuedText = allQueued.joined(separator: "\n\n")
        let existingText = currentText ?? editor?.getText() ?? ""
        let combined = [queuedText, existingText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        editor?.setText(combined)
        updatePendingMessagesDisplay()
        if abort {
            Task { await session.abort() }
        }
        return allQueued.count
    }

    private enum ModelCycleDirection {
        case forward
        case backward
    }

    @MainActor
    private func cycleThinkingLevel() {
        guard let session else { return }
        let model = session.agent.state.model
        guard model.reasoning else {
            showStatus("Current model does not support thinking")
            return
        }

        let levels: [ThinkingLevel]
        if supportsXhigh(model: model) {
            levels = [.off, .minimal, .low, .medium, .high, .xhigh]
        } else {
            levels = [.off, .minimal, .low, .medium, .high]
        }

        let current = session.agent.state.thinkingLevel
        guard let idx = levels.firstIndex(of: current) else { return }
        let next = levels[(idx + 1) % levels.count]
        session.agent.setThinkingLevel(next)
        session.settingsManager.setDefaultThinkingLevel(next.rawValue)
        updateEditorBorderColor()
        showStatus("Thinking level: \(next.rawValue)")
    }

    @MainActor
    private func cycleModel(direction: ModelCycleDirection) async {
        guard let session else { return }
        let models: [Model]
        let scoped = !scopedModels.isEmpty
        if scoped {
            models = scopedModels.map { $0.model }
        } else {
            models = await session.modelRegistry.getAvailable()
        }
        guard !models.isEmpty else {
            showStatus("No models available")
            return
        }

        let current = session.agent.state.model
        let currentIndex = models.firstIndex(where: { modelsAreEqual($0, current) }) ?? 0
        let nextIndex: Int
        switch direction {
        case .forward:
            nextIndex = (currentIndex + 1) % models.count
        case .backward:
            nextIndex = (currentIndex - 1 + models.count) % models.count
        }

        let nextModel = models[nextIndex]
        session.agent.setModel(nextModel)
        session.settingsManager.setDefaultModelAndProvider(nextModel.provider, nextModel.id)

        if scoped {
            let scopedLevel = scopedModels[nextIndex].thinkingLevel
            session.agent.setThinkingLevel(scopedLevel)
        } else if !nextModel.reasoning {
            session.agent.setThinkingLevel(.off)
        } else if session.agent.state.thinkingLevel == .xhigh && !supportsXhigh(model: nextModel) {
            session.agent.setThinkingLevel(.high)
        }

        updateEditorBorderColor()
        showStatus("Switched to \(nextModel.id)")
    }

    @MainActor
    private func toggleToolOutputExpansion() {
        toolOutputExpanded.toggle()
        for child in chatContainer.children {
            if let tool = child as? ToolExecutionComponent {
                tool.setExpanded(toolOutputExpanded)
            } else if let bash = child as? BashExecutionComponent {
                bash.setExpanded(toolOutputExpanded)
            } else if let branch = child as? BranchSummaryMessageComponent {
                branch.setExpanded(toolOutputExpanded)
            } else if let compaction = child as? CompactionSummaryMessageComponent {
                compaction.setExpanded(toolOutputExpanded)
            } else if let hook = child as? HookMessageComponent {
                hook.setExpanded(toolOutputExpanded)
            }
        }
        scheduleRender()
    }

    @MainActor
    private func toggleThinkingBlockVisibility() {
        hideThinkingBlock.toggle()
        session?.settingsManager.setHideThinkingBlock(hideThinkingBlock)

        applyThinkingBlockVisibility()
    }

    @MainActor
    private func applyThinkingBlockVisibility() {
        chatContainer.clear()
        renderInitialMessages()

        if let streamingComponent, let streamingMessage {
            streamingComponent.setHideThinkingBlock(hideThinkingBlock)
            streamingComponent.updateContent(streamingMessage)
            chatContainer.addChild(streamingComponent)
        }

        showStatus("Thinking blocks: \(hideThinkingBlock ? "hidden" : "visible")")
    }

    @MainActor
    private func openExternalEditor() async {
        guard let editor, let tui else { return }
        let editorCmd = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"]
        guard let editorCmd, !editorCmd.isEmpty else {
            showWarning("No editor configured. Set VISUAL or EDITOR.")
            return
        }

        let currentText = editor.getText()
        let tmpFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("pi-editor-\(Int(Date().timeIntervalSince1970)).md")

        do {
            try currentText.write(toFile: tmpFile, atomically: true, encoding: .utf8)

            tui.stop()

            let parts = editorCmd.split(separator: " ").map(String.init)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: parts[0])
            process.arguments = Array(parts.dropFirst()) + [tmpFile]
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let newContent = (try? String(contentsOfFile: tmpFile, encoding: .utf8)) ?? currentText
                editor.setText(newContent.trimmingCharacters(in: .newlines))
            }
        } catch {
            showWarning("Failed to open external editor")
        }

        try? FileManager.default.removeItem(atPath: tmpFile)

        tui.start()
        tui.requestRender()
    }

    @MainActor
    private func handleClipboardImagePaste() {
        guard let editor else { return }
        guard clipboardHasImage(), let data = getClipboardImagePngData(), !data.isEmpty else { return }

        let fileName = "pi-clipboard-\(UUID().uuidString).png"
        let filePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(fileName)
        do {
            try data.write(to: URL(fileURLWithPath: filePath))
            editor.insertTextAtCursor(filePath)
            scheduleRender()
        } catch {
            // Ignore clipboard errors.
        }
    }

    @MainActor
    private func handleEditorSubmit(_ text: String) async {
        guard let session, let editor else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("/") {
            if await handleHookCommand(trimmed) {
                editor.setText("")
                return
            }
        }

        if trimmed == "/settings" {
            showSettingsSelector()
            editor.setText("")
            return
        }
        if trimmed == "/model" {
            showModelSelector()
            editor.setText("")
            return
        }
        if trimmed == "/theme" {
            showThemeSelector()
            editor.setText("")
            return
        }
        if trimmed == "/login" {
            showOAuthSelector(.login)
            editor.setText("")
            return
        }
        if trimmed == "/logout" {
            showOAuthSelector(.logout)
            editor.setText("")
            return
        }
        if trimmed == "/templates" || trimmed == "/template" {
            handleTemplatesCommand()
            editor.setText("")
            return
        }
        if trimmed.hasPrefix("/export") {
            handleExportCommand(trimmed)
            editor.setText("")
            return
        }
        if trimmed == "/copy" {
            handleCopyCommand()
            editor.setText("")
            return
        }
        if trimmed == "/session" {
            handleSessionCommand()
            editor.setText("")
            return
        }
        if trimmed == "/changelog" {
            handleChangelogCommand()
            editor.setText("")
            return
        }
        if trimmed == "/hotkeys" {
            handleHotkeysCommand()
            editor.setText("")
            return
        }
        if trimmed == "/debug" {
            handleDebugCommand()
            editor.setText("")
            return
        }
        if trimmed == "/branch" {
            showUserMessageSelector()
            editor.setText("")
            return
        }
        if trimmed == "/tree" {
            showTreeSelector()
            editor.setText("")
            return
        }
        if trimmed == "/new" {
            handleNewSessionCommand()
            editor.setText("")
            return
        }
        if trimmed.hasPrefix("/compact") {
            let custom = trimmed.count > 8 ? String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            editor.disableSubmit = true
            handleCompactCommand(custom)
            editor.disableSubmit = false
            editor.setText("")
            return
        }
        if trimmed == "/resume" {
            showSessionSelector()
            editor.setText("")
            return
        }
        if trimmed == "/quit" || trimmed == "/exit" {
            editor.setText("")
            shutdown()
            return
        }

        if trimmed.hasPrefix("!") {
            let command = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                return
            }
            if bashAbort != nil {
                showWarning("A bash command is already running")
                return
            }
            editor.addToHistory(trimmed)
            await handleBashCommand(command)
            isBashMode = false
            updateEditorBorderColor()
            return
        }

        if session.isStreaming {
            session.steer(trimmed)
            pendingSteeringMessages.append(trimmed)
            updatePendingMessagesDisplay()
            editor.addToHistory(trimmed)
            editor.setText("")
            scheduleRender()
            return
        }

        flushPendingBashComponents()
        editor.addToHistory(trimmed)
        await prompt(trimmed, images: nil)
    }

    private func prompt(_ text: String, images: [ImageContent]?) async {
        guard let session else { return }
        do {
            try await session.prompt(text, options: PromptOptions(expandSlashCommands: nil, images: images))
        } catch {
            await MainActor.run {
                self.showError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handleHookCommand(_ text: String) async -> Bool {
        guard let session, let hookRunner = session.hookRunner else { return false }
        guard text.hasPrefix("/") else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let namePart = parts.first else { return false }
        let commandName = String(namePart)
        guard !commandName.isEmpty else { return false }

        let args = parts.count > 1 ? String(parts[1]) : ""
        guard let command = hookRunner.getCommand(commandName) else { return false }

        let context = hookRunner.createCommandContext()
        do {
            try await command.handler(args, context)
        } catch {
            hookRunner.emitError(HookError(
                hookPath: "command:\(commandName)",
                event: "command",
                error: error.localizedDescription,
                stack: Thread.callStackSymbols.joined(separator: "\n")
            ))
        }
        return true
    }

    @MainActor
    private func handleBashCommand(_ command: String) async {
        guard let tui, let session else { return }
        let component = BashExecutionComponent(command: command, ui: tui)
        bashComponent = component

        let deferDisplay = session.isStreaming
        if deferDisplay {
            pendingBashComponents.append(component)
        } else {
            chatContainer.addChild(component)
        }
        updatePendingMessagesDisplay()
        scheduleRender()

        let abortToken = CancellationToken()
        bashAbort = abortToken

        do {
            let result = try await executeBash(command, options: BashExecutorOptions(onChunk: { [weak self] chunk in
                Task { @MainActor in
                    guard let self, let bashComponent = self.bashComponent else { return }
                    bashComponent.appendOutput(chunk)
                    self.scheduleRender()
                }
            }, signal: abortToken))

            let truncation = result.truncated ? truncateTail(result.output) : nil
            component.setComplete(exitCode: result.exitCode, cancelled: result.cancelled, truncationResult: truncation, fullOutputPath: result.fullOutputPath)

            let message = BashExecutionMessage(
                command: command,
                output: result.output,
                exitCode: result.exitCode,
                cancelled: result.cancelled,
                truncated: result.truncated,
                fullOutputPath: result.fullOutputPath
            )

            if deferDisplay {
                pendingBashMessages.append(message)
            } else {
                let agentMessage = makeBashExecutionAgentMessage(message)
                session.agent.appendMessage(agentMessage)
                _ = session.sessionManager.appendMessage(agentMessage)
            }
        } catch {
            component.setComplete(exitCode: nil, cancelled: false)
            showError("Bash command failed: \(error.localizedDescription)")
        }

        bashComponent = nil
        bashAbort = nil
        scheduleRender()
    }

    @MainActor
    private func showSelector(_ builder: (_ done: @escaping () -> Void) -> (component: Component, focus: Component)) {
        guard let editorContainer, let tui else { return }

        let done: () -> Void = { [weak self] in
            guard let self else { return }
            self.selectorCancel = nil
            editorContainer.clear()
            if let editor = self.editor {
                editorContainer.addChild(editor)
                tui.setFocus(editor)
            }
            self.scheduleRender()
        }

        selectorCancel = done
        let result = builder(done)
        editorContainer.clear()
        editorContainer.addChild(result.component)
        tui.setFocus(result.focus)
        scheduleRender()
    }

    @MainActor
    private func showSettingsSelector() {
        guard let session else { return }
        let settingsManager = session.settingsManager

        let availableThinking: [ThinkingLevel] = {
            let model = session.agent.state.model
            guard model.reasoning else { return [.off] }
            if supportsXhigh(model: model) {
                return [.off, .minimal, .low, .medium, .high, .xhigh]
            }
            return [.off, .minimal, .low, .medium, .high]
        }()

        let config = SettingsConfig(
            autoCompact: settingsManager.getCompactionEnabled(),
            showImages: settingsManager.getShowImages(),
            autoResizeImages: settingsManager.getAutoResizeImages(),
            steeringMode: settingsManager.getSteeringMode(),
            followUpMode: settingsManager.getFollowUpMode(),
            thinkingLevel: session.agent.state.thinkingLevel,
            availableThinkingLevels: availableThinking,
            currentTheme: settingsManager.getTheme() ?? "dark",
            availableThemes: getAvailableThemes(),
            hideThinkingBlock: hideThinkingBlock,
            collapseChangelog: settingsManager.getCollapseChangelog()
        )

        showSelector { done in
            let callbacks = SettingsCallbacks(
                onAutoCompactChange: { [weak self] enabled in
                    settingsManager.setCompactionEnabled(enabled)
                    self?.footer?.setAutoCompactEnabled(enabled)
                },
                onShowImagesChange: { [weak self] enabled in
                    settingsManager.setShowImages(enabled)
                    self?.updateToolImages(enabled)
                },
                onAutoResizeImagesChange: { enabled in
                    settingsManager.setAutoResizeImages(enabled)
                },
                onSteeringModeChange: { mode in
                    settingsManager.setSteeringMode(mode)
                    session.agent.setSteeringMode(AgentSteeringMode(rawValue: mode) ?? .oneAtATime)
                },
                onFollowUpModeChange: { mode in
                    settingsManager.setFollowUpMode(mode)
                    session.agent.setFollowUpMode(AgentFollowUpMode(rawValue: mode) ?? .oneAtATime)
                },
                onThinkingLevelChange: { [weak self] level in
                    session.agent.setThinkingLevel(level)
                    settingsManager.setDefaultThinkingLevel(level.rawValue)
                    self?.updateEditorBorderColor()
                },
                onThemeChange: { [weak self] name in
                    let result = setTheme(name, enableWatcher: true)
                    settingsManager.setTheme(name)
                    if result.success == false {
                        self?.showError("Failed to load theme \(name): \(result.error ?? "unknown error")")
                    }
                },
                onThemePreview: { name in
                    _ = setTheme(name, enableWatcher: true)
                },
                onHideThinkingBlockChange: { [weak self] hide in
                    self?.hideThinkingBlock = hide
                    settingsManager.setHideThinkingBlock(hide)
                    self?.applyThinkingBlockVisibility()
                },
                onCollapseChangelogChange: { collapse in
                    settingsManager.setCollapseChangelog(collapse)
                },
                onCancel: {
                    done()
                }
            )

            let selector = SettingsSelectorComponent(config: config, callbacks: callbacks)
            return (component: selector, focus: selector.getSettingsList())
        }
    }

    @MainActor
    private func showModelSelector() {
        guard let session, let tui else { return }
        showSelector { done in
            let selector = ModelSelectorComponent(
                tui: tui,
                currentModel: session.agent.state.model,
                settingsManager: session.settingsManager,
                modelRegistry: session.modelRegistry,
                scopedModels: scopedModels,
                onSelect: { [weak self] model in
                    session.agent.setModel(model)
                    self?.updateEditorBorderColor()
                    done()
                    self?.showStatus("Model: \(model.id)")
                },
                onCancel: {
                    done()
                }
            )
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showThemeSelector() {
        guard let settingsManager = session?.settingsManager else { return }
        let current = settingsManager.getTheme() ?? "dark"
        showSelector { done in
            let selector = ThemeSelectorComponent(
                currentTheme: current,
                onSelect: { [weak self] name in
                    _ = setTheme(name, enableWatcher: true)
                    settingsManager.setTheme(name)
                    done()
                    self?.showStatus("Theme: \(name)")
                },
                onCancel: {
                    done()
                },
                onPreview: { name in
                    _ = setTheme(name, enableWatcher: true)
                }
            )
            return (component: selector, focus: selector.getSelectList())
        }
    }

    @MainActor
    private func showUserMessageSelector() {
        guard let session else { return }
        let messages = session.getUserMessagesForBranching()
        guard !messages.isEmpty else {
            showStatus("No messages to branch from")
            return
        }

        showSelector { done in
            let selector = UserMessageSelectorComponent(messages: messages.map { (id: $0.entryId, text: $0.text, timestamp: nil) }, onSelect: { [weak self] entryId in
                Task {
                    guard let self else { return }
                    do {
                        let result = try await session.branch(entryId)
                        if result.cancelled {
                            done()
                            self.scheduleRender()
                            return
                        }
                        self.chatContainer.clear()
                        self.renderInitialMessages()
                        self.editor?.setText(result.selectedText)
                        done()
                        self.showStatus("Branched to new session")
                    } catch {
                        done()
                        self.showError(error.localizedDescription)
                    }
                }
            }, onCancel: {
                done()
            })
            return (component: selector, focus: selector.getMessageList())
        }
    }

    @MainActor
    private func showTreeSelector() {
        guard let session else { return }
        let tree = session.sessionManager.getTree()
        let leafId = session.sessionManager.getLeafId()
        let height = tui?.terminal.rows ?? 24

        showSelector { done in
            let selector = TreeSelectorComponent(
                tree: tree,
                currentLeafId: leafId,
                terminalHeight: height,
                onSelect: { [weak self] entryId in
                    Task {
                        guard let self else { return }
                        let result = await session.navigateTree(entryId, summarize: false, customInstructions: nil)
                        if result.cancelled {
                            done()
                            self.showStatus("Navigation cancelled")
                            return
                        }
                        self.chatContainer.clear()
                        self.renderInitialMessages()
                        if let editorText = result.editorText {
                            self.editor?.setText(editorText)
                        }
                        done()
                        self.showStatus("Navigated to selected point")
                    }
                },
                onCancel: {
                    done()
                },
                onLabelChange: { entryId, label in
                    _ = try? session.sessionManager.appendLabelChange(entryId, label)
                }
            )
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showSessionSelector() {
        showStatus("Session resume is not implemented yet")
    }

    private struct OAuthLoginCancelled: Error, LocalizedError {
        var errorDescription: String? { "Login cancelled" }
    }

    @MainActor
    private func showOAuthSelector(_ mode: OAuthSelectorMode) {
        guard let session else { return }
        if mode == .logout {
            let providers = session.modelRegistry.authStorage.list()
            let loggedIn = providers.filter { provider in
                if case .oauth = session.modelRegistry.authStorage.get(provider) {
                    return true
                }
                return false
            }
            if loggedIn.isEmpty {
                showStatus("No OAuth providers logged in. Use /login first.")
                return
            }
        }

        showSelector { done in
            let selector = OAuthSelectorComponent(
                mode: mode,
                authStorage: session.modelRegistry.authStorage,
                onSelect: { [weak self] providerId in
                    done()
                    Task { @MainActor in
                        await self?.handleOAuthSelection(providerId: providerId, mode: mode)
                    }
                },
                onCancel: { [weak self] in
                    done()
                    self?.ui.requestRender()
                }
            )
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func handleOAuthSelection(providerId: String, mode: OAuthSelectorMode) async {
        guard let session else { return }
        guard let provider = OAuthProvider(rawValue: providerId) else {
            showError("Unknown OAuth provider: \(providerId)")
            return
        }

        switch mode {
        case .login:
            await handleOAuthLogin(provider, authStorage: session.modelRegistry.authStorage)
        case .logout:
            handleOAuthLogout(provider, authStorage: session.modelRegistry.authStorage)
        }
    }

    @MainActor
    private func handleOAuthLogin(_ provider: OAuthProvider, authStorage: AuthStorage) async {
        guard let tui, let editorContainer, let editor else { return }
        let providerName = getOAuthProviders().first { $0.id == provider }?.name ?? provider.rawValue

        let dialog = LoginDialogComponent(tui: tui, providerId: provider.rawValue) { _, _ in }
        let savedText = editor.getText()
        final class ManualInputState {
            var task: Task<String, Error>?
        }
        let manualInputState = ManualInputState()

        let restoreEditor: () -> Void = {
            editorContainer.clear()
            editorContainer.addChild(editor)
            editor.setText(savedText)
            tui.setFocus(editor)
            tui.requestRender()
        }

        editorContainer.clear()
        editorContainer.addChild(dialog)
        tui.setFocus(dialog)
        tui.requestRender()

        let needsManualInput = provider == .openAICodex || provider == .googleGeminiCli || provider == .googleAntigravity

        let manualInputProvider: (@MainActor @Sendable () async throws -> String?)?
        if needsManualInput {
            manualInputProvider = { () async throws -> String? in
                if let task = manualInputState.task {
                    return try await task.value
                }
                let value = try await dialog.showManualInput("Paste redirect URL below, or complete login in browser:")
                return value
            }
        } else {
            manualInputProvider = nil
        }

        let callbacks = OAuthLoginCallbacks(
            onAuth: { info in
                if needsManualInput {
                    manualInputState.task = Task { @MainActor in
                        dialog.showAuth(info.url, info.instructions)
                        return try await dialog.showManualInput("Paste redirect URL below, or complete login in browser:")
                    }
                } else {
                    Task { @MainActor in
                        dialog.showAuth(info.url, info.instructions)
                        if provider == .githubCopilot {
                            dialog.showWaiting("Waiting for browser authentication...")
                        }
                    }
                }
            },
            onPrompt: { prompt in
                try await dialog.showPrompt(prompt.message, prompt.placeholder)
            },
            onProgress: { message in
                Task { @MainActor in
                    dialog.showProgress(message)
                }
            },
            onManualCodeInput: manualInputProvider,
            signal: dialog.signal
        )

        do {
            try await authStorage.login(provider, callbacks: callbacks)
            session?.modelRegistry.refresh()
            restoreEditor()
            showStatus("Logged in to \(providerName). Credentials saved to \(getAuthPath())")
        } catch {
            restoreEditor()
            let message = error.localizedDescription
            if message != "Login cancelled" {
                showError("Failed to login to \(providerName): \(message)")
            }
        }
    }

    @MainActor
    private func handleOAuthLogout(_ provider: OAuthProvider, authStorage: AuthStorage) {
        let providerName = getOAuthProviders().first { $0.id == provider }?.name ?? provider.rawValue
        authStorage.logout(provider)
        session?.modelRegistry.refresh()
        showStatus("Logged out of \(providerName)")
    }

    @MainActor
    private func handleExportCommand(_ text: String) {
        guard let session else { return }
        let parts = text.split(separator: " ").map(String.init)
        let outputPath = parts.count > 1 ? parts[1] : nil

        do {
            let exported = try session.exportToHtml(outputPath)
            showStatus("Exported to: \(exported)")
        } catch {
            showError("Export failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleCopyCommand() {
        guard let session else { return }
        let lastAssistant = session.agent.state.messages.reversed().compactMap { message -> AssistantMessage? in
            if case .assistant(let assistant) = message {
                return assistant
            }
            return nil
        }.first

        guard let assistant = lastAssistant else {
            showStatus("No assistant message to copy")
            return
        }

        let text = assistant.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")

        if copyTextToClipboard(text) {
            showStatus("Copied last assistant message")
        } else {
            showWarning("Clipboard copy not available")
        }
    }

    @MainActor
    private func handleSessionCommand() {
        guard let session else { return }
        let entries = session.sessionManager.getEntries()
        var userMessages = 0
        var assistantMessages = 0
        var toolCalls = 0
        var toolResults = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0

        for entry in entries {
            if case .message(let messageEntry) = entry {
                switch messageEntry.message {
                case .user:
                    userMessages += 1
                case .assistant(let assistant):
                    assistantMessages += 1
                    totalInput += assistant.usage.input
                    totalOutput += assistant.usage.output
                    totalCacheRead += assistant.usage.cacheRead
                    totalCacheWrite += assistant.usage.cacheWrite
                    totalCost += assistant.usage.cost.total
                    toolCalls += assistant.content.filter { if case .toolCall = $0 { return true } else { return false } }.count
                case .toolResult:
                    toolResults += 1
                default:
                    break
                }
            }
        }

        let totalMessages = userMessages + assistantMessages + toolResults
        var info = "Session Info\n\n"
        info += "File: \(session.sessionManager.getSessionFile() ?? "n/a")\n"
        info += "ID: \(session.sessionManager.getSessionId())\n\n"
        info += "Messages\n"
        info += "User: \(userMessages)\n"
        info += "Assistant: \(assistantMessages)\n"
        info += "Tool Calls: \(toolCalls)\n"
        info += "Tool Results: \(toolResults)\n"
        info += "Total: \(totalMessages)\n\n"
        info += "Tokens\n"
        info += "Input: \(totalInput)\n"
        info += "Output: \(totalOutput)\n"
        info += "Cache Read: \(totalCacheRead)\n"
        info += "Cache Write: \(totalCacheWrite)\n"
        info += "Total: \(totalInput + totalOutput + totalCacheRead + totalCacheWrite)\n"
        if totalCost > 0 {
            info += "\nCost\nTotal: \(String(format: "%.4f", totalCost))\n"
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.fg(.dim, info), paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func handleChangelogCommand() {
        let path = getChangelogPath()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            showStatus("No changelog found")
            return
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.bold(theme.fg(.accent, "Changelog")), paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Markdown(content.trimmingCharacters(in: .whitespacesAndNewlines), paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
        scheduleRender()
    }

    @MainActor
    private func handleHotkeysCommand() {
        let cursorWordLeft = getEditorKeyDisplay(.cursorWordLeft)
        let cursorWordRight = getEditorKeyDisplay(.cursorWordRight)
        let cursorLineStart = getEditorKeyDisplay(.cursorLineStart)
        let cursorLineEnd = getEditorKeyDisplay(.cursorLineEnd)

        let submit = getEditorKeyDisplay(.submit)
        let newLine = getEditorKeyDisplay(.newLine)
        let deleteWordBackward = getEditorKeyDisplay(.deleteWordBackward)
        let deleteToLineStart = getEditorKeyDisplay(.deleteToLineStart)
        let deleteToLineEnd = getEditorKeyDisplay(.deleteToLineEnd)
        let tab = getEditorKeyDisplay(.tab)

        let interrupt = getAppKeyDisplay(.interrupt)
        let clear = getAppKeyDisplay(.clear)
        let exit = getAppKeyDisplay(.exit)
        let suspend = getAppKeyDisplay(.suspend)
        let cycleThinkingLevel = getAppKeyDisplay(.cycleThinkingLevel)
        let cycleModelForward = getAppKeyDisplay(.cycleModelForward)
        let expandTools = getAppKeyDisplay(.expandTools)
        let toggleThinking = getAppKeyDisplay(.toggleThinking)
        let externalEditor = getAppKeyDisplay(.externalEditor)
        let followUp = getAppKeyDisplay(.followUp)
        let dequeue = getAppKeyDisplay(.dequeue)

        var hotkeys = """
**Navigation**
| Key | Action |
|-----|--------|
| `Arrow keys` | Move cursor / browse history (Up when empty) |
| `\(cursorWordLeft)` / `\(cursorWordRight)` | Move by word |
| `\(cursorLineStart)` | Start of line |
| `\(cursorLineEnd)` | End of line |

**Editing**
| Key | Action |
|-----|--------|
| `\(submit)` | Send message |
| `\(newLine)` | New line |
| `\(deleteWordBackward)` | Delete word backwards |
| `\(deleteToLineStart)` | Delete to start of line |
| `\(deleteToLineEnd)` | Delete to end of line |

**Other**
| Key | Action |
|-----|--------|
| `\(tab)` | Path completion / accept autocomplete |
| `\(interrupt)` | Cancel autocomplete / abort streaming |
| `\(clear)` | Clear editor (first) / exit (second) |
| `\(exit)` | Exit (when editor is empty) |
| `\(suspend)` | Suspend to background |
| `\(cycleThinkingLevel)` | Cycle thinking level |
| `\(cycleModelForward)` | Cycle models |
| `\(expandTools)` | Toggle tool output expansion |
| `\(toggleThinking)` | Toggle thinking block visibility |
| `\(externalEditor)` | Edit message in external editor |
| `\(followUp)` | Queue follow-up message |
| `\(dequeue)` | Restore queued messages |
| `Ctrl+V` | Paste image from clipboard |
| `/` | Slash commands |
| `!` | Run bash command |
"""

        if !hookShortcuts.isEmpty {
            hotkeys += """

**Hooks**
| Key | Action |
|-----|--------|
"""
            let sorted = hookShortcuts.keys.sorted()
            for key in sorted {
                if let shortcut = hookShortcuts[key] {
                    let description = shortcut.description ?? shortcut.hookPath
                    hotkeys += "| `\(key)` | \(description) |\n"
                }
            }
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(DynamicBorder())
        chatContainer.addChild(Text(theme.bold(theme.fg(.accent, "Keyboard Shortcuts")), paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Markdown(hotkeys.trimmingCharacters(in: .whitespacesAndNewlines), paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
        chatContainer.addChild(DynamicBorder())
        scheduleRender()
    }

    @MainActor
    private func handleTemplatesCommand() {
        guard let session else { return }
        let templates = session.promptTemplates.sorted { $0.name.lowercased() < $1.name.lowercased() }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.bold(theme.fg(.accent, "Prompt Templates")), paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))

        if templates.isEmpty {
            chatContainer.addChild(Text(theme.fg(.dim, "No prompt templates found"), paddingX: 1, paddingY: 0))
            scheduleRender()
            return
        }

        let list = templates
            .map { "- /\($0.name) - \($0.description)" }
            .joined(separator: "\n")
        chatContainer.addChild(Markdown(list, paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
        scheduleRender()
    }

    private func formatKeyDisplay(_ keys: [KeyId]) -> String {
        return keys.map { formatKeyDisplay($0) }.joined(separator: "/")
    }

    private func formatKeyDisplay(_ keys: String) -> String {
        return keys.split(separator: "+").map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: "+")
    }

    private func getAppKeyDisplay(_ action: AppAction) -> String {
        return formatKeyDisplay(keybindings.getDisplayString(action))
    }

    private func getEditorKeyDisplay(_ action: EditorAction) -> String {
        return formatKeyDisplay(getEditorKeybindings().getKeys(action))
    }

    @MainActor
    private func handleNewSessionCommand() {
        guard let session else { return }
        _ = session.sessionManager.newSession()
        session.agent.replaceMessages([])
        chatContainer.clear()
        showStatus("New session started")
        scheduleRender()
    }

    @MainActor
    private func handleCompactCommand(_ customInstructions: String?) {
        guard let session else { return }
        Task {
            do {
                _ = try await session.compact(customInstructions: customInstructions)
                chatContainer.clear()
                renderInitialMessages()
                showStatus("Compaction complete")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handleDebugCommand() {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(getThemeDiagnostics(), paddingX: 1, paddingY: 0))
        let sample = [
            "Color sample:",
            theme.fg(.accent, "accent"),
            theme.fg(.muted, "muted"),
            theme.bg(.selectedBg, " selectedBg "),
        ].joined(separator: " ")
        chatContainer.addChild(Text(sample, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func updateToolImages(_ showImages: Bool) {
        for child in chatContainer.children {
            if let tool = child as? ToolExecutionComponent {
                tool.setShowImages(showImages)
            }
        }
        scheduleRender()
    }

    private func copyTextToClipboard(_ text: String) -> Bool {
        do {
            try copyToClipboard(text)
            return true
        } catch {
            return false
        }
    }

    public func showStatus(_ message: String) {
        let children = chatContainer.children
        let last = children.last
        let secondLast = children.count > 1 ? children[children.count - 2] : nil

        if let last = last as? Text,
           let secondLast = secondLast as? Spacer,
           lastStatusText === last,
           lastStatusSpacer === secondLast {
            last.setText(theme.fg(.dim, message))
            ui.requestRender()
            return
        }

        let spacer = Spacer(1)
        let text = Text(theme.fg(.dim, message), paddingX: 1, paddingY: 0)
        chatContainer.addChild(spacer)
        chatContainer.addChild(text)
        lastStatusSpacer = spacer
        lastStatusText = text
        ui.requestRender()
    }

    public func showError(_ errorMessage: String) {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.fg(.error, "Error: \(errorMessage)"), paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    public func showWarning(_ warningMessage: String) {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(theme.fg(.warning, "Warning: \(warningMessage)"), paddingX: 1, paddingY: 0))
        scheduleRender()
    }
}

private func decodeBashExecutionMessage(_ custom: AgentCustomMessage) -> BashExecutionMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let command = payload["command"] as? String ?? ""
    let output = payload["output"] as? String ?? ""
    let exitCode = payload["exitCode"] as? Int
    let cancelled = payload["cancelled"] as? Bool ?? false
    let truncated = payload["truncated"] as? Bool ?? false
    let fullOutputPath = payload["fullOutputPath"] as? String
    return BashExecutionMessage(command: command, output: output, exitCode: exitCode, cancelled: cancelled, truncated: truncated, fullOutputPath: fullOutputPath, timestamp: custom.timestamp)
}

private func decodeBranchSummaryMessage(_ custom: AgentCustomMessage) -> BranchSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let fromId = payload["fromId"] as? String ?? ""
    return BranchSummaryMessage(summary: summary, fromId: fromId, timestamp: custom.timestamp)
}

private func decodeCompactionSummaryMessage(_ custom: AgentCustomMessage) -> CompactionSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let tokensBefore = payload["tokensBefore"] as? Int ?? 0
    return CompactionSummaryMessage(summary: summary, tokensBefore: tokensBefore, timestamp: custom.timestamp)
}

private func decodeHookMessage(_ custom: AgentCustomMessage) -> HookMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    guard let customType = payload["customType"] as? String else { return nil }
    let display = payload["display"] as? Bool ?? true

    if let text = payload["content"] as? String {
        return HookMessage(customType: customType, content: .text(text), display: display, details: nil, timestamp: custom.timestamp)
    }

    if let blocks = payload["content"] as? [[String: Any]] {
        let contentBlocks: [ContentBlock] = blocks.compactMap { block in
            if let type = block["type"] as? String, type == "text", let text = block["text"] as? String {
                return .text(TextContent(text: text))
            }
            return nil
        }
        return HookMessage(customType: customType, content: .blocks(contentBlocks), display: display, details: nil, timestamp: custom.timestamp)
    }

    return HookMessage(customType: customType, content: .text(""), display: display, details: nil, timestamp: custom.timestamp)
}
