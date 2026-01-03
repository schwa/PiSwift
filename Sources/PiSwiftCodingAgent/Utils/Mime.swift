import Foundation

public func detectSupportedImageMimeType(fromFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        return nil
    }
    defer { try? handle.close() }

    let data = handle.readData(ofLength: 16)
    if data.count >= 8 {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if Array(data.prefix(8)) == pngSignature {
            return "image/png"
        }
    }

    if data.count >= 3 {
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
        if Array(data.prefix(3)) == jpegSignature {
            return "image/jpeg"
        }
    }

    if data.count >= 6 {
        let header = String(bytes: data.prefix(6), encoding: .ascii) ?? ""
        if header.hasPrefix("GIF87a") || header.hasPrefix("GIF89a") {
            return "image/gif"
        }
    }

    if data.count >= 12 {
        let riff = String(bytes: data.prefix(4), encoding: .ascii) ?? ""
        let webp = String(bytes: data[8..<12], encoding: .ascii) ?? ""
        if riff == "RIFF" && webp == "WEBP" {
            return "image/webp"
        }
    }

    return nil
}
