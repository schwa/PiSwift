import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

// Small 2x2 red PNG image (base64) - generated with ImageMagick
private let TINY_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAQMAAABIeJ9nAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gEOADM5Ddoh/wAAAAxJREFUCNdjYGBgAAAABAABJzQnCgAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wMS0xNFQwMDo1MTo1NyswMDowMOnKzHgAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDEtMTRUMDA6NTE6NTcrMDA6MDCYl3TEAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTAxLTE0VDAwOjUxOjU3KzAwOjAwz4JVGwAAAABJRU5ErkJggg=="

// Small 2x2 blue JPEG image (base64) - generated with ImageMagick
private let TINY_JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAGCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AD3VTB3/2Q=="

// 100x100 gray PNG
private let MEDIUM_PNG_100x100 = "iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAAAAABVicqIAAAAAmJLR0QA/4ePzL8AAAAHdElNRQfqAQ4AMzkN2iH/AAAAP0lEQVRo3u3NQQEAAAQEMASXXYrz2gqst/Lm4ZBIJBKJRCKRSCQSiUQikUgkEolEIpFIJBKJRCKRSCQSiSTsAP1cAUZeKtreAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTAxLTE0VDAwOjUxOjU3KzAwOjAw6crMeAAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0wMS0xNFQwMDo1MTo1NyswMDowMJiXdMQAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMDEtMTRUMDA6NTE6NTcrMDA6MDDPglUbAAAAAElFTkSuQmCC"

// 200x200 colored PNG
private let LARGE_PNG_200x200 = "iVBORw0KGgoAAAANSUhEUgAAAMgAAADIEAIAAAByquWKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRP///////wlY99wAAAAHdElNRQfqAQ4AMzqU03BFAAAEEElEQVR42u3dvWqUURSF4XXMRAyIhSAWQvwnWtjaWusFx9bW1kKD/wELESxEiBjDjJdwysOC57mCXW32+zGcGbtdACpsdi+T8Xz1GABzm91xMl6sHgNgblzcT/Y+rh4DYG6cv0/2H64eA2BOEgI1fHQHaoyzbXIwVo8BMCcJgRqSEKgxft9Lrn5aPQbA3Ph1klw7Wj0GwJwkBGpYWECN8fMiub63egyAORcWUMPCAmqMH3eTG59XjwEwN76/S24+Wj0GwJwkBGpYWECN8e1fcmuzegyAORcWUMPCAmqM09vJ4dfVYwDMjS9vkzuPV48BMCcJgRqeSAZqjA/nyYP91WMAzElCoIYkBGqMk8Pk6HT1GABzm+3L5JIkBApIQqCGj+5AjfHmb/Lk8uoxAOYkIVBDEgI1LCygxmZ7nFyShEABFxZQw8ICaozXf5KnV1aPATDnwgJqWFhADQsLqOFnDUANFxZQw8ICaoxXZ8mzg9VjAMy5sIAaFhZQw3tYQA1/QgHUkIRADUkI1JCEQA1JCNSQhEANFxZQwzcsoIYkBGpIQqCGJARqSEKghiQEalhYQA1/QgHUcGEBNSwsoIYkBGq4sIAaFhZQw8ICaviGBdRwYQE1LCyghiQEariwgBoWFlDDe1hADS+OAjUkIVBDEgI1JCFQQxICNSQhUMOFBdTwDQuoIQmBGpIQqCEJgRqSEKghCYEaFhZQw4ujQA0XFlDDwgJqSEKghgsLqGFhATUsLKCGb1hADRcWUMPCAmpIQqCGCwuoYWEBNbyHBdTw4ihQQxICNSQhUEMSAjUkIVBDEgI1XFhADd+wgBqSEKghCYEakhCoIQmBGpIQqGFhATW8OArUcGEBNSwsoIYkBGq4sIAaFhZQw8ICaviGBdRwYQE1LCyghiQEariwgBoWFlDDe1hADS+OAjUkIVBDEgI1JCFQQxICNSQhUMOFBdTwDQuoIQmBGpIQqCEJgRqSEKghCYEa49lB8ups9RgAc14cBWpIQqCGhQXUkIRADRcWUMPCAmqMp1eS139WjwEw5xsWUEMSAjUsLKCGJARquLCAGhYWUGM8uZy8+bt6DIA5L44CNSQhUMMTyUCNcXSanByuHgNgThICNSQhUGM82E8+nK8eA2DOzxqAGpIQqDHuPE6+vF09BsDcOPyanN5ePQbAnCQEavgdFlBj3Nok3/6tHgNgzoujQA1JCNQYNx8l39+tHgNgbtz4nPy4u3oMgDlJCNSwsIAa4/pe8vNi9RgAc37WANSQhECNce0o+XWyegyAuXH1U/L73uoxAOYkIVDDwgJqjIORnG1XjwEw508ogBqSEKgx9h8m5+9XjwEwN/Y+Jhf3V48BMCcJgRpjPE+2x6vHAJgbSbLbrR4DYO4/GqiSgXN+ksgAAAAldEVYdGRhdGU6Y3JlYXRlADIwMjYtMDEtMTRUMDA6NTE6NTcrMDA6MDDpysx4AAAAJXRFWHRkYXRlOm1vZGlmeQAyMDI2LTAxLTE0VDAwOjUxOjU3KzAwOjAwmJd0xAAAACh0RVh0ZGF0ZTp0aW1lc3RhbXAAMjAyNi0wMS0xNFQwMDo1MTo1NyswMDowMM+CVRsAAAAASUVORK5CYII="

// MARK: - convertToPng tests

@Test func convertToPngReturnsSameDataForPng() {
    let result = convertToPng(TINY_PNG, "image/png")

    #expect(result != nil)
    #expect(result?.data == TINY_PNG)
    #expect(result?.mimeType == "image/png")
}

@Test func convertToPngConvertsJpegToPng() {
    let result = convertToPng(TINY_JPEG, "image/jpeg")

    #expect(result != nil)
    #expect(result?.mimeType == "image/png")

    // Result should be valid base64
    if let data = result?.data, let decoded = Data(base64Encoded: data) {
        // PNG magic bytes
        #expect(decoded[0] == 0x89)
        #expect(decoded[1] == 0x50) // 'P'
        #expect(decoded[2] == 0x4E) // 'N'
        #expect(decoded[3] == 0x47) // 'G'
    } else {
        Issue.record("Failed to decode result as base64")
    }
}

// MARK: - resizeImage tests

@Test func resizeImageReturnsOriginalIfWithinLimits() {
    let img = ImageContent(data: TINY_PNG, mimeType: "image/png")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 100,
        maxHeight: 100,
        maxBytes: 1024 * 1024
    ))

    #expect(result.wasResized == false)
    #expect(result.data == TINY_PNG)
    #expect(result.originalWidth == 2)
    #expect(result.originalHeight == 2)
    #expect(result.width == 2)
    #expect(result.height == 2)
}

@Test func resizeImageResizesExceedingDimensionLimits() {
    let img = ImageContent(data: MEDIUM_PNG_100x100, mimeType: "image/png")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 50,
        maxHeight: 50,
        maxBytes: 1024 * 1024
    ))

    #expect(result.wasResized == true)
    #expect(result.originalWidth == 100)
    #expect(result.originalHeight == 100)
    #expect(result.width <= 50)
    #expect(result.height <= 50)
}

@Test func resizeImageResizesExceedingByteLimit() {
    guard let originalData = Data(base64Encoded: LARGE_PNG_200x200) else {
        Issue.record("Failed to decode test image")
        return
    }
    let originalSize = originalData.count

    let img = ImageContent(data: LARGE_PNG_200x200, mimeType: "image/png")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 2000,
        maxHeight: 2000,
        maxBytes: originalSize / 2
    ))

    // Should have tried to reduce size
    if let resultData = Data(base64Encoded: result.data) {
        #expect(resultData.count < originalSize)
    }
}

@Test func resizeImageHandlesJpegInput() {
    let img = ImageContent(data: TINY_JPEG, mimeType: "image/jpeg")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 100,
        maxHeight: 100,
        maxBytes: 1024 * 1024
    ))

    #expect(result.wasResized == false)
    #expect(result.originalWidth == 2)
    #expect(result.originalHeight == 2)
}

// MARK: - formatDimensionNote tests

@Test func formatDimensionNoteReturnsNilForNonResized() {
    let result = ResizedImage(
        data: "",
        mimeType: "image/png",
        originalWidth: 100,
        originalHeight: 100,
        width: 100,
        height: 100,
        wasResized: false
    )

    let note = formatDimensionNote(result)
    #expect(note == nil)
}

@Test func formatDimensionNoteReturnsFormattedNoteForResized() {
    let result = ResizedImage(
        data: "",
        mimeType: "image/png",
        originalWidth: 2000,
        originalHeight: 1000,
        width: 1000,
        height: 500,
        wasResized: true
    )

    let note = formatDimensionNote(result)
    #expect(note != nil)
    #expect(note?.contains("original 2000x1000") == true)
    #expect(note?.contains("displayed at 1000x500") == true)
    #expect(note?.contains("2.00") == true) // scale factor
}

// MARK: - Image dimension parsing tests

@Test func resizeImageParsesPngDimensions() {
    let img = ImageContent(data: MEDIUM_PNG_100x100, mimeType: "image/png")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 2000,
        maxHeight: 2000,
        maxBytes: 10 * 1024 * 1024
    ))

    #expect(result.originalWidth == 100)
    #expect(result.originalHeight == 100)
}

@Test func resizeImageParsesJpegDimensions() {
    let img = ImageContent(data: TINY_JPEG, mimeType: "image/jpeg")
    let result = resizeImage(img, options: ImageResizeOptions(
        maxWidth: 2000,
        maxHeight: 2000,
        maxBytes: 10 * 1024 * 1024
    ))

    #expect(result.originalWidth == 2)
    #expect(result.originalHeight == 2)
}

@Test func resizeImageHandlesInvalidBase64() {
    let img = ImageContent(data: "not-valid-base64!!!", mimeType: "image/png")
    let result = resizeImage(img, options: ImageResizeOptions())

    // Should return original data without crashing
    #expect(result.data == "not-valid-base64!!!")
    #expect(result.wasResized == false)
}
