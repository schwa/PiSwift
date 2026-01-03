import Foundation
import PiSwiftAI

public struct FileProcessingResult: Sendable {
    public var textContent: String
    public var imageAttachments: [ImageContent]

    public init(textContent: String, imageAttachments: [ImageContent]) {
        self.textContent = textContent
        self.imageAttachments = imageAttachments
    }
}

public func processFileArguments(_ fileArgs: [String]) throws -> FileProcessingResult {
    var textContent = ""
    var imageAttachments: [ImageContent] = []

    for fileArg in fileArgs {
        let expanded = expandPath(fileArg)
        let absolutePath = URL(fileURLWithPath: expanded).standardizedFileURL.path

        guard FileManager.default.fileExists(atPath: absolutePath) else {
            throw NSError(domain: "FileProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(absolutePath)"])
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: absolutePath)
        if let size = attrs[.size] as? Int, size == 0 {
            continue
        }

        if let mimeType = detectSupportedImageMimeType(fromFile: absolutePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            let base64 = data.base64EncodedString()
            imageAttachments.append(ImageContent(data: base64, mimeType: mimeType))
            textContent += "<file name=\"\(absolutePath)\"></file>\n"
        } else {
            let content = try String(contentsOfFile: absolutePath, encoding: .utf8)
            textContent += "<file name=\"\(absolutePath)\">\n\(content)\n</file>\n"
        }
    }

    return FileProcessingResult(textContent: textContent, imageAttachments: imageAttachments)
}
