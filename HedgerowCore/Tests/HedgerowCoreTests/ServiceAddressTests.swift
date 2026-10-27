import Foundation
import Testing
@testable import HedgerowCore

@Suite struct ServiceAddressTests {
    @Test(arguments: [
        ("https://vole.example.com", "https://vole.example.com"),
        ("  vole.example.com  ", "https://vole.example.com"),
        ("http://10.0.3.26:3001", "http://10.0.3.26:3001"),
        ("10.0.3.26:3001", "https://10.0.3.26:3001"),
        ("https://example.com/vole/", "https://example.com/vole"),
        ("HTTPS://Vole.Example.com///", "HTTPS://Vole.Example.com"),
    ])
    func acceptsAddresses(input: String, expected: String) {
        #expect(parseServiceAddress(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "https://", "ftp://example.com", "https://exa mple.com",
                      "https://example.com?x=1", "https://example.com#top", "http://"])
    func refusesNonAddresses(input: String) {
        #expect(parseServiceAddress(input) == nil)
    }

    @Test func publicHttpParsesButIsNotAllowed() throws {
        let url = try #require(parseServiceAddress("http://vole.example.com"))
        #expect(!isAllowedBaseURL(url))
    }
}
