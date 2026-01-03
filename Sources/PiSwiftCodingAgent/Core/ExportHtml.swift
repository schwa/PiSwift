import Foundation

public func exportFromFile(_ inputPath: String, _ outputPath: String? = nil) throws -> String {
    let content = try String(contentsOfFile: inputPath, encoding: .utf8)
    let escaped = escapeHtml(content)
    let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Session Export</title>
      <style>
        body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 24px; }
        pre { white-space: pre-wrap; }
      </style>
    </head>
    <body>
      <pre>\(escaped)</pre>
    </body>
    </html>
    """

    let output = outputPath ?? (inputPath as NSString).appendingPathExtension("html") ?? "\(inputPath).html"
    try html.write(toFile: output, atomically: true, encoding: .utf8)
    return output
}

private func escapeHtml(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
