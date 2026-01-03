import Testing
import PiSwiftCodingAgent

@Test func parseArgsVersionFlag() {
    let result = parseArgs(["--version"])
    #expect(result.version == true)

    let shortResult = parseArgs(["-v"])
    #expect(shortResult.version == true)

    let mixed = parseArgs(["--version", "--help", "some message"])
    #expect(mixed.version == true)
    #expect(mixed.help == true)
    #expect(mixed.messages.contains("some message"))
}

@Test func parseArgsHelpFlag() {
    let result = parseArgs(["--help"])
    #expect(result.help == true)

    let shortResult = parseArgs(["-h"])
    #expect(shortResult.help == true)
}

@Test func parseArgsPrintFlag() {
    let result = parseArgs(["--print"])
    #expect(result.print == true)

    let shortResult = parseArgs(["-p"])
    #expect(shortResult.print == true)
}

@Test func parseArgsContinueFlag() {
    let result = parseArgs(["--continue"])
    #expect(result.continue == true)

    let shortResult = parseArgs(["-c"])
    #expect(shortResult.continue == true)
}

@Test func parseArgsResumeFlag() {
    let result = parseArgs(["--resume"])
    #expect(result.resume == true)

    let shortResult = parseArgs(["-r"])
    #expect(shortResult.resume == true)
}

@Test func parseArgsWithValues() {
    #expect(parseArgs(["--provider", "openai"]).provider == "openai")
    #expect(parseArgs(["--model", "gpt-4o"]).model == "gpt-4o")
    #expect(parseArgs(["--api-key", "sk-test-key"]).apiKey == "sk-test-key")
    #expect(parseArgs(["--system-prompt", "You are helpful"]).systemPrompt == "You are helpful")
    #expect(parseArgs(["--append-system-prompt", "More"]).appendSystemPrompt == "More")
    #expect(parseArgs(["--mode", "json"]).mode == .json)
    #expect(parseArgs(["--mode", "rpc"]).mode == .rpc)
    #expect(parseArgs(["--session", "/path/session.jsonl"]).session == "/path/session.jsonl")
    #expect(parseArgs(["--export", "session.jsonl"]).export == "session.jsonl")
    #expect(parseArgs(["--thinking", "high"]).thinking == .high)

    let models = parseArgs(["--models", "gpt-4o,claude-sonnet,gemini-pro"]).models
    #expect(models == ["gpt-4o", "claude-sonnet", "gemini-pro"])
}

@Test func parseArgsNoSessionFlag() {
    #expect(parseArgs(["--no-session"]).noSession == true)
}

@Test func parseArgsHookFlags() {
    let single = parseArgs(["--hook", "./my-hook.ts"])
    #expect(single.hooks == ["./my-hook.ts"])

    let multiple = parseArgs(["--hook", "./hook1.ts", "--hook", "./hook2.ts"])
    #expect(multiple.hooks == ["./hook1.ts", "./hook2.ts"])
}

@Test func parseArgsMessagesAndFiles() {
    let text = parseArgs(["hello", "world"])
    #expect(text.messages == ["hello", "world"])

    let files = parseArgs(["@README.md", "@src/main.ts"])
    #expect(files.fileArgs == ["README.md", "src/main.ts"])

    let mixed = parseArgs(["@file.txt", "explain this", "@image.png"])
    #expect(mixed.fileArgs == ["file.txt", "image.png"])
    #expect(mixed.messages == ["explain this"])

    let unknown = parseArgs(["--unknown-flag", "message"])
    #expect(unknown.messages == ["message"])
}

@Test func parseArgsComplex() {
    let result = parseArgs([
        "--provider", "anthropic",
        "--model", "claude-sonnet",
        "--print",
        "--thinking", "high",
        "@prompt.md",
        "Do the task",
    ])
    #expect(result.provider == "anthropic")
    #expect(result.model == "claude-sonnet")
    #expect(result.print == true)
    #expect(result.thinking == .high)
    #expect(result.fileArgs == ["prompt.md"])
    #expect(result.messages == ["Do the task"])
}
