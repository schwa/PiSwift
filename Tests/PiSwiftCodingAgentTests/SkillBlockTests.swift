import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - parseSkillBlock tests

@Test func parseSkillBlockValidBlock() {
    let text = """
    <skill name="commit" location="/path/to/skills/commit/SKILL.md">
    Instructions for committing code.
    </skill>
    """

    let result = parseSkillBlock(text)

    #expect(result != nil)
    #expect(result?.name == "commit")
    #expect(result?.location == "/path/to/skills/commit/SKILL.md")
    #expect(result?.content == "Instructions for committing code.")
    #expect(result?.userMessage == nil)
}

@Test func parseSkillBlockWithUserMessage() {
    let text = """
    <skill name="review-pr" location="/path/to/skills/review-pr/SKILL.md">
    Instructions for reviewing PRs.
    </skill>

    Please review PR #123
    """

    let result = parseSkillBlock(text)

    #expect(result != nil)
    #expect(result?.name == "review-pr")
    #expect(result?.location == "/path/to/skills/review-pr/SKILL.md")
    #expect(result?.content == "Instructions for reviewing PRs.")
    #expect(result?.userMessage == "Please review PR #123")
}

@Test func parseSkillBlockMultilineContent() {
    let text = """
    <skill name="debug" location="/skills/debug/SKILL.md">
    First line of instructions.
    Second line of instructions.
    Third line with code: `console.log("test")`
    </skill>
    """

    let result = parseSkillBlock(text)

    #expect(result != nil)
    #expect(result?.name == "debug")
    #expect(result?.content.contains("First line") == true)
    #expect(result?.content.contains("Second line") == true)
    #expect(result?.content.contains("Third line") == true)
}

@Test func parseSkillBlockInvalidMissingClosingTag() {
    let text = """
    <skill name="test" location="/path">
    Some content
    """

    let result = parseSkillBlock(text)
    #expect(result == nil)
}

@Test func parseSkillBlockInvalidMissingName() {
    let text = """
    <skill location="/path">
    Some content
    </skill>
    """

    let result = parseSkillBlock(text)
    #expect(result == nil)
}

@Test func parseSkillBlockInvalidMissingLocation() {
    let text = """
    <skill name="test">
    Some content
    </skill>
    """

    let result = parseSkillBlock(text)
    #expect(result == nil)
}

@Test func parseSkillBlockPlainText() {
    let text = "Just some plain text without skill tags"

    let result = parseSkillBlock(text)
    #expect(result == nil)
}

@Test func parseSkillBlockEmptyContent() {
    let text = """
    <skill name="empty" location="/path/empty">

    </skill>
    """

    let result = parseSkillBlock(text)

    #expect(result != nil)
    #expect(result?.name == "empty")
    #expect(result?.content == "")
}

@Test func parseSkillBlockWithMultilineUserMessage() {
    let text = """
    <skill name="analyze" location="/skills/analyze/SKILL.md">
    Analysis instructions here.
    </skill>

    Please analyze this code:
    ```swift
    func hello() {
        print("Hello")
    }
    ```
    """

    let result = parseSkillBlock(text)

    #expect(result != nil)
    #expect(result?.name == "analyze")
    #expect(result?.userMessage?.contains("Please analyze") == true)
    #expect(result?.userMessage?.contains("func hello") == true)
}
