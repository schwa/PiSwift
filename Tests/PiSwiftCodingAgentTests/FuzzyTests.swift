import Testing
import PiSwiftCodingAgent

@Test func fuzzyMatchEmptyQuery() {
    let result = fuzzyMatch("", "anything")
    #expect(result.matches)
    #expect(result.score == 0)
}

@Test func fuzzyMatchQueryLongerThanText() {
    let result = fuzzyMatch("longquery", "short")
    #expect(!result.matches)
}

@Test func fuzzyMatchExactMatchScore() {
    let result = fuzzyMatch("test", "test")
    #expect(result.matches)
    #expect(result.score < 0)
}

@Test func fuzzyMatchOrder() {
    #expect(fuzzyMatch("abc", "aXbXc").matches)
    #expect(!fuzzyMatch("abc", "cba").matches)
}

@Test func fuzzyMatchCaseInsensitive() {
    #expect(fuzzyMatch("ABC", "abc").matches)
    #expect(fuzzyMatch("abc", "ABC").matches)
}

@Test func fuzzyMatchConsecutiveBetter() {
    let consecutive = fuzzyMatch("foo", "foobar")
    let scattered = fuzzyMatch("foo", "f_o_o_bar")
    #expect(consecutive.matches)
    #expect(scattered.matches)
    #expect(consecutive.score < scattered.score)
}

@Test func fuzzyMatchWordBoundaryScore() {
    let boundary = fuzzyMatch("fb", "foo-bar")
    let notBoundary = fuzzyMatch("fb", "afbx")
    #expect(boundary.matches)
    #expect(notBoundary.matches)
    #expect(boundary.score < notBoundary.score)
}

@Test func fuzzyFilterEmptyQuery() {
    let items = ["apple", "banana", "cherry"]
    let result = fuzzyFilter(items, "", getText: { $0 })
    #expect(result == items)
}

@Test func fuzzyFilterMatches() {
    let items = ["apple", "banana", "cherry"]
    let result = fuzzyFilter(items, "an", getText: { $0 })
    #expect(result.contains("banana"))
    #expect(!result.contains("apple"))
    #expect(!result.contains("cherry"))
}

@Test func fuzzyFilterSortOrder() {
    let items = ["a_p_p", "app", "application"]
    let result = fuzzyFilter(items, "app", getText: { $0 })
    #expect(result.first == "app")
}

@Test func fuzzyFilterCustomGetter() {
    struct Item: Equatable {
        let name: String
        let id: Int
    }
    let items = [Item(name: "foo", id: 1), Item(name: "bar", id: 2), Item(name: "foobar", id: 3)]
    let result = fuzzyFilter(items, "foo", getText: { $0.name })
    #expect(result.count == 2)
    #expect(result.map(\.name).contains("foo"))
    #expect(result.map(\.name).contains("foobar"))
}
