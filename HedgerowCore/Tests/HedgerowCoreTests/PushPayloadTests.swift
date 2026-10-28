import Foundation
import Testing
@testable import HedgerowCore

@Suite struct PushPayloadTests {
    private let tag = "AbCdEfGhIjKlMnOpQrStUv"

    private func hr(_ fields: [String: Any]) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title-loc-key": "HR_PUSH_TITLE"], "mutable-content": 1], "hr": fields]
    }

    @Test func versionOneAlertWithARef() {
        let payload = PushPayload.parse(hr(["v": 1, "k": "alert", "t": tag, "r": "ref_123-x"]))
        #expect(payload == .v1(HedgerowPush(kind: .alert, tag: tag, ref: "ref_123-x")))
    }

    @Test func versionOneSyncHasNoRef() {
        let payload = PushPayload.parse(hr(["v": 1, "k": "sync", "t": tag]))
        #expect(payload == .v1(HedgerowPush(kind: .sync, tag: tag, ref: nil)))
    }

    @Test func aKindFromALaterRelayIsKept() {
        let payload = PushPayload.parse(hr(["v": 1, "k": "digest", "t": tag, "r": "abc"]))
        #expect(payload == .v1(HedgerowPush(kind: .other("digest"), tag: tag, ref: "abc")))
    }

    @Test func aPayloadReadFromJSONParsesToo() throws {
        let json = #"{"aps":{"mutable-content":1},"hr":{"v":1,"k":"alert","t":"\#(tag)","r":"abc"}}"#
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        #expect(PushPayload.parse(object) == .v1(HedgerowPush(kind: .alert, tag: tag, ref: "abc")))
    }

    @Test func anUnknownVersionIsOnlyASyncNow() {
        // Nothing is read from a format this version does not know, even when the other fields look right.
        #expect(PushPayload.parse(hr(["v": 2, "k": "alert", "t": tag, "r": "abc"])) == .unsupportedVersion)
        #expect(PushPayload.parse(hr(["v": 99])) == .unsupportedVersion)
        #expect(PushPayload.parse(hr(["v": 0, "k": "alert", "t": tag])) == .unsupportedVersion)
    }

    @Test func missingOrWrongFieldsAreMalformed() {
        let cases: [[AnyHashable: Any]] = [
            [:],
            ["aps": ["alert": "x"]],
            ["hr": "nope"],
            hr([:]),
            hr(["k": "alert", "t": tag]),
            hr(["v": "1", "k": "alert", "t": tag]),
            hr(["v": 1, "t": tag]),
            hr(["v": 1, "k": "alert"]),
            hr(["v": 1, "k": "", "t": tag]),
            hr(["v": 1, "k": 7, "t": tag]),
            hr(["v": 1, "k": "alert", "t": 5]),
            hr(["v": 1, "k": "alert", "t": ""]),
            hr(["v": 1, "k": "alert", "t": tag, "r": 12]),
        ]
        for (index, userInfo) in cases.enumerated() {
            #expect(PushPayload.parse(userInfo) == .malformed, "case \(index)")
        }
    }

    @Test func aTagOrRefThatCouldNotBeAKeyIsMalformed() {
        let bad = ["a/b", "../x", "a b", "https://evil.example/x", "a?b=1", "a%2Fb", String(repeating: "a", count: 65), "é"]
        for value in bad {
            #expect(PushPayload.parse(hr(["v": 1, "k": "alert", "t": value, "r": "abc"])) == .malformed, "tag \(value)")
            #expect(PushPayload.parse(hr(["v": 1, "k": "alert", "t": tag, "r": value])) == .malformed, "ref \(value)")
        }
    }
}

@Suite struct PushTagTests {
    @Test func aGeneratedTagIs22UnpaddedURLSafeCharacters() {
        for _ in 0..<50 {
            let tag = PushTag.generate()
            #expect(tag.count == 22)
            #expect(PushTag.isWellFormed(tag))
            #expect(!tag.contains("=") && !tag.contains("+") && !tag.contains("/"))
        }
    }

    @Test func tagsDiffer() {
        #expect(Set((0..<50).map { _ in PushTag.generate() }).count == 50)
    }

    @Test func onlyTheGeneratedShapeIsWellFormed() {
        #expect(!PushTag.isWellFormed(""))
        #expect(!PushTag.isWellFormed("short"))
        #expect(!PushTag.isWellFormed(String(repeating: "a", count: 23)))
        #expect(!PushTag.isWellFormed("AbCdEfGhIjKlMnOpQrSt+/"))
        #expect(!PushTag.isWellFormed("AbCdEfGhIjKlMnOpQrSt=="))
        #expect(PushTag.isWellFormed("AbCdEfGhIjKlMnOpQrS-_9"))
    }
}
