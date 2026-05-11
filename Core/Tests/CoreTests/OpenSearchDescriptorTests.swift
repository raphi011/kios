import Testing
import Foundation
@testable import Core

@Suite("OpenSearchDescriptor")
struct OpenSearchDescriptorTests {
    @Test func substitutesSearchTermsPlaceholder() {
        let descriptor = OpenSearchDescriptor(
            templateURL: URL(string: "https://example.com/opds/search/{searchTerms}")!
        )
        let resolved = descriptor.resolve(query: "Dune")
        #expect(resolved?.absoluteString == "https://example.com/opds/search/Dune")
    }

    @Test func percentEncodesSpacesAndSpecialChars() {
        let descriptor = OpenSearchDescriptor(
            templateURL: URL(string: "https://example.com/search/{searchTerms}")!
        )
        let resolved = descriptor.resolve(query: "Hello World & Foo")
        #expect(resolved?.absoluteString == "https://example.com/search/Hello%20World%20%26%20Foo")
    }

    @Test func substitutesInQueryParameter() {
        let descriptor = OpenSearchDescriptor(
            templateURL: URL(string: "https://example.com/search?q={searchTerms}&page=1")!
        )
        let resolved = descriptor.resolve(query: "frank herbert")
        #expect(resolved?.absoluteString == "https://example.com/search?q=frank%20herbert&page=1")
    }

    @Test func returnsNilWhenTemplateHasNoPlaceholder() {
        let descriptor = OpenSearchDescriptor(
            templateURL: URL(string: "https://example.com/search")!
        )
        #expect(descriptor.resolve(query: "anything") == nil)
    }

    @Test func emptyQueryProducesNil() {
        let descriptor = OpenSearchDescriptor(
            templateURL: URL(string: "https://example.com/search/{searchTerms}")!
        )
        #expect(descriptor.resolve(query: "") == nil)
        #expect(descriptor.resolve(query: "   ") == nil)
    }
}
