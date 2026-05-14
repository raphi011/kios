import Testing
@testable import Kios

@Suite("GemmaChatTemplate")
struct GemmaChatTemplateTests {
    @Test("renders Gemma instruct format with system and user turns")
    func render() {
        let out = GemmaChatTemplate.render(system: "You are helpful.", user: "Hello.")
        #expect(out.contains("<start_of_turn>user"))
        #expect(out.contains("<end_of_turn>"))
        #expect(out.contains("<start_of_turn>model"))
        #expect(out.contains("You are helpful."))
        #expect(out.contains("Hello."))
    }

    @Test("does not include system content if empty")
    func emptySystem() {
        let out = GemmaChatTemplate.render(system: "", user: "Hi.")
        #expect(out.contains("Hi."))
        #expect(out.contains("<start_of_turn>user"))
        #expect(out.contains("<start_of_turn>model"))
    }
}
