public typealias KeyId = String

/// Helper for building key identifiers without a UI dependency.
public enum Key {
    // Special keys
    public static let escape: KeyId = "escape"
    public static let esc: KeyId = "esc"
    public static let enter: KeyId = "enter"
    public static let `return`: KeyId = "return"
    public static let tab: KeyId = "tab"
    public static let space: KeyId = "space"
    public static let backspace: KeyId = "backspace"
    public static let delete: KeyId = "delete"
    public static let home: KeyId = "home"
    public static let end: KeyId = "end"
    public static let up: KeyId = "up"
    public static let down: KeyId = "down"
    public static let left: KeyId = "left"
    public static let right: KeyId = "right"

    // Symbol keys
    public static let backtick: KeyId = "`"
    public static let hyphen: KeyId = "-"
    public static let equals: KeyId = "="
    public static let leftbracket: KeyId = "["
    public static let rightbracket: KeyId = "]"
    public static let backslash: KeyId = "\\"
    public static let semicolon: KeyId = ";"
    public static let quote: KeyId = "'"
    public static let comma: KeyId = ","
    public static let period: KeyId = "."
    public static let slash: KeyId = "/"
    public static let exclamation: KeyId = "!"
    public static let at: KeyId = "@"
    public static let hash: KeyId = "#"
    public static let dollar: KeyId = "$"
    public static let percent: KeyId = "%"
    public static let caret: KeyId = "^"
    public static let ampersand: KeyId = "&"
    public static let asterisk: KeyId = "*"
    public static let leftparen: KeyId = "("
    public static let rightparen: KeyId = ")"
    public static let underscore: KeyId = "_"
    public static let plus: KeyId = "+"
    public static let pipe: KeyId = "|"
    public static let tilde: KeyId = "~"
    public static let leftbrace: KeyId = "{"
    public static let rightbrace: KeyId = "}"
    public static let colon: KeyId = ":"
    public static let lessthan: KeyId = "<"
    public static let greaterthan: KeyId = ">"
    public static let question: KeyId = "?"

    // Single modifiers
    public static func ctrl(_ key: KeyId) -> KeyId { "ctrl+\(key)" }
    public static func shift(_ key: KeyId) -> KeyId { "shift+\(key)" }
    public static func alt(_ key: KeyId) -> KeyId { "alt+\(key)" }

    // Combined modifiers
    public static func ctrlShift(_ key: KeyId) -> KeyId { "ctrl+shift+\(key)" }
    public static func shiftCtrl(_ key: KeyId) -> KeyId { "shift+ctrl+\(key)" }
    public static func ctrlAlt(_ key: KeyId) -> KeyId { "ctrl+alt+\(key)" }
    public static func altCtrl(_ key: KeyId) -> KeyId { "alt+ctrl+\(key)" }
    public static func shiftAlt(_ key: KeyId) -> KeyId { "shift+alt+\(key)" }
    public static func altShift(_ key: KeyId) -> KeyId { "alt+shift+\(key)" }

    // Triple modifiers
    public static func ctrlShiftAlt(_ key: KeyId) -> KeyId { "ctrl+shift+alt+\(key)" }
}
