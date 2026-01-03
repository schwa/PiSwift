import Foundation
import PiSwiftAI

public func intValue(_ value: AnyCodable?) -> Int? {
    if let intValue = value?.value as? Int {
        return intValue
    }
    if let doubleValue = value?.value as? Double {
        return Int(doubleValue)
    }
    if let stringValue = value?.value as? String, let parsed = Int(stringValue) {
        return parsed
    }
    return nil
}

public func doubleValue(_ value: AnyCodable?) -> Double? {
    if let doubleValue = value?.value as? Double {
        return doubleValue
    }
    if let intValue = value?.value as? Int {
        return Double(intValue)
    }
    if let stringValue = value?.value as? String, let parsed = Double(stringValue) {
        return parsed
    }
    return nil
}
