import Foundation

public protocol HookPlugin: AnyObject {
    init()
    func register(_ api: HookAPI)
}

public struct HookLoadError: Sendable {
    public var path: String
    public var error: String

    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

public struct LoadHooksResult: Sendable {
    public var hooks: [LoadedHook]
    public var errors: [HookLoadError]

    public init(hooks: [LoadedHook], errors: [HookLoadError]) {
        self.hooks = hooks
        self.errors = errors
    }
}

private final class HookPluginStore: @unchecked Sendable {
    static let shared = HookPluginStore()
    private let lock = NSLock()
    private var plugins: [AnyObject] = []

    func add(_ plugin: AnyObject) {
        lock.lock()
        plugins.append(plugin)
        lock.unlock()
    }
}

private func resolveHookPath(_ hookPath: String, cwd: String) -> String {
    resolveToCwd(hookPath, cwd: cwd)
}

private func discoverHooksInDir(_ dir: String) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return []
    }

    var hooks: [String] = []
    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") { continue }
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDir = values?.isDirectory ?? false

        if isDir, name.hasSuffix(".bundle") {
            hooks.append(entry.path)
            continue
        }

        let ext = entry.pathExtension.lowercased()
        if ext == "dylib" || ext == "so" {
            hooks.append(entry.path)
        }
    }
    return hooks
}

private func loadHook(_ hookPath: String, cwd: String, eventBus: EventBus) -> (hook: LoadedHook?, error: String?) {
    let resolvedPath = resolveHookPath(hookPath, cwd: cwd)
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        return (nil, "Hook not found")
    }

    let resolvedUrl = URL(fileURLWithPath: resolvedPath)
    if resolvedUrl.pathExtension.lowercased() == "bundle" {
        guard let bundle = Bundle(path: resolvedPath) else {
            return (nil, "Failed to load bundle")
        }
        guard bundle.load() else {
            return (nil, "Failed to load bundle")
        }
        guard let principal = bundle.principalClass as? HookPlugin.Type else {
            return (nil, "Bundle principal class must conform to HookPlugin")
        }

        let api = HookAPI(events: eventBus)
        api.setExecCwd(cwd)
        let plugin = principal.init()
        plugin.register(api)
        HookPluginStore.shared.add(plugin)

        let loaded = LoadedHook(
            path: hookPath,
            resolvedPath: resolvedPath,
            handlers: api.handlers,
            messageRenderers: api.messageRenderers,
            commands: api.commands,
            setSendMessageHandler: api.setSendMessageHandler,
            setAppendEntryHandler: api.setAppendEntryHandler
        )
        return (loaded, nil)
    }

    return (nil, "Unsupported hook format. Use a .bundle with a HookPlugin principal class")
}

public func loadHooks(_ paths: [String], cwd: String, eventBus: EventBus? = nil) -> LoadHooksResult {
    var hooks: [LoadedHook] = []
    var errors: [HookLoadError] = []
    let resolvedEventBus = eventBus ?? createEventBus()

    for path in paths {
        let result = loadHook(path, cwd: cwd, eventBus: resolvedEventBus)
        if let error = result.error {
            errors.append(HookLoadError(path: path, error: error))
            continue
        }
        if let hook = result.hook {
            hooks.append(hook)
        }
    }

    return LoadHooksResult(hooks: hooks, errors: errors)
}

public func discoverAndLoadHooks(
    _ configuredPaths: [String],
    _ cwd: String,
    _ agentDir: String = getAgentDir(),
    _ eventBus: EventBus? = nil
) -> LoadHooksResult {
    var allPaths: [String] = []
    var seen: Set<String> = []

    func addPaths(_ paths: [String]) {
        for path in paths {
            let resolved = resolveHookPath(path, cwd: cwd)
            if !seen.contains(resolved) {
                seen.insert(resolved)
                allPaths.append(path)
            }
        }
    }

    let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("hooks").path
    addPaths(discoverHooksInDir(globalDir))

    let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("hooks").path
    addPaths(discoverHooksInDir(localDir))

    addPaths(configuredPaths)

    return loadHooks(allPaths, cwd: cwd, eventBus: eventBus)
}
