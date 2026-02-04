import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - isSafeCommand tests

@Test func isSafeCommandAllowsBasicReadCommands() {
    #expect(isSafeCommand("ls -la") == true)
    #expect(isSafeCommand("cat file.txt") == true)
    #expect(isSafeCommand("head -n 10 file.txt") == true)
    #expect(isSafeCommand("tail -f log.txt") == true)
    #expect(isSafeCommand("grep pattern file") == true)
    #expect(isSafeCommand("find . -name '*.ts'") == true)
}

@Test func isSafeCommandAllowsGitReadCommands() {
    #expect(isSafeCommand("git status") == true)
    #expect(isSafeCommand("git log --oneline") == true)
    #expect(isSafeCommand("git diff") == true)
    #expect(isSafeCommand("git branch") == true)
}

@Test func isSafeCommandAllowsNpmYarnReadCommands() {
    #expect(isSafeCommand("npm list") == true)
    #expect(isSafeCommand("npm outdated") == true)
    #expect(isSafeCommand("yarn info react") == true)
}

@Test func isSafeCommandAllowsOtherSafeCommands() {
    #expect(isSafeCommand("pwd") == true)
    #expect(isSafeCommand("echo hello") == true)
    #expect(isSafeCommand("wc -l file.txt") == true)
    #expect(isSafeCommand("du -sh .") == true)
    #expect(isSafeCommand("df -h") == true)
}

@Test func isSafeCommandBlocksFileModificationCommands() {
    #expect(isSafeCommand("rm file.txt") == false)
    #expect(isSafeCommand("rm -rf dir") == false)
    #expect(isSafeCommand("mv old new") == false)
    #expect(isSafeCommand("cp src dst") == false)
    #expect(isSafeCommand("mkdir newdir") == false)
    #expect(isSafeCommand("touch newfile") == false)
}

@Test func isSafeCommandBlocksGitWriteCommands() {
    #expect(isSafeCommand("git add .") == false)
    #expect(isSafeCommand("git commit -m 'msg'") == false)
    #expect(isSafeCommand("git push") == false)
    #expect(isSafeCommand("git checkout -b new-branch") == false)
    #expect(isSafeCommand("git reset --hard") == false)
}

@Test func isSafeCommandBlocksPackageManagerInstalls() {
    #expect(isSafeCommand("npm install lodash") == false)
    #expect(isSafeCommand("yarn add react") == false)
    #expect(isSafeCommand("pip install requests") == false)
    #expect(isSafeCommand("brew install node") == false)
}

@Test func isSafeCommandBlocksRedirects() {
    #expect(isSafeCommand("echo hello > file.txt") == false)
    #expect(isSafeCommand("cat foo >> bar") == false)
}

@Test func isSafeCommandBlocksDangerousCommands() {
    #expect(isSafeCommand("sudo rm -rf /") == false)
    #expect(isSafeCommand("kill -9 1234") == false)
    #expect(isSafeCommand("reboot") == false)
}

@Test func isSafeCommandBlocksEditors() {
    #expect(isSafeCommand("vim file.txt") == false)
    #expect(isSafeCommand("nano file.txt") == false)
    #expect(isSafeCommand("code .") == false)
}

@Test func isSafeCommandHandlesLeadingWhitespace() {
    #expect(isSafeCommand("  ls -la") == true)
    #expect(isSafeCommand("  rm file") == false)
}

// MARK: - cleanStepText tests

@Test func cleanStepTextRemovesMarkdownBold() {
    let result = cleanStepText("**bold text**")
    #expect(result == "Bold text")
}

@Test func cleanStepTextRemovesMarkdownItalic() {
    let result = cleanStepText("*italic text*")
    #expect(result == "Italic text")
}

@Test func cleanStepTextRemovesMarkdownCode() {
    let result = cleanStepText("check the `config.json` file")
    #expect(result == "Config.json file")
}

@Test func cleanStepTextRemovesLeadingActionWords() {
    #expect(cleanStepText("Create the new file") == "New file")
    #expect(cleanStepText("Run the tests") == "Tests")
    #expect(cleanStepText("Check the status") == "Status")
}

@Test func cleanStepTextCapitalizesFirstLetter() {
    let result = cleanStepText("update config")
    #expect(result == "Config")
}

@Test func cleanStepTextTruncatesLongText() {
    let longText = "This is a very long step description that exceeds the maximum allowed length for display"
    let result = cleanStepText(longText)
    #expect(result.count == 50)
    #expect(result.hasSuffix("..."))
}

@Test func cleanStepTextNormalizesWhitespace() {
    let result = cleanStepText("multiple   spaces   here")
    #expect(result == "Multiple spaces here")
}

// MARK: - extractTodoItems tests

@Test func extractTodoItemsExtractsNumberedItems() {
    let message = """
    Here's what we'll do:

    1. First step here
    2. Second step here
    3. Third step here
    """

    let items = extractTodoItems(message)
    #expect(items.count == 3)
    #expect(items[0].step == 1)
    #expect(items[0].text.contains("First"))
    #expect(items[0].completed == false)
}

@Test func extractTodoItemsHandlesParenthesisStyleNumbering() {
    let message = """
    1) First item description here
    2) Second item description here
    """

    let items = extractTodoItems(message)
    #expect(items.count == 2)
}

@Test func extractTodoItemsFiltersOutShortItems() {
    let message = """
    1. OK
    2. This is a proper step description
    """

    let items = extractTodoItems(message)
    // Short items like "OK" should be filtered
    #expect(items.count <= 1)
}

@Test func extractTodoItemsFiltersOutCodeLikeItems() {
    let message = """
    1. `npm install`
    2. Run the build process and verify
    """

    let items = extractTodoItems(message)
    // Items starting with backtick should be filtered
    #expect(items.count <= 1)
}

@Test func extractTodoItemsReturnsEmptyForNoNumberedItems() {
    let message = "Just some regular text without numbered items"
    let items = extractTodoItems(message)
    #expect(items.isEmpty)
}

// MARK: - extractDoneSteps tests

@Test func extractDoneStepsExtractsSingleMarker() {
    let message = "I've completed the first step [DONE:1]"
    let steps = extractDoneSteps(message)
    #expect(steps == [1])
}

@Test func extractDoneStepsExtractsMultipleMarkers() {
    let message = "Did steps [DONE:1] and [DONE:2] and [DONE:3]"
    let steps = extractDoneSteps(message)
    #expect(steps == [1, 2, 3])
}

@Test func extractDoneStepsHandlesCaseInsensitivity() {
    let message = "[done:1] [DONE:2] [Done:3]"
    let steps = extractDoneSteps(message)
    #expect(steps == [1, 2, 3])
}

@Test func extractDoneStepsReturnsEmptyWithNoMarkers() {
    let message = "No markers here"
    let steps = extractDoneSteps(message)
    #expect(steps.isEmpty)
}

@Test func extractDoneStepsIgnoresMalformedMarkers() {
    let message = "[DONE:abc] [DONE:] [DONE:1]"
    let steps = extractDoneSteps(message)
    #expect(steps == [1])
}

// MARK: - markCompletedSteps tests

@Test func markCompletedStepsMarksMatchingItems() {
    var items = [
        TodoItem(step: 1, text: "First", completed: false),
        TodoItem(step: 2, text: "Second", completed: false),
        TodoItem(step: 3, text: "Third", completed: false),
    ]

    let count = markCompletedSteps("[DONE:1] [DONE:3]", &items)

    #expect(count == 2)
    #expect(items[0].completed == true)
    #expect(items[1].completed == false)
    #expect(items[2].completed == true)
}

@Test func markCompletedStepsReturnsCountOfMarkersFound() {
    var items = [TodoItem(step: 1, text: "First", completed: false)]

    #expect(markCompletedSteps("[DONE:1]", &items) == 1)

    var items2 = [TodoItem(step: 1, text: "First", completed: false)]
    #expect(markCompletedSteps("no markers", &items2) == 0)
}

@Test func markCompletedStepsIgnoresMarkersForNonExistentSteps() {
    var items = [TodoItem(step: 1, text: "First", completed: false)]

    let count = markCompletedSteps("[DONE:99]", &items)

    #expect(count == 1) // Marker was found
    #expect(items[0].completed == false) // But nothing was marked
}

@Test func markCompletedStepsDoesNotDoubleComplete() {
    var items = [TodoItem(step: 1, text: "First", completed: true)]

    _ = markCompletedSteps("[DONE:1]", &items)
    #expect(items[0].completed == true)
}
