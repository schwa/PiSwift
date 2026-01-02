import Foundation
import OpenAI

private struct JSONNull: JSONDocument {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if !container.decodeNil() {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected null value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

func openAIJSONSchema(from parameters: [String: AnyCodable]) -> JSONSchema? {
    let converted = parameters.mapValues { toAnyJSONDocument($0.value) }
    return .object(converted)
}

func toAnyJSONDocument(_ value: Any) -> AnyJSONDocument {
    switch value {
    case is NSNull:
        return AnyJSONDocument(JSONNull())
    case let intVal as Int:
        return AnyJSONDocument(intVal)
    case let doubleVal as Double:
        return AnyJSONDocument(doubleVal)
    case let stringVal as String:
        return AnyJSONDocument(stringVal)
    case let boolVal as Bool:
        return AnyJSONDocument(boolVal)
    case let arrayVal as [Any]:
        let converted = arrayVal.map { toAnyJSONDocument($0) }
        return AnyJSONDocument(converted)
    case let dictVal as [String: Any]:
        let converted = dictVal.mapValues { toAnyJSONDocument($0) }
        return AnyJSONDocument(converted)
    default:
        return AnyJSONDocument(String(describing: value))
    }
}

func jsonString(from dict: [String: AnyCodable]) -> String {
    let jsonObject = dict.mapValues { $0.jsonValue }
    if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
       let string = String(data: data, encoding: .utf8) {
        return string
    }
    return "{}"
}
