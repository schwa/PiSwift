import Foundation
import MiniTui
import PiSwiftAI

public struct ImageResizeOptions: Sendable {
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxBytes: Int
    public var jpegQuality: Int

    public init(
        maxWidth: Int = 2000,
        maxHeight: Int = 2000,
        maxBytes: Int = Int(4.5 * 1024 * 1024),
        jpegQuality: Int = 80
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBytes = maxBytes
        self.jpegQuality = jpegQuality
    }
}

public struct ResizedImage: Sendable {
    public var data: String
    public var mimeType: String
    public var originalWidth: Int
    public var originalHeight: Int
    public var width: Int
    public var height: Int
    public var wasResized: Bool

    public init(
        data: String,
        mimeType: String,
        originalWidth: Int,
        originalHeight: Int,
        width: Int,
        height: Int,
        wasResized: Bool
    ) {
        self.data = data
        self.mimeType = mimeType
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.width = width
        self.height = height
        self.wasResized = wasResized
    }
}

private let defaultQualitySteps: [Int] = [85, 70, 55, 40]
private let defaultScaleSteps: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25]

public func formatDimensionNote(_ result: ResizedImage) -> String? {
    guard result.wasResized, result.width > 0, result.originalWidth > 0 else { return nil }
    let scale = Double(result.originalWidth) / Double(result.width)
    let scaleString = String(format: "%.2f", scale)
    return "[Image: original \(result.originalWidth)x\(result.originalHeight), displayed at \(result.width)x\(result.height). Multiply coordinates by \(scaleString) to map to original image.]"
}

public func resizeImage(_ img: ImageContent, options: ImageResizeOptions = ImageResizeOptions()) -> ResizedImage {
    let mimeType = img.mimeType
    let base64Data = img.data
    guard let rawData = Data(base64Encoded: base64Data) else {
        return ResizedImage(
            data: base64Data,
            mimeType: mimeType,
            originalWidth: 0,
            originalHeight: 0,
            width: 0,
            height: 0,
            wasResized: false
        )
    }

    let parsedDims = getImageDimensions(base64Data, mimeType: mimeType)
    var originalWidth = parsedDims?.widthPx ?? 0
    var originalHeight = parsedDims?.heightPx ?? 0

    if originalWidth > 0, originalHeight > 0,
       originalWidth <= options.maxWidth,
       originalHeight <= options.maxHeight,
       rawData.count <= options.maxBytes {
        return ResizedImage(
            data: base64Data,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    #if canImport(AppKit)
    return resizeImageWithAppKit(
        rawData: rawData,
        originalBase64: base64Data,
        mimeType: mimeType,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        options: options
    )
    #else
    return ResizedImage(
        data: base64Data,
        mimeType: mimeType,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        width: originalWidth,
        height: originalHeight,
        wasResized: false
    )
    #endif
}

public func convertToPng(_ base64Data: String, _ mimeType: String) -> ImageContent? {
    if mimeType == "image/png" {
        return ImageContent(data: base64Data, mimeType: mimeType)
    }
    guard let rawData = Data(base64Encoded: base64Data) else { return nil }
    #if canImport(AppKit)
    if let converted = convertImageToPng(rawData) {
        return ImageContent(data: converted.base64EncodedString(), mimeType: "image/png")
    }
    #endif
    return nil
}

#if canImport(AppKit)
import AppKit

private func resizeImageWithAppKit(
    rawData: Data,
    originalBase64: String,
    mimeType: String,
    originalWidth: Int,
    originalHeight: Int,
    options: ImageResizeOptions
) -> ResizedImage {
    guard let image = NSImage(data: rawData) else {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    var width = originalWidth
    var height = originalHeight
    if width == 0 || height == 0 {
        if let rep = NSBitmapImageRep(data: rawData) {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        } else {
            width = Int(image.size.width)
            height = Int(image.size.height)
        }
    }

    if width <= 0 || height <= 0 {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            width: originalWidth,
            height: originalHeight,
            wasResized: false
        )
    }

    let originalSize = rawData.count
    if width <= options.maxWidth, height <= options.maxHeight, originalSize <= options.maxBytes {
        return ResizedImage(
            data: originalBase64,
            mimeType: mimeType,
            originalWidth: width,
            originalHeight: height,
            width: width,
            height: height,
            wasResized: false
        )
    }

    let target = scaleToFit(width: width, height: height, maxWidth: options.maxWidth, maxHeight: options.maxHeight)

    let qualitySteps = defaultQualitySteps
    let scaleSteps = defaultScaleSteps

    var bestData: Data?
    var bestMimeType = mimeType
    var finalWidth = target.width
    var finalHeight = target.height

    func tryEncode(width: Int, height: Int, jpegQuality: Int) -> (Data, String)? {
        guard let rep = makeBitmapRep(image: image, width: width, height: height) else { return nil }
        return encodeBestFormat(rep: rep, jpegQuality: jpegQuality)
    }

    if let encoded = tryEncode(width: target.width, height: target.height, jpegQuality: options.jpegQuality) {
        bestData = encoded.0
        bestMimeType = encoded.1
        if encoded.0.count <= options.maxBytes {
            return ResizedImage(
                data: encoded.0.base64EncodedString(),
                mimeType: encoded.1,
                originalWidth: width,
                originalHeight: height,
                width: target.width,
                height: target.height,
                wasResized: true
            )
        }
    }

    for quality in qualitySteps {
        if let encoded = tryEncode(width: target.width, height: target.height, jpegQuality: quality) {
            bestData = encoded.0
            bestMimeType = encoded.1
            if encoded.0.count <= options.maxBytes {
                return ResizedImage(
                    data: encoded.0.base64EncodedString(),
                    mimeType: encoded.1,
                    originalWidth: width,
                    originalHeight: height,
                    width: target.width,
                    height: target.height,
                    wasResized: true
                )
            }
        }
    }

    for scale in scaleSteps {
        finalWidth = max(1, Int(Double(target.width) * scale))
        finalHeight = max(1, Int(Double(target.height) * scale))
        if finalWidth < 100 || finalHeight < 100 {
            break
        }
        for quality in qualitySteps {
            if let encoded = tryEncode(width: finalWidth, height: finalHeight, jpegQuality: quality) {
                bestData = encoded.0
                bestMimeType = encoded.1
                if encoded.0.count <= options.maxBytes {
                    return ResizedImage(
                        data: encoded.0.base64EncodedString(),
                        mimeType: encoded.1,
                        originalWidth: width,
                        originalHeight: height,
                        width: finalWidth,
                        height: finalHeight,
                        wasResized: true
                    )
                }
            }
        }
    }

    if let bestData {
        return ResizedImage(
            data: bestData.base64EncodedString(),
            mimeType: bestMimeType,
            originalWidth: width,
            originalHeight: height,
            width: finalWidth,
            height: finalHeight,
            wasResized: true
        )
    }

    return ResizedImage(
        data: originalBase64,
        mimeType: mimeType,
        originalWidth: width,
        originalHeight: height,
        width: width,
        height: height,
        wasResized: false
    )
}

private func scaleToFit(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
    var targetWidth = width
    var targetHeight = height
    if targetWidth > maxWidth {
        targetHeight = Int(Double(targetHeight) * Double(maxWidth) / Double(targetWidth))
        targetWidth = maxWidth
    }
    if targetHeight > maxHeight {
        targetWidth = Int(Double(targetWidth) * Double(maxHeight) / Double(targetHeight))
        targetHeight = maxHeight
    }
    return (max(1, targetWidth), max(1, targetHeight))
}

private func makeBitmapRep(image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
    let size = NSSize(width: width, height: height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep else { return nil }
    image.size = size
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func encodeBestFormat(rep: NSBitmapImageRep, jpegQuality: Int) -> (Data, String)? {
    let pngData = rep.representation(using: .png, properties: [:])
    let quality = max(0.0, min(1.0, Double(jpegQuality) / 100.0))
    let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])

    switch (pngData, jpegData) {
    case let (png?, jpeg?):
        if png.count <= jpeg.count {
            return (png, "image/png")
        }
        return (jpeg, "image/jpeg")
    case let (png?, nil):
        return (png, "image/png")
    case let (nil, jpeg?):
        return (jpeg, "image/jpeg")
    default:
        return nil
    }
}

private func convertImageToPng(_ rawData: Data) -> Data? {
    if let rep = NSBitmapImageRep(data: rawData) {
        return rep.representation(using: .png, properties: [:])
    }
    guard let image = NSImage(data: rawData),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
}
#endif
