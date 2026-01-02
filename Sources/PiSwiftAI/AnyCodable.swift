import Foundation

public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let arrayVal as [Any]:
            try container.encode(arrayVal.map { AnyCodable($0) })
        case let dictVal as [String: Any]:
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AnyCodable value cannot be encoded"))
        }
    }

    public var jsonValue: Any {
        switch value {
        case is NSNull:
            return NSNull()
        case let intVal as Int:
            return intVal
        case let doubleVal as Double:
            return doubleVal
        case let stringVal as String:
            return stringVal
        case let boolVal as Bool:
            return boolVal
        case let arrayVal as [Any]:
            return arrayVal.map { AnyCodable($0).jsonValue }
        case let dictVal as [String: Any]:
            return dictVal.mapValues { AnyCodable($0).jsonValue }
        default:
            return String(describing: value)
        }
    }
}

public func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
    switch (lhs.value, rhs.value) {
    case (is NSNull, is NSNull):
        return true
    case let (l as Int, r as Int):
        return l == r
    case let (l as Double, r as Double):
        return l == r
    case let (l as String, r as String):
        return l == r
    case let (l as Bool, r as Bool):
        return l == r
    case let (l as [Any], r as [Any]):
        return l.map { AnyCodable($0) } == r.map { AnyCodable($0) }
    case let (l as [String: Any], r as [String: Any]):
        return l.mapValues { AnyCodable($0) } == r.mapValues { AnyCodable($0) }
    default:
        return false
    }
}
