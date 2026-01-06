import Foundation
import PiSwiftAI

public final class ModelRegistry: @unchecked Sendable {
    public let authStorage: AuthStorage
    private var models: [Model] = []
    private var errorMessage: String?
    private let modelsDir: String?

    public init(_ authStorage: AuthStorage, _ modelsDir: String? = nil) {
        self.authStorage = authStorage
        self.modelsDir = modelsDir
        loadDefaultModels()
        loadCustomModelsIfNeeded()
    }

    public func getError() -> String? {
        errorMessage
    }

    public func refresh() {
        errorMessage = nil
        loadDefaultModels()
        loadCustomModelsIfNeeded()
    }

    public func find(_ provider: String, _ modelId: String) -> Model? {
        models.first { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }
    }

    public func getAvailable() async -> [Model] {
        models
    }

    public func getApiKey(_ provider: String) async -> String? {
        await authStorage.getApiKey(provider)
    }

    private func loadDefaultModels() {
        var loaded: [Model] = []
        for provider in getProviders() {
            loaded.append(contentsOf: getModels(provider: provider))
        }
        models = loaded
    }

    private func loadCustomModelsIfNeeded() {
        guard let modelsDir else { return }
        loadCustomModels(from: modelsDir)
    }

    private func loadCustomModels(from dir: String) {
        let path = (dir as NSString).appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            errorMessage = "models.json parse error"
            return
        }
        var custom: [Model] = []
        for entry in json {
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
                maxTokens: maxTokens
            )
            custom.append(model)
        }
        models.append(contentsOf: custom)
    }
}
