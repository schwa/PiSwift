import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct ScopedModel: Sendable {
    public var model: Model
    public var thinkingLevel: ThinkingLevel

    public init(model: Model, thinkingLevel: ThinkingLevel) {
        self.model = model
        self.thinkingLevel = thinkingLevel
    }
}

public struct ParsedModelResult: Sendable {
    public var model: Model?
    public var thinkingLevel: ThinkingLevel
    public var warning: String?
}

private func isAlias(_ id: String) -> Bool {
    if id.hasSuffix("-latest") { return true }
    let pattern = try? NSRegularExpression(pattern: "-\\d{8}$", options: [])
    let range = NSRange(location: 0, length: id.utf16.count)
    if let pattern, pattern.firstMatch(in: id, options: [], range: range) != nil {
        return false
    }
    return true
}

private func tryMatchModel(_ modelPattern: String, availableModels: [Model]) -> Model? {
    if let slashIndex = modelPattern.firstIndex(of: "/") {
        let provider = String(modelPattern[..<slashIndex])
        let modelId = String(modelPattern[modelPattern.index(after: slashIndex)...])
        if let providerMatch = availableModels.first(where: { $0.provider.lowercased() == provider.lowercased() && $0.id.lowercased() == modelId.lowercased() }) {
            return providerMatch
        }
    }

    if let exact = availableModels.first(where: { $0.id.lowercased() == modelPattern.lowercased() }) {
        return exact
    }

    let matches: [Model]
    if modelPattern.isEmpty {
        matches = availableModels
    } else {
        matches = availableModels.filter {
            $0.id.lowercased().contains(modelPattern.lowercased()) ||
            $0.name.lowercased().contains(modelPattern.lowercased())
        }
    }

    if matches.isEmpty {
        return nil
    }

    let aliases = matches.filter { isAlias($0.id) }.sorted { $0.id > $1.id }
    if let alias = aliases.first {
        return alias
    }

    let dated = matches.filter { !isAlias($0.id) }.sorted { $0.id > $1.id }
    return dated.first
}

public func parseModelPattern(_ pattern: String, _ availableModels: [Model]) -> ParsedModelResult {
    if let exact = tryMatchModel(pattern, availableModels: availableModels) {
        return ParsedModelResult(model: exact, thinkingLevel: .off, warning: nil)
    }

    guard let lastColon = pattern.lastIndex(of: ":") else {
        return ParsedModelResult(model: nil, thinkingLevel: .off, warning: nil)
    }

    let prefix = String(pattern[..<lastColon])
    let suffix = String(pattern[pattern.index(after: lastColon)...])

    if isValidThinkingLevel(suffix) {
        let result = parseModelPattern(prefix, availableModels)
        if let model = result.model {
            let level = result.warning == nil ? ThinkingLevel(rawValue: suffix) ?? .off : .off
            return ParsedModelResult(model: model, thinkingLevel: level, warning: result.warning)
        }
        return result
    } else {
        let result = parseModelPattern(prefix, availableModels)
        if let model = result.model {
            return ParsedModelResult(
                model: model,
                thinkingLevel: .off,
                warning: "Invalid thinking level \"\(suffix)\" in pattern \"\(pattern)\". Using \"off\" instead."
            )
        }
        return result
    }
}

public func resolveModelScope(_ patterns: [String], _ modelRegistry: ModelRegistry) async -> [ScopedModel] {
    let available = await modelRegistry.getAvailable()
    var scoped: [ScopedModel] = []

    for pattern in patterns {
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            var globPattern = pattern
            var thinkingLevel: ThinkingLevel = .off
            if let colon = pattern.lastIndex(of: ":") {
                let suffix = String(pattern[pattern.index(after: colon)...])
                if isValidThinkingLevel(suffix) {
                    thinkingLevel = ThinkingLevel(rawValue: suffix) ?? .off
                    globPattern = String(pattern[..<colon])
                }
            }

            for model in available {
                let fullId = "\(model.provider)/\(model.id)"
                if matchesGlob(fullId, globPattern) || matchesGlob(model.id, globPattern) {
                    if !scoped.contains(where: { modelsAreEqual($0.model, model) }) {
                        scoped.append(ScopedModel(model: model, thinkingLevel: thinkingLevel))
                    }
                }
            }
            continue
        }

        let parsed = parseModelPattern(pattern, available)
        if let model = parsed.model {
            if !scoped.contains(where: { modelsAreEqual($0.model, model) }) {
                scoped.append(ScopedModel(model: model, thinkingLevel: parsed.thinkingLevel))
            }
        }
    }

    return scoped
}
