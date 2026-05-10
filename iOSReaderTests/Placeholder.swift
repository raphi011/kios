import Testing

@Suite("Placeholder")
struct PlaceholderTests {
    @Test func suiteCompiles() {
        #expect(1 + 1 == 2)
    }
}
