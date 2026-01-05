import Foundation
import Dispatch
import MiniTui
import Darwin
import PiSwiftSyntaxHighlight

public enum ThemeColor: String, CaseIterable, Sendable {
    case accent
    case border
    case borderAccent
    case borderMuted
    case success
    case error
    case warning
    case muted
    case dim
    case text
    case thinkingText
    case userMessageText
    case customMessageText
    case customMessageLabel
    case toolTitle
    case toolOutput
    case mdHeading
    case mdLink
    case mdLinkUrl
    case mdCode
    case mdCodeBlock
    case mdCodeBlockBorder
    case mdQuote
    case mdQuoteBorder
    case mdHr
    case mdListBullet
    case toolDiffAdded
    case toolDiffRemoved
    case toolDiffContext
    case syntaxComment
    case syntaxKeyword
    case syntaxFunction
    case syntaxVariable
    case syntaxString
    case syntaxNumber
    case syntaxType
    case syntaxOperator
    case syntaxPunctuation
    case thinkingOff
    case thinkingMinimal
    case thinkingLow
    case thinkingMedium
    case thinkingHigh
    case thinkingXhigh
    case bashMode
}

public enum ThemeBg: String, CaseIterable, Sendable {
    case selectedBg
    case userMessageBg
    case customMessageBg
    case toolPendingBg
    case toolSuccessBg
    case toolErrorBg
}

private enum ColorMode: String {
    case truecolor
    case color256
}

private enum ThemeColorValue: Decodable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.typeMismatch(
            ThemeColorValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
        )
    }
}

private struct ThemeExportSection: Decodable, Sendable {
    var pageBg: ThemeColorValue?
    var cardBg: ThemeColorValue?
    var infoBg: ThemeColorValue?
}

private struct ThemeJson: Decodable, Sendable {
    var name: String
    var vars: [String: ThemeColorValue]?
    var colors: [String: ThemeColorValue]
    var export: ThemeExportSection?
}

private enum ThemeLoadError: Error, CustomStringConvertible {
    case missingTheme(String)
    case invalidTheme(String)

    var description: String {
        switch self {
        case .missingTheme(let name):
            return "Theme not found: \(name)"
        case .invalidTheme(let message):
            return message
        }
    }
}

public struct Theme: Sendable {
    private var fgColors: [ThemeColor: String]
    private var bgColors: [ThemeBg: String]
    private var mode: ColorMode

    fileprivate init(fgColors: [ThemeColor: String], bgColors: [ThemeBg: String], mode: ColorMode) {
        self.fgColors = fgColors
        self.bgColors = bgColors
        self.mode = mode
    }

    public static func fallback() -> Theme {
        let fg = Dictionary(uniqueKeysWithValues: ThemeColor.allCases.map { ($0, "\u{001B}[39m") })
        let bg = Dictionary(uniqueKeysWithValues: ThemeBg.allCases.map { ($0, "\u{001B}[49m") })
        return Theme(fgColors: fg, bgColors: bg, mode: .color256)
    }

    public func fg(_ color: ThemeColor, _ text: String) -> String {
        guard let ansi = fgColors[color] else { return text }
        return "\(ansi)\(text)\u{001B}[39m"
    }

    public func fg(_ color: String, _ text: String) -> String {
        guard let parsed = ThemeColor(rawValue: color) else { return text }
        return fg(parsed, text)
    }

    public func bg(_ color: ThemeBg, _ text: String) -> String {
        guard let ansi = bgColors[color] else { return text }
        return "\(ansi)\(text)\u{001B}[49m"
    }

    public func bg(_ color: String, _ text: String) -> String {
        guard let parsed = ThemeBg(rawValue: color) else { return text }
        return bg(parsed, text)
    }

    public func bold(_ text: String) -> String {
        "\u{001B}[1m\(text)\u{001B}[22m"
    }

    public func italic(_ text: String) -> String {
        "\u{001B}[3m\(text)\u{001B}[23m"
    }

    public func underline(_ text: String) -> String {
        "\u{001B}[4m\(text)\u{001B}[24m"
    }

    public func strikethrough(_ text: String) -> String {
        "\u{001B}[9m\(text)\u{001B}[29m"
    }

    public func inverse(_ text: String) -> String {
        "\u{001B}[7m\(text)\u{001B}[27m"
    }

    public func getFgAnsi(_ color: ThemeColor) -> String {
        fgColors[color] ?? "\u{001B}[39m"
    }

    public func getBgAnsi(_ color: ThemeBg) -> String {
        bgColors[color] ?? "\u{001B}[49m"
    }

    public func getColorMode() -> String {
        mode.rawValue
    }

    public func getThinkingBorderColor(_ level: String) -> (String) -> String {
        switch level {
        case "off":
            return { self.fg(.thinkingOff, $0) }
        case "minimal":
            return { self.fg(.thinkingMinimal, $0) }
        case "low":
            return { self.fg(.thinkingLow, $0) }
        case "medium":
            return { self.fg(.thinkingMedium, $0) }
        case "high":
            return { self.fg(.thinkingHigh, $0) }
        case "xhigh":
            return { self.fg(.thinkingXhigh, $0) }
        default:
            return { self.fg(.thinkingOff, $0) }
        }
    }

    public func getBashModeBorderColor() -> (String) -> String {
        { self.fg(.bashMode, $0) }
    }
}

private struct ResolvedColor: Sendable {
    var string: String?
    var number: Int?

    init(string: String) {
        self.string = string
        self.number = nil
    }

    init(number: Int) {
        self.string = nil
        self.number = number
    }
}

private let cubeValues: [Int] = [0, 95, 135, 175, 215, 255]
private let grayValues: [Int] = (0..<24).map { 8 + $0 * 10 }

private func detectColorMode() -> ColorMode {
    let env = ProcessInfo.processInfo.environment
    if let colorterm = env["COLORTERM"], colorterm == "truecolor" || colorterm == "24bit" {
        return .truecolor
    }
    if env["WT_SESSION"] != nil {
        return .truecolor
    }
    let term = env["TERM"] ?? ""
    if term.contains("256color") {
        return .color256
    }
    return .color256
}

private func hexToRgb(_ hex: String) throws -> (r: Int, g: Int, b: Int) {
    let cleaned = hex.replacingOccurrences(of: "#", with: "")
    guard cleaned.count == 6 else {
        throw ThemeLoadError.invalidTheme("Invalid hex color: \(hex)")
    }
    let r = Int(cleaned.prefix(2), radix: 16)
    let g = Int(cleaned.dropFirst(2).prefix(2), radix: 16)
    let b = Int(cleaned.dropFirst(4).prefix(2), radix: 16)
    guard let r, let g, let b else {
        throw ThemeLoadError.invalidTheme("Invalid hex color: \(hex)")
    }
    return (r, g, b)
}

private func colorDistance(_ r1: Int, _ g1: Int, _ b1: Int, _ r2: Int, _ g2: Int, _ b2: Int) -> Double {
    let dr = Double(r1 - r2)
    let dg = Double(g1 - g2)
    let db = Double(b1 - b2)
    return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114
}

private func findClosestCubeIndex(_ value: Int) -> Int {
    var minDist = Int.max
    var minIdx = 0
    for (idx, candidate) in cubeValues.enumerated() {
        let dist = abs(value - candidate)
        if dist < minDist {
            minDist = dist
            minIdx = idx
        }
    }
    return minIdx
}

private func findClosestGrayIndex(_ value: Int) -> Int {
    var minDist = Int.max
    var minIdx = 0
    for (idx, candidate) in grayValues.enumerated() {
        let dist = abs(value - candidate)
        if dist < minDist {
            minDist = dist
            minIdx = idx
        }
    }
    return minIdx
}

private func rgbTo256(_ r: Int, _ g: Int, _ b: Int) -> Int {
    let rIdx = findClosestCubeIndex(r)
    let gIdx = findClosestCubeIndex(g)
    let bIdx = findClosestCubeIndex(b)
    let cubeR = cubeValues[rIdx]
    let cubeG = cubeValues[gIdx]
    let cubeB = cubeValues[bIdx]
    let cubeIndex = 16 + 36 * rIdx + 6 * gIdx + bIdx
    let cubeDist = colorDistance(r, g, b, cubeR, cubeG, cubeB)

    let gray = Int((0.299 * Double(r)) + (0.587 * Double(g)) + (0.114 * Double(b)))
    let grayIdx = findClosestGrayIndex(gray)
    let grayValue = grayValues[grayIdx]
    let grayIndex = 232 + grayIdx
    let grayDist = colorDistance(r, g, b, grayValue, grayValue, grayValue)

    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let spread = maxC - minC

    if spread < 10 && grayDist < cubeDist {
        return grayIndex
    }
    return cubeIndex
}

private func hexTo256(_ hex: String) throws -> Int {
    let rgb = try hexToRgb(hex)
    return rgbTo256(rgb.r, rgb.g, rgb.b)
}

private func fgAnsi(_ color: ResolvedColor, _ mode: ColorMode) throws -> String {
    if let number = color.number {
        return "\u{001B}[38;5;\(number)m"
    }
    let value = color.string ?? ""
    if value.isEmpty {
        return "\u{001B}[39m"
    }
    if value.hasPrefix("#") {
        switch mode {
        case .truecolor:
            let rgb = try hexToRgb(value)
            return "\u{001B}[38;2;\(rgb.r);\(rgb.g);\(rgb.b)m"
        case .color256:
            let index = try hexTo256(value)
            return "\u{001B}[38;5;\(index)m"
        }
    }
    throw ThemeLoadError.invalidTheme("Invalid color value: \(value)")
}

private func bgAnsi(_ color: ResolvedColor, _ mode: ColorMode) throws -> String {
    if let number = color.number {
        return "\u{001B}[48;5;\(number)m"
    }
    let value = color.string ?? ""
    if value.isEmpty {
        return "\u{001B}[49m"
    }
    if value.hasPrefix("#") {
        switch mode {
        case .truecolor:
            let rgb = try hexToRgb(value)
            return "\u{001B}[48;2;\(rgb.r);\(rgb.g);\(rgb.b)m"
        case .color256:
            let index = try hexTo256(value)
            return "\u{001B}[48;5;\(index)m"
        }
    }
    throw ThemeLoadError.invalidTheme("Invalid color value: \(value)")
}

private func resolveVarRefs(
    _ value: ThemeColorValue,
    vars: [String: ThemeColorValue],
    visited: inout Set<String>
) throws -> ResolvedColor {
    switch value {
    case .number(let number):
        guard (0...255).contains(number) else {
            throw ThemeLoadError.invalidTheme("Invalid color index: \(number)")
        }
        return ResolvedColor(number: number)
    case .string(let stringValue):
        if stringValue.isEmpty || stringValue.hasPrefix("#") {
            return ResolvedColor(string: stringValue)
        }
        let key = stringValue.hasPrefix("$") ? String(stringValue.dropFirst()) : stringValue
        if visited.contains(key) {
            throw ThemeLoadError.invalidTheme("Circular variable reference detected: \(key)")
        }
        guard let ref = vars[key] else {
            throw ThemeLoadError.invalidTheme("Variable reference not found: \(key)")
        }
        visited.insert(key)
        let resolved = try resolveVarRefs(ref, vars: vars, visited: &visited)
        visited.remove(key)
        return resolved
    }
}

private func resolveThemeColors(
    colors: [String: ThemeColorValue],
    vars: [String: ThemeColorValue]
) throws -> [String: ResolvedColor] {
    var resolved: [String: ResolvedColor] = [:]
    for (key, value) in colors {
        var visited: Set<String> = []
        resolved[key] = try resolveVarRefs(value, vars: vars, visited: &visited)
    }
    return resolved
}

private func getBuiltinThemeData() -> [String: ThemeJson] {
    if let cached = themeState.builtinThemes {
        return cached
    }

    let decoder = JSONDecoder()
    var builtins: [String: ThemeJson] = [:]
    let names = ["dark", "light"]

    for name in names {
        if let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "theme"),
           let data = try? Data(contentsOf: url),
           let json = try? decoder.decode(ThemeJson.self, from: data) {
            builtins[name] = json
            continue
        }
        let fallbackPath = (getThemesDir() as NSString).appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
           let json = try? decoder.decode(ThemeJson.self, from: data) {
            builtins[name] = json
        }
    }

    themeState.builtinThemes = builtins
    return builtins
}

private func validateThemeJson(_ json: ThemeJson, name: String) throws {
    let required = Set(ThemeColor.allCases.map { $0.rawValue } + ThemeBg.allCases.map { $0.rawValue })
    let present = Set(json.colors.keys)
    let missing = required.subtracting(present).sorted()
    if !missing.isEmpty {
        var message = "Invalid theme \"\(name)\":\n\nMissing required color tokens:\n"
        message += missing.map { "  - \($0)" }.joined(separator: "\n")
        message += "\n\nPlease add these colors to your theme's \"colors\" object."
        message += "\nSee the built-in themes (dark.json, light.json) for reference values."
        throw ThemeLoadError.invalidTheme(message)
    }
}

private func loadThemeJson(_ name: String) throws -> ThemeJson {
    let builtins = getBuiltinThemeData()
    if let builtin = builtins[name] {
        return builtin
    }

    let customDir = getCustomThemesDir()
    let path = (customDir as NSString).appendingPathComponent("\(name).json")
    guard FileManager.default.fileExists(atPath: path) else {
        throw ThemeLoadError.missingTheme(name)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let json = try JSONDecoder().decode(ThemeJson.self, from: data)
    try validateThemeJson(json, name: name)
    return json
}

private func createTheme(_ themeJson: ThemeJson, mode: ColorMode?) throws -> Theme {
    let colorMode = mode ?? detectColorMode()
    let vars = themeJson.vars ?? [:]
    let resolved = try resolveThemeColors(colors: themeJson.colors, vars: vars)

    var fgColors: [ThemeColor: String] = [:]
    var bgColors: [ThemeBg: String] = [:]

    for (key, value) in resolved {
        if let bgKey = ThemeBg(rawValue: key) {
            bgColors[bgKey] = try bgAnsi(value, colorMode)
        } else if let fgKey = ThemeColor(rawValue: key) {
            fgColors[fgKey] = try fgAnsi(value, colorMode)
        }
    }

    return Theme(fgColors: fgColors, bgColors: bgColors, mode: colorMode)
}

private func loadTheme(_ name: String, mode: ColorMode? = nil) throws -> Theme {
    let themeJson = try loadThemeJson(name)
    return try createTheme(themeJson, mode: mode)
}

private func detectTerminalBackground() -> String {
    let env = ProcessInfo.processInfo.environment
    if let colorfgbg = env["COLORFGBG"] {
        let parts = colorfgbg.split(separator: ";")
        if parts.count >= 2, let bg = Int(parts[1]) {
            return bg < 8 ? "dark" : "light"
        }
    }
    return "dark"
}

private func getDefaultTheme() -> String {
    detectTerminalBackground()
}

private final class ThemeState: @unchecked Sendable {
    var theme: Theme = Theme.fallback()
    var builtinThemes: [String: ThemeJson]?
    var currentThemeName: String?
    var themeWatcher: DispatchSourceFileSystemObject?
    var themeWatcherFd: Int32 = -1
    var onThemeChangeCallback: (() -> Void)?
    var themeReloadWorkItem: DispatchWorkItem?
}

private let themeState = ThemeState()

public var theme: Theme {
    get { themeState.theme }
    set { themeState.theme = newValue }
}

public func initTheme(_ name: String? = nil, enableWatcher: Bool = false) {
    let themeName = name ?? getDefaultTheme()
    themeState.currentThemeName = themeName
    do {
        theme = try loadTheme(themeName)
        if enableWatcher {
            startThemeWatcher()
        }
    } catch {
        themeState.currentThemeName = "dark"
        theme = (try? loadTheme("dark")) ?? Theme.fallback()
    }
}

public func setTheme(_ name: String, enableWatcher: Bool = false) -> (success: Bool, error: String?) {
    themeState.currentThemeName = name
    do {
        theme = try loadTheme(name)
        if enableWatcher {
            startThemeWatcher()
        }
        return (true, nil)
    } catch {
        themeState.currentThemeName = "dark"
        theme = (try? loadTheme("dark")) ?? Theme.fallback()
        return (false, (error as? ThemeLoadError)?.description ?? error.localizedDescription)
    }
}

public func onThemeChange(_ callback: @escaping () -> Void) {
    themeState.onThemeChangeCallback = callback
}

private func startThemeWatcher() {
    stopThemeWatcher()

    guard let themeName = themeState.currentThemeName,
          themeName != "dark",
          themeName != "light" else {
        return
    }

    let customDir = getCustomThemesDir()
    let path = (customDir as NSString).appendingPathComponent("\(themeName).json")
    guard FileManager.default.fileExists(atPath: path) else {
        return
    }

    themeState.themeWatcherFd = open(path, O_EVTONLY)
    guard themeState.themeWatcherFd >= 0 else {
        return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: themeState.themeWatcherFd,
        eventMask: [.write, .delete, .rename],
        queue: DispatchQueue.global()
    )

    source.setEventHandler {
        let flags = source.data
        if flags.contains(.delete) || flags.contains(.rename) {
            themeState.currentThemeName = "dark"
            theme = (try? loadTheme("dark")) ?? Theme.fallback()
            stopThemeWatcher()
            themeState.onThemeChangeCallback?()
            return
        }

        themeState.themeReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard let current = themeState.currentThemeName else { return }
            if let loaded = try? loadTheme(current) {
                theme = loaded
                themeState.onThemeChangeCallback?()
            }
        }
        themeState.themeReloadWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    source.setCancelHandler {
        if themeState.themeWatcherFd >= 0 {
            close(themeState.themeWatcherFd)
            themeState.themeWatcherFd = -1
        }
    }

    themeState.themeWatcher = source
    source.resume()
}

public func stopThemeWatcher() {
    themeState.themeReloadWorkItem?.cancel()
    themeState.themeReloadWorkItem = nil
    if let watcher = themeState.themeWatcher {
        watcher.cancel()
        themeState.themeWatcher = nil
    }
}

public func getAvailableThemes() -> [String] {
    var themes = Set(getBuiltinThemeData().keys)
    let customDir = getCustomThemesDir()
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: customDir) {
        for file in contents where file.hasSuffix(".json") {
            themes.insert(String(file.dropLast(5)))
        }
    }
    return themes.sorted()
}

private func ansi256ToHex(_ index: Int) -> String {
    let basicColors = [
        "#000000", "#800000", "#008000", "#808000", "#000080", "#800080", "#008080", "#c0c0c0",
        "#808080", "#ff0000", "#00ff00", "#ffff00", "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
    ]
    if index < 16 {
        return basicColors[index]
    }
    if index < 232 {
        let cubeIndex = index - 16
        let r = cubeIndex / 36
        let g = (cubeIndex % 36) / 6
        let b = cubeIndex % 6
        let toHex: (Int) -> String = { n in
            let value = n == 0 ? 0 : 55 + n * 40
            return String(format: "%02x", value)
        }
        return "#\(toHex(r))\(toHex(g))\(toHex(b))"
    }
    let gray = 8 + (index - 232) * 10
    let grayHex = String(format: "%02x", gray)
    return "#\(grayHex)\(grayHex)\(grayHex)"
}

public func getResolvedThemeColors(_ themeName: String? = nil) -> [String: String] {
    let name = themeName ?? getDefaultTheme()
    let isLight = name == "light"
    guard let themeJson = try? loadThemeJson(name),
          let resolved = try? resolveThemeColors(colors: themeJson.colors, vars: themeJson.vars ?? [:]) else {
        return [:]
    }

    let defaultText = isLight ? "#000000" : "#e5e5e7"
    var cssColors: [String: String] = [:]

    for (key, value) in resolved {
        if let number = value.number {
            cssColors[key] = ansi256ToHex(number)
        } else if let string = value.string {
            cssColors[key] = string.isEmpty ? defaultText : string
        }
    }
    return cssColors
}

public func isLightTheme(_ themeName: String? = nil) -> Bool {
    (themeName ?? getDefaultTheme()) == "light"
}

public func getThemeExportColors(_ themeName: String? = nil) -> (pageBg: String?, cardBg: String?, infoBg: String?) {
    let name = themeName ?? getDefaultTheme()
    guard let themeJson = try? loadThemeJson(name) else {
        return (nil, nil, nil)
    }

    let vars = themeJson.vars ?? [:]
    let exportSection = themeJson.export
    let page = resolveExportColor(exportSection?.pageBg, vars: vars)
    let card = resolveExportColor(exportSection?.cardBg, vars: vars)
    let info = resolveExportColor(exportSection?.infoBg, vars: vars)
    return (page, card, info)
}

private func resolveExportColor(_ value: ThemeColorValue?, vars: [String: ThemeColorValue]) -> String? {
    guard let value else { return nil }
    switch value {
    case .number(let number):
        return ansi256ToHex(number)
    case .string(let stringValue):
        if stringValue.hasPrefix("$") {
            let key = String(stringValue.dropFirst())
            guard let ref = vars[key] else { return nil }
            return resolveExportColor(ref, vars: vars)
        }
        return stringValue
    }
}

public func highlightCode(_ code: String, lang: String? = nil) -> [String] {
    let adapter = ThemeSyntaxAdapter(theme: theme)
    return SyntaxHighlighter.highlight(code: code, lang: lang, theme: adapter)
}

private struct ThemeSyntaxAdapter: SyntaxTheme {
    let theme: Theme

    func plain(_ text: String) -> String { theme.fg(.mdCodeBlock, text) }
    func keyword(_ text: String) -> String { theme.fg(.syntaxKeyword, text) }
    func builtIn(_ text: String) -> String { theme.fg(.syntaxType, text) }
    func literal(_ text: String) -> String { theme.fg(.syntaxNumber, text) }
    func number(_ text: String) -> String { theme.fg(.syntaxNumber, text) }
    func string(_ text: String) -> String { theme.fg(.syntaxString, text) }
    func comment(_ text: String) -> String { theme.fg(.syntaxComment, text) }
    func function(_ text: String) -> String { theme.fg(.syntaxFunction, text) }
    func type(_ text: String) -> String { theme.fg(.syntaxType, text) }
    func variable(_ text: String) -> String { theme.fg(.syntaxVariable, text) }
    func operatorToken(_ text: String) -> String { theme.fg(.syntaxOperator, text) }
    func punctuation(_ text: String) -> String { theme.fg(.syntaxPunctuation, text) }
}

public func getLanguageFromPath(_ filePath: String) -> String? {
    let ext = (filePath as NSString).pathExtension.lowercased()
    if ext.isEmpty { return nil }

    let extToLang: [String: String] = [
        "ts": "typescript",
        "tsx": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "go": "go",
        "java": "java",
        "kt": "kotlin",
        "swift": "swift",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
        "php": "php",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "fish",
        "ps1": "powershell",
        "sql": "sql",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "sass": "sass",
        "less": "less",
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "md": "markdown",
        "markdown": "markdown",
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "cmake": "cmake",
        "lua": "lua",
        "perl": "perl",
        "r": "r",
        "scala": "scala",
        "clj": "clojure",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "ml": "ocaml",
        "vim": "vim",
        "graphql": "graphql",
        "proto": "protobuf",
        "tf": "hcl",
        "hcl": "hcl",
    ]

    return extToLang[ext]
}

public func getMarkdownTheme() -> MarkdownTheme {
    MarkdownTheme(
        heading: { theme.fg(.mdHeading, $0) },
        link: { theme.fg(.mdLink, $0) },
        linkUrl: { theme.fg(.mdLinkUrl, $0) },
        code: { theme.fg(.mdCode, $0) },
        codeBlock: { theme.fg(.mdCodeBlock, $0) },
        codeBlockBorder: { theme.fg(.mdCodeBlockBorder, $0) },
        quote: { theme.fg(.mdQuote, $0) },
        quoteBorder: { theme.fg(.mdQuoteBorder, $0) },
        hr: { theme.fg(.mdHr, $0) },
        listBullet: { theme.fg(.mdListBullet, $0) },
        bold: { theme.bold($0) },
        italic: { theme.italic($0) },
        strikethrough: { theme.strikethrough($0) },
        underline: { theme.underline($0) },
        highlightCode: { code, lang in
            highlightCode(code, lang: lang)
        }
    )
}

public func getSelectListTheme() -> SelectListTheme {
    SelectListTheme(
        selectedPrefix: { theme.fg(.accent, $0) },
        selectedText: { theme.fg(.accent, $0) },
        description: { theme.fg(.muted, $0) },
        scrollInfo: { theme.fg(.muted, $0) },
        noMatch: { theme.fg(.muted, $0) }
    )
}

public func getEditorTheme() -> EditorTheme {
    EditorTheme(borderColor: { theme.fg(.borderMuted, $0) }, selectList: getSelectListTheme())
}

public func getSettingsListTheme() -> SettingsListTheme {
    SettingsListTheme(
        label: { text, selected in selected ? theme.fg(.accent, text) : text },
        value: { text, selected in selected ? theme.fg(.accent, text) : theme.fg(.muted, text) },
        description: { theme.fg(.dim, $0) },
        cursor: theme.fg(.accent, "→ "),
        hint: { theme.fg(.dim, $0) }
    )
}
