import Foundation
import PiSwiftAI

private let commandResultCache = LockedState<[String: String?]>([:])

private func resolveConfigValue(_ config: String) -> String? {
    if config.hasPrefix("!") {
        return executeCommand(config)
    }
    let envValue = ProcessInfo.processInfo.environment[config]
    if let envValue, !envValue.isEmpty {
        return envValue
    }
    return config
}

private func executeCommand(_ commandConfig: String) -> String? {
    if let cached = commandResultCache.withLock({ $0[commandConfig] }) {
        return cached
    }
    if commandResultCache.withLock({ $0.keys.contains(commandConfig) }) {
        return nil
    }

    let command = String(commandConfig.dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    var result: String? = nil
    do {
        try process.run()
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }
        if group.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            result = trimmed.isEmpty ? nil : trimmed
        }
    } catch {
        result = nil
    }

    commandResultCache.withLock { $0[commandConfig] = result }
    return result
}

private func resolveHeaders(_ headers: [String: String]?) -> [String: String]? {
    guard let headers else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in headers {
        if let resolvedValue = resolveConfigValue(value), !resolvedValue.isEmpty {
            resolved[key] = resolvedValue
        }
    }
    return resolved.isEmpty ? nil : resolved
}

private struct ProviderOverride: Sendable {
    var baseUrl: String?
    var headers: [String: String]?
    var apiKey: String?
}

private struct CustomModelsResult: Sendable {
    var models: [Model]
    var replacedProviders: Set<String>
    var overrides: [String: ProviderOverride]
    var errorMessage: String?
}

private func emptyCustomModelsResult(errorMessage: String? = nil) -> CustomModelsResult {
    CustomModelsResult(models: [], replacedProviders: Set(), overrides: [:], errorMessage: errorMessage)
}

public final class ModelRegistry: Sendable {
    public let authStorage: AuthStorage
    private let modelsDir: String?
    private let state = LockedState(State())
    private let customProviderApiKeys = LockedState<[String: String]>([:])

    private struct State: Sendable {
        var models: [Model] = []
        var errorMessage: String?
    }

    public init(_ authStorage: AuthStorage, _ modelsDir: String? = nil) {
        self.authStorage = authStorage
        self.modelsDir = modelsDir
        self.authStorage.setFallbackResolver { [weak self] provider in
            guard let self else { return nil }
            let keyConfig = self.customProviderApiKeys.withLock { $0[provider] }
            if let keyConfig {
                return resolveConfigValue(keyConfig)
            }
            return nil
        }
        loadModels()
    }

    public func getError() -> String? {
        state.withLock { $0.errorMessage }
    }

    public func refresh() {
        state.withLock { $0.errorMessage = nil }
        customProviderApiKeys.withLock { $0 = [:] }
        loadModels()
    }

    public func find(_ provider: String, _ modelId: String) -> Model? {
        state.withLock { state in
            state.models.first { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }
        }
    }

    public func getAvailable() async -> [Model] {
        state.withLock { $0.models }
    }

    public func getApiKey(_ provider: String) async -> String? {
        await authStorage.getApiKey(provider)
    }

    private func loadModels() {
        let customResult = modelsDir.map(loadCustomModels) ?? emptyCustomModelsResult()
        if let errorMessage = customResult.errorMessage {
            state.withLock { $0.errorMessage = errorMessage }
        }
        let builtInModels = loadBuiltInModels(
            replacedProviders: customResult.replacedProviders,
            overrides: customResult.overrides
        )
        var combined = builtInModels
        combined.append(contentsOf: customResult.models)
        state.withLock { $0.models = combined }
    }

    private func loadBuiltInModels(replacedProviders: Set<String>, overrides: [String: ProviderOverride]) -> [Model] {
        var models: [Model] = []
        for provider in getProviders() {
            let providerId = provider.rawValue
            guard !replacedProviders.contains(providerId) else { continue }
            let builtIns = getModels(provider: provider)
            guard let override = overrides[providerId] else {
                models.append(contentsOf: builtIns)
                continue
            }

            let resolvedHeaders = resolveHeaders(override.headers)
            for model in builtIns {
                let mergedHeaders: [String: String]?
                if let resolvedHeaders {
                    var headers = model.headers ?? [:]
                    for (key, value) in resolvedHeaders {
                        headers[key] = value
                    }
                    mergedHeaders = headers
                } else {
                    mergedHeaders = model.headers
                }
                let updated = Model(
                    id: model.id,
                    name: model.name,
                    api: model.api,
                    provider: model.provider,
                    baseUrl: override.baseUrl ?? model.baseUrl,
                    reasoning: model.reasoning,
                    input: model.input,
                    cost: model.cost,
                    contextWindow: model.contextWindow,
                    maxTokens: model.maxTokens,
                    headers: mergedHeaders,
                    compat: model.compat
                )
                models.append(updated)
            }

            if let apiKey = override.apiKey {
                customProviderApiKeys.withLock { $0[providerId] = apiKey }
            }
        }
        return models
    }

    private func loadCustomModels(from dir: String) -> CustomModelsResult {
        let path = (dir as NSString).appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return emptyCustomModelsResult()
        }

        do {
            let root = try JSONSerialization.jsonObject(with: data)
            if let entries = root as? [[String: Any]] {
                return parseLegacyModels(entries)
            }
            guard let dict = root as? [String: Any],
                  let providers = dict["providers"] as? [String: Any] else {
                return emptyCustomModelsResult(errorMessage: "models.json parse error")
            }
            return parseProviderModels(providers)
        } catch {
            return emptyCustomModelsResult(errorMessage: "models.json parse error")
        }
    }

    private func parseLegacyModels(_ entries: [[String: Any]]) -> CustomModelsResult {
        var custom: [Model] = []
        for entry in entries {
            guard let provider = entry["provider"] as? String,
                  let id = entry["id"] as? String,
                  let name = entry["name"] as? String,
                  let apiRaw = entry["api"] as? String,
                  let api = Api(rawValue: apiRaw),
                  let baseUrl = entry["baseUrl"] as? String,
                  let reasoning = entry["reasoning"] as? Bool,
                  let input = entry["input"] as? [String],
                  let contextWindow = entry["contextWindow"] as? Int,
                  let maxTokens = entry["maxTokens"] as? Int,
                  let cost = entry["cost"] as? [String: Any]
            else { continue }

            let costModel = ModelCost(
                input: cost["input"] as? Double ?? 0,
                output: cost["output"] as? Double ?? 0,
                cacheRead: cost["cacheRead"] as? Double ?? 0,
                cacheWrite: cost["cacheWrite"] as? Double ?? 0
            )

            let model = Model(
                id: id,
                name: name,
                api: api,
                provider: provider,
                baseUrl: baseUrl,
                reasoning: reasoning,
                input: input.compactMap { ModelInput(rawValue: $0) },
                cost: costModel,
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                headers: entry["headers"] as? [String: String]
            )
            custom.append(model)
        }
        return CustomModelsResult(models: custom, replacedProviders: Set(), overrides: [:], errorMessage: nil)
    }

    private func parseProviderModels(_ providers: [String: Any]) -> CustomModelsResult {
        var custom: [Model] = []
        var replacedProviders = Set<String>()
        var overrides: [String: ProviderOverride] = [:]

        for (providerName, value) in providers {
            guard let providerConfig = value as? [String: Any] else { continue }
            let models = providerConfig["models"] as? [[String: Any]] ?? []
            let baseUrl = providerConfig["baseUrl"] as? String
            let apiKey = providerConfig["apiKey"] as? String
            let apiOverride = providerConfig["api"] as? String
            let headers = providerConfig["headers"] as? [String: String]
            let authHeader = providerConfig["authHeader"] as? Bool ?? false

            if models.isEmpty {
                if baseUrl != nil {
                    overrides[providerName] = ProviderOverride(baseUrl: baseUrl, headers: headers, apiKey: apiKey)
                }
                if let apiKey {
                    customProviderApiKeys.withLock { $0[providerName] = apiKey }
                }
                continue
            }

            replacedProviders.insert(providerName)
            if let apiKey {
                customProviderApiKeys.withLock { $0[providerName] = apiKey }
            }

            for modelDef in models {
                guard let id = modelDef["id"] as? String,
                      let name = modelDef["name"] as? String,
                      let reasoning = modelDef["reasoning"] as? Bool,
                      let input = modelDef["input"] as? [String],
                      let contextWindow = modelDef["contextWindow"] as? Int,
                      let maxTokens = modelDef["maxTokens"] as? Int,
                      let cost = modelDef["cost"] as? [String: Any] else {
                    continue
                }

                let apiRaw = (modelDef["api"] as? String) ?? apiOverride
                guard let apiRaw, let api = Api(rawValue: apiRaw) else { continue }

                var resolvedHeaders = resolveHeaders(headers)
                if let modelHeaders = resolveHeaders(modelDef["headers"] as? [String: String]) {
                    resolvedHeaders = (resolvedHeaders ?? [:]).merging(modelHeaders) { _, new in new }
                }

                if authHeader, let apiKey, let resolvedKey = resolveConfigValue(apiKey) {
                    var headers = resolvedHeaders ?? [:]
                    headers["Authorization"] = "Bearer \(resolvedKey)"
                    resolvedHeaders = headers
                }

                let costModel = ModelCost(
                    input: cost["input"] as? Double ?? 0,
                    output: cost["output"] as? Double ?? 0,
                    cacheRead: cost["cacheRead"] as? Double ?? 0,
                    cacheWrite: cost["cacheWrite"] as? Double ?? 0
                )

                guard let baseUrl else { continue }
                let model = Model(
                    id: id,
                    name: name,
                    api: api,
                    provider: providerName,
                    baseUrl: baseUrl,
                    reasoning: reasoning,
                    input: input.compactMap { ModelInput(rawValue: $0) },
                    cost: costModel,
                    contextWindow: contextWindow,
                    maxTokens: maxTokens,
                    headers: resolvedHeaders
                )
                custom.append(model)
            }
        }

        return CustomModelsResult(
            models: custom,
            replacedProviders: replacedProviders,
            overrides: overrides,
            errorMessage: nil
        )
    }
}
