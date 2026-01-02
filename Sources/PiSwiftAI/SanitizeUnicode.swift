import Foundation

public func sanitizeSurrogates(_ text: String) -> String {
    let units = Array(text.utf16)
    var output: [UInt16] = []
    output.reserveCapacity(units.count)

    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit >= 0xD800 && unit <= 0xDBFF {
            if index + 1 < units.count {
                let next = units[index + 1]
                if next >= 0xDC00 && next <= 0xDFFF {
                    output.append(unit)
                    output.append(next)
                    index += 2
                    continue
                }
            }
            index += 1
            continue
        }

        if unit >= 0xDC00 && unit <= 0xDFFF {
            index += 1
            continue
        }

        output.append(unit)
        index += 1
    }

    let cleaned = String(decoding: output, as: UTF16.self)
    let replacement = String(UnicodeScalar(0xFFFD)!)
    return cleaned.replacingOccurrences(of: replacement, with: "")
}
