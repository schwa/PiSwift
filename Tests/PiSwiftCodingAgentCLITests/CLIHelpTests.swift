import Foundation
import Testing
@testable import PiSwiftCodingAgentCLI

enum CLIHelpTestError: LocalizedError, Sendable {
    case missingFixture(name: String)

    var errorDescription: String? {
        switch self {
        case let .missingFixture(name):
            return "Missing fixture \(name)"
        }
    }
}

@Test func cliHelpSnapshot() throws {
    let help = PiCodingAgentCLI.helpMessage(for: PiCodingAgentCLI.self, includeHidden: false, columns: 80)
    let expected = try loadFixture(named: "cli-help.txt")
    #expect(normalize(help) == normalize(expected))
}

private func loadFixture(named name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures") else {
        throw CLIHelpTestError.missingFixture(name: name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func normalize(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
