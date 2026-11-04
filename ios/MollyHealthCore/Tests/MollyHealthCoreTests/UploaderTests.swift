import XCTest
@testable import MollyHealthCore

final class FakeSession: HTTPSession, @unchecked Sendable {
    enum Step {
        case reply(Int, String)
        case fail(Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? .reply(200, "{}") : steps.removeFirst()
        }
        switch step {
        case .fail(let error): throw error
        case .reply(let status, let body):
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            return (Data(body.utf8), response ?? HTTPURLResponse())
        }
    }
}

final class UploaderTests: XCTestCase {
    private let server = ServerConfig(baseURL: URL(string: "http://mac.local:9765") ?? URL(fileURLWithPath: "/"), token: "secret")
    private let item = UploadItem(date: "2026-11-03", body: Data("{}".utf8))

    private func result(_ steps: [FakeSession.Step]) async -> (UploadResult, FakeSession) {
        let session = FakeSession(steps)
        let uploader = Uploader(session: session)
        let out = await uploader.submit([item], to: server, force: true)
        return (out.first?.result ?? .debounced, session)
    }

    func testAcceptedReplyIsParsedAndRequestIsAuthorised() async throws {
        let (outcome, session) = await result([.reply(200, #"{"accepted": 3, "rejected": {"bad_type": 1}}"#)])
        XCTAssertEqual(outcome, .sent(PostReply(status: 200, accepted: 3, rejected: ["bad_type": 1])))
        let request = try XCTUnwrap(session.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://mac.local:9765/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testStatusCodesMapToFailures() async {
        let cases: [(Int, UploadFailure)] = [
            (401, .unauthorized), (413, .payloadTooLarge), (503, .collectorDisabled), (403, .forbidden), (500, .server(500)),
        ]
        for (status, failure) in cases {
            let (outcome, _) = await result([.reply(status, "")])
            XCTAssertEqual(outcome, .failed(failure), "status \(status)")
        }
    }

    func testTimeoutIsReportedAsTimeout() async {
        let (outcome, _) = await result([.fail(URLError(.timedOut))])
        XCTAssertEqual(outcome, .failed(.timeout))
    }

    func testPostsWithinTheDebounceWindowAreSkippedUnlessForced() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let session = FakeSession([])
        let uploader = Uploader(session: session, now: { clock.now })
        _ = await uploader.submit([item], to: server, force: false)
        clock.advance(60)
        let skipped = await uploader.submit([item], to: server, force: false)
        XCTAssertEqual(skipped.first?.result, .debounced)
        XCTAssertEqual(session.requests.count, 1)
        let forced = await uploader.submit([item], to: server, force: true)
        XCTAssertEqual(session.requests.count, 2)
        XCTAssertNotEqual(forced.first?.result, .debounced)
        clock.advance(Uploader.debounceInterval + 1)
        _ = await uploader.submit([item], to: server, force: false)
        XCTAssertEqual(session.requests.count, 3)
    }

    func testBatchStopsAtAFailureThatWouldRepeat() async {
        let session = FakeSession([.reply(401, "")])
        let uploader = Uploader(session: session)
        let out = await uploader.submit([item, item, item], to: server, force: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(session.requests.count, 1)
    }

    func testBatchContinuesPastAnOversizedDay() async {
        let session = FakeSession([.reply(413, ""), .reply(200, "{}")])
        let uploader = Uploader(session: session)
        let out = await uploader.submit([item, item], to: server, force: true)
        XCTAssertEqual(out.count, 2)
    }

    func testStatusEndpointOutcomes() async {
        let cases: [(Int, StatusOutcome)] = [(404, .notReported), (401, .badToken), (503, .collectorDisabled)]
        for (status, expected) in cases {
            let client = PostClient(session: FakeSession([.reply(status, "")]), server: server)
            let outcome = await client.fetchStatus()
            XCTAssertEqual(outcome, expected)
        }
        let ok = await PostClient(session: FakeSession([.reply(200, #"{"a":1}"#)]), server: server).fetchStatus()
        XCTAssertEqual(ok, .ok(#"{"a":1}"#))
    }

    func testHealthzMustAnswerOk() async {
        let good = await PostClient(session: FakeSession([.reply(200, "ok\n")]), server: server).checkHealthz()
        guard case .success = good else { return XCTFail("expected success") }
        let bad = await PostClient(session: FakeSession([.reply(200, "nope")]), server: server).checkHealthz()
        guard case .failure = bad else { return XCTFail("expected failure") }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class BackfillPlannerTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
        return c
    }()

    private func keys(_ dates: [Date]) -> [String] { dates.map { DayKey.string(for: $0, calendar: calendar) } }
    private let noon = ISO8601DateFormatter().date(from: "2026-11-03T17:00:00Z") ?? Date()

    func testBackfillListsDaysOldestFirstEndingToday() {
        let days = keys(BackfillPlanner.days(count: 3, endingOn: noon, calendar: calendar))
        XCTAssertEqual(days, ["2026-11-01", "2026-11-02", "2026-11-03"])
    }

    func testBackfillCrossesMonthAndClampsCount() {
        let days = keys(BackfillPlanner.days(count: 5, endingOn: noon, calendar: calendar))
        XCTAssertEqual(days.first, "2026-10-30")
        XCTAssertEqual(BackfillPlanner.days(count: 0, endingOn: noon, calendar: calendar).count, 1)
        XCTAssertEqual(BackfillPlanner.days(count: 10_000, endingOn: noon, calendar: calendar).count, BackfillPlanner.maxDays)
    }

    func testRefreshAddsYesterdayOnlyWhenTheDateChanged() {
        XCTAssertEqual(keys(BackfillPlanner.daysToRefresh(today: noon, lastPostedDay: "2026-11-02", calendar: calendar)),
                       ["2026-11-02", "2026-11-03"])
        XCTAssertEqual(keys(BackfillPlanner.daysToRefresh(today: noon, lastPostedDay: nil, calendar: calendar)),
                       ["2026-11-02", "2026-11-03"])
        XCTAssertEqual(keys(BackfillPlanner.daysToRefresh(today: noon, lastPostedDay: "2026-11-03", calendar: calendar)),
                       ["2026-11-03"])
    }
}
