import Foundation

public func parseStreamingJSON(_ partialJson: String?) -> [String: AnyCodable] {
    guard let partialJson, !partialJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return [:]
    }

    if let object = parseJSONObject(partialJson) {
        return object.mapValues { AnyCodable($0) }
    }

    var trimmed = partialJson
    while !trimmed.isEmpty {
        trimmed.removeLast()
        if let object = parseJSONObject(trimmed) {
            return object.mapValues { AnyCodable($0) }
        }
    }

    return [:]
}

private func parseJSONObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else {
        return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let object = json as? [String: Any] else {
        return nil
    }
    return object
}
