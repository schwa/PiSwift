import Foundation
import MiniTui
import PiSwiftAI

private let bashPreviewLines = 5

public struct ToolExecutionOptions: Sendable {
    public var showImages: Bool

    public init(showImages: Bool = true) {
        self.showImages = showImages
    }
}

@MainActor
public final class ToolExecutionComponent: Container {
    private let contentBox: Box
    private let contentText: Text
    private var imageComponents: [Image] = []
    private var imageSpacers: [Spacer] = []
    private let toolName: String
    private var args: [String: AnyCodable]
    private var expanded = false
    private var showImages: Bool
    private var isPartial = true
    private let ui: TUI
    private let cwd: String
    private var result: ToolResultMessage?
    private var editDiffPreview: String?
    private var editDiffArgsKey: String?

    public init(
        toolName: String,
        args: [String: AnyCodable],
        options: ToolExecutionOptions = ToolExecutionOptions(),
        ui: TUI,
        cwd: String = FileManager.default.currentDirectoryPath
    ) {
        self.toolName = toolName
        self.args = args
        self.showImages = options.showImages
        self.ui = ui
        self.cwd = cwd

        self.contentBox = Box(paddingX: 1, paddingY: 1, bgFn: { theme.bg(.toolPendingBg, $0) })
        self.contentText = Text("", paddingX: 1, paddingY: 1, customBgFn: { theme.bg(.toolPendingBg, $0) })

        super.init()

        addChild(Spacer(1))
        if toolName == "bash" {
            addChild(contentBox)
        } else {
            addChild(contentText)
        }

        updateDisplay()
    }

    public func updateArgs(_ args: [String: AnyCodable]) {
        self.args = args
        updateDisplay()
    }

    public func setArgsComplete() {
        maybeComputeEditDiff()
    }

    public func updateResult(_ result: ToolResultMessage, isPartial: Bool = false) {
        self.result = result
        self.isPartial = isPartial
        updateDisplay()
    }

    public func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        updateDisplay()
    }

    public func setShowImages(_ show: Bool) {
        self.showImages = show
        updateDisplay()
    }

    private func updateDisplay() {
        let bgFn: (String) -> String
        if isPartial {
            bgFn = { theme.bg(.toolPendingBg, $0) }
        } else if result?.isError == true {
            bgFn = { theme.bg(.toolErrorBg, $0) }
        } else {
            bgFn = { theme.bg(.toolSuccessBg, $0) }
        }

        if toolName == "bash" {
            contentBox.setBgFn(bgFn)
            contentBox.clear()
            renderBashContent()
        } else {
            contentText.setCustomBgFn(bgFn)
            contentText.setText(formatToolExecution())
        }

        for component in imageComponents {
            removeChild(component)
        }
        for spacer in imageSpacers {
            removeChild(spacer)
        }
        imageComponents.removeAll()
        imageSpacers.removeAll()

        if let result {
            let imageBlocks = result.content.compactMap { block -> ImageContent? in
                if case let .image(image) = block {
                    return image
                }
                return nil
            }

            let caps = getCapabilities()
            for image in imageBlocks {
                if caps.images != nil, showImages {
                    let spacer = Spacer(1)
                    addChild(spacer)
                    imageSpacers.append(spacer)
                    let imageComponent = Image(
                        base64Data: image.data,
                        mimeType: image.mimeType,
                        theme: ImageTheme(fallbackColor: { theme.fg(.toolOutput, $0) }),
                        options: ImageOptions(filename: nil)
                    )
                    addChild(imageComponent)
                    imageComponents.append(imageComponent)
                } else {
                    let spacer = Spacer(1)
                    addChild(spacer)
                    imageSpacers.append(spacer)
                    let fallback = Text(theme.fg(.toolOutput, "[image: \(image.mimeType)]"), paddingX: 1, paddingY: 0)
                    addChild(fallback)
                }
            }
        }
    }

    private func renderBashContent() {
        let command = args["command"]?.value as? String ?? ""
        contentBox.addChild(Text(theme.fg(.toolTitle, theme.bold("$ \(command)")), paddingX: 0, paddingY: 0))

        let output = getTextOutput()
        if !output.isEmpty {
            let styled = output.split(separator: "\n", omittingEmptySubsequences: false).map {
                theme.fg(.toolOutput, String($0))
            }.joined(separator: "\n")

            if expanded {
                contentBox.addChild(Text("\n" + styled, paddingX: 0, paddingY: 0))
            } else {
                let truncation = truncateToVisualLines("\n" + styled, maxVisualLines: bashPreviewLines, width: ui.terminal.columns, paddingX: 0)
                contentBox.addChild(StaticLines(truncation.visualLines))
                if truncation.skippedCount > 0 {
                    let hint = theme.fg(.dim, "... \(truncation.skippedCount) more lines (ctrl+o to expand)")
                    contentBox.addChild(Text("\n" + hint, paddingX: 0, paddingY: 0))
                }
            }
        }
    }

    private func formatToolExecution() -> String {
        var lines: [String] = []
        lines.append(theme.fg(.toolTitle, theme.bold(toolName)))

        if let argsText = formatArgs(args), !argsText.isEmpty {
            lines.append(theme.fg(.toolOutput, argsText))
        }

        if let editDiffPreview, result == nil {
            lines.append(renderDiff(editDiffPreview))
        }

        if let result {
            let output = getTextOutput(from: result)
            if !output.isEmpty {
                lines.append(theme.fg(.toolOutput, output))
            }

            if let diff = extractDiff(from: result.details) {
                lines.append(renderDiff(diff))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatArgs(_ args: [String: AnyCodable]) -> String? {
        guard !args.isEmpty else { return nil }
        let jsonObject = args.mapValues { $0.jsonValue }
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            return String(describing: jsonObject)
        }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: options),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: jsonObject)
    }

    private func getTextOutput() -> String {
        guard let result else { return "" }
        return getTextOutput(from: result)
    }

    private func getTextOutput(from result: ToolResultMessage) -> String {
        let textBlocks = result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }
        return textBlocks.joined(separator: "\n")
    }

    private func extractDiff(from details: AnyCodable?) -> String? {
        guard let details, let dict = details.value as? [String: Any] else {
            return nil
        }
        if let diff = dict["diff"] as? String {
            return diff
        }
        return nil
    }

    private func maybeComputeEditDiff() {
        guard toolName == "edit" else { return }
        guard let path = args["path"]?.value as? String else { return }
        guard let oldText = args["oldText"]?.value as? String else { return }
        guard let newText = args["newText"]?.value as? String else { return }

        let argsKey = "\(path)::\(oldText)::\(newText)"
        if editDiffArgsKey == argsKey {
            return
        }
        editDiffArgsKey = argsKey

        let diffResult = generateDiffString(oldText, newText)
        editDiffPreview = diffResult.diff
    }
}

private final class StaticLines: Component {
    private let lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func render(width: Int) -> [String] {
        _ = width
        return lines
    }
}
