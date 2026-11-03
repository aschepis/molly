import XCTest
@testable import Molly

final class LabelPolicyTests: XCTestCase {
    func testDisabledFilterRedactsEverything() {
        let f = LabelFilter.disabled
        XCTAssertFalse(f.enabled)
        XCTAssertEqual(f.label("github.com"), LabelPolicy.redacted)
    }

    func testDenylistPassesUnmatchedAndRedactsMatched() throws {
        let f = try LabelPolicy(enabled: true, mode: .denylist, patterns: ["*.bank.com", "secret.io"]).compile()
        XCTAssertEqual(f.label("GitHub.com"), "github.com")
        XCTAssertEqual(f.label("online.bank.com"), LabelPolicy.redacted)
        XCTAssertEqual(f.label("secret.io"), LabelPolicy.redacted)
        XCTAssertEqual(f.label("www.secret.io"), LabelPolicy.redacted)
        XCTAssertEqual(f.label("notsecret.io"), "notsecret.io")
        XCTAssertEqual(f.label("  spaced.example  "), "spaced.example")
        XCTAssertEqual(f.label(""), LabelPolicy.other)
    }

    func testAllowlistOnlyPassesMatched() throws {
        let f = try LabelPolicy(enabled: true, mode: .allowlist, patterns: ["github.com", "*.google.com"]).compile()
        XCTAssertEqual(f.label("github.com"), "github.com")
        XCTAssertEqual(f.label("api.github.com"), "api.github.com")
        XCTAssertEqual(f.label("docs.google.com"), "docs.google.com")
        XCTAssertEqual(f.label("google.com"), LabelPolicy.other)
        XCTAssertEqual(f.label("evil.com"), LabelPolicy.other)
    }

    func testWildcardInMiddle() throws {
        let f = try LabelPolicy(enabled: true, mode: .allowlist, patterns: ["aschepis/*"]).compile()
        XCTAssertEqual(f.label("aschepis/molly"), "aschepis/molly")
        XCTAssertEqual(f.label("other/molly"), LabelPolicy.other)
    }

    func testHashIsStableAndSalted() throws {
        let a = try LabelPolicy(enabled: true, hash: true, salt: "one").compile()
        let b = try LabelPolicy(enabled: true, hash: true, salt: "two").compile()
        XCTAssertEqual(a.label("x.com"), a.label("X.COM"))
        XCTAssertNotEqual(a.label("x.com"), b.label("x.com"))
        XCTAssertEqual(a.label("x.com").count, 14)
        XCTAssertTrue(a.label("x.com").hasPrefix("h_"))
    }

    func testLabelsMergesAndFoldsCardinality() throws {
        let f = try LabelPolicy(enabled: true, mode: .denylist, patterns: ["deny.me"], maxCardinality: 2).compile()
        let got = f.labels(["A.com": 5, "a.com": 1, "b.com": 4, "c.com": 3, "d.com": 1, "deny.me": 2])
        XCTAssertEqual(got, ["a.com": 6, "b.com": 4, LabelPolicy.other: 4, LabelPolicy.redacted: 2])
    }

    func testTopNKeepsAllWhenUnlimited() {
        XCTAssertEqual(LabelFilter.topN(["a": 1, "b": 2], 0), ["a": 1, "b": 2])
    }

    func testPolicyFromJSONOverridesDefaults() throws {
        let json = try JSONValue.parse(Data(#"{"enabled": true, "mode": "allowlist", "patterns": ["a.com"], "hash": true, "maxCardinality": 5}"#.utf8))
        let p = try LabelPolicy.from(json, defaults: LabelPolicy(enabled: false))
        XCTAssertEqual(p, LabelPolicy(enabled: true, mode: .allowlist, patterns: ["a.com"], hash: true, maxCardinality: 5))
        XCTAssertEqual(try LabelPolicy.from(nil, defaults: LabelPolicy(enabled: true)).enabled, true)
    }

    func testPolicyRejectsBadInput() throws {
        XCTAssertThrowsError(try LabelPolicy.from(try JSONValue.parse(Data(#"{"mode": "sometimes"}"#.utf8))))
        XCTAssertThrowsError(try LabelPolicy.from(try JSONValue.parse(Data(#"{"maxCardinality": -1}"#.utf8))))
        XCTAssertThrowsError(try LabelPolicy.from(try JSONValue.parse(Data(#"{"enabled": "yes"}"#.utf8))))
        XCTAssertThrowsError(try LabelPolicy(patterns: [""]).compile())
    }
}
