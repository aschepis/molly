import XCTest
@testable import Molly

/// Unavailable sources are not errors, and a subscription's cost is not spend.
final class DataTruthTests: XCTestCase {
    private func digest(subscription: Bool) -> InsightsDigest {
        var d = InsightsDigest(kind: .day, date: "2026-11-03", user: "adam", host: "mbp",
                               from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600),
                               generatedAt: Date(timeIntervalSince1970: 3600))
        d.scalars = ["claude_cost_usd": 3.5, "molly_collector_errors": 0]
        d.breakdowns = ["claude_cost_by_model": ["claude-sonnet-4-5": 3.5], "collectors_unavailable": ["codex": 1]]
        if subscription { d.scalars["claude_pricing_subscription"] = 1 }
        return d
    }

    func testDigestCallsSubscriptionCostAListPriceEquivalent() {
        let text = digest(subscription: true).markdown()
        XCTAssertTrue(text.contains("Claude list-price equivalent (subscription, not spend): 3.50 USD"), text)
        XCTAssertTrue(text.contains("Claude list-price equivalent (subscription, not spend) by model"), text)
        XCTAssertFalse(text.contains("Claude estimated cost"), text)
    }

    func testDigestKeepsEstimateWordingInListMode() {
        XCTAssertTrue(digest(subscription: false).markdown().contains("Claude estimated cost"))
    }

    func testDigestLabelsAbsentSourcesAsNotAMalfunction() {
        let text = digest(subscription: false).markdown()
        XCTAssertTrue(text.contains("codex 1"), text)
        XCTAssertTrue(text.contains("not a malfunction"), text)
    }

    func testDigestQueriesCoverUnavailableAndPricingMode() {
        let keys = DigestQueries.all.map(\.key)
        XCTAssertTrue(keys.contains("collectors_unavailable"))
        XCTAssertTrue(keys.contains("claude_pricing_subscription"))
    }

    func testPromptRulesOutSpendAdviceAndDataCollectionFixes() {
        let system = InsightsPrompt.system
        XCTAssertTrue(system.contains("list-price equivalent"))
        XCTAssertTrue(system.contains("never recommend reducing spend"))
        XCTAssertTrue(system.contains("never recommend fixing data collection"))
    }

    func testDoctorSeparatesUnavailableFromErrors() throws {
        let json = #"[{"name":"codex","errors":0,"unavailable":true},{"name":"git","errors":0,"unavailable":false},{"name":"mail","errors":3,"unavailable":false}]"#
        let check = try XCTUnwrap(DoctorCommand.collectorsSummary(from: Data(json.utf8)))
        XCTAssertFalse(check.ok)
        XCTAssertTrue(check.detail.contains("erroring: mail"))
        XCTAssertTrue(check.detail.contains("unavailable (source absent, not an error): codex"))

        let onlyAbsent = #"[{"name":"codex","errors":0,"unavailable":true}]"#
        XCTAssertTrue(try XCTUnwrap(DoctorCommand.collectorsSummary(from: Data(onlyAbsent.utf8))).ok)
    }
}
