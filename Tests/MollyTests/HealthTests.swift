import XCTest
@testable import Molly

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .current
    return c
}()

private func iso(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
}

private func object(_ json: String) -> [String: JSONValue] {
    (try? JSONValue.parse(Data(json.utf8)))?.objectValue ?? [:]
}

final class HealthPayloadTests: XCTestCase {
    private let now = iso("2026-11-03T12:00:00Z")

    private func parse(_ json: String, maxAge: TimeInterval = HealthLimits.defaultMaxAgeSeconds) -> HealthParseResult? {
        HealthPayloadParser(now: now, maxAge: maxAge, calendar: utc).parse(object(json))
    }

    func testSampleFormAttributesToStartDayAndSleepToWakeDay() throws {
        let result = try XCTUnwrap(parse("""
        {"device":"iPhone","samples":[
          {"type":"steps","start":"2026-11-03T08:00:00Z","end":"2026-11-03T09:00:00Z","value":812,"unit":"count"},
          {"type":"sleep_minutes","start":"2026-11-02T23:30:00Z","end":"2026-11-03T07:00:00Z","value":420,"unit":"min"}]}
        """))
        XCTAssertEqual(result.samples.map { $0.type }, [.steps, .sleepMinutes])
        XCTAssertEqual(result.samples.map { $0.day }, ["2026-11-03", "2026-11-03"])
        XCTAssertEqual(result.samples[0].value, 812)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testTotalsFormReplacesTheDayAndAcceptsStrings() throws {
        let result = try XCTUnwrap(parse(#"{"date":"2026-11-02","totals":{"steps":"8120","stand_hours":9,"bedtime":"23:30"}}"#))
        XCTAssertEqual(result.samples.count, 3)
        XCTAssertTrue(result.samples.allSatisfy { $0.day == "2026-11-02" && $0.replacesDay })
        XCTAssertEqual(result.samples.first { $0.type == .steps }?.value, 8120)
        XCTAssertEqual(result.samples.first { $0.type == .bedtime }?.value, 84600)
    }

    func testRejectsAreCountedNotFatal() throws {
        let result = try XCTUnwrap(parse("""
        {"samples":[
          {"type":"steps","start":"2026-11-03T08:00:00Z","end":"2026-11-03T09:00:00Z","value":5},
          {"type":"nonsense","start":"2026-11-03T08:00:00Z","value":1},
          {"type":"steps","start":"2026-11-03T08:00:00Z","value":"lots"},
          {"type":"steps","start":"2026-11-03T08:00:00Z","value":-4},
          {"type":"steps","start":"yesterday-ish","value":4},
          {"type":"steps","value":4},
          {"type":"steps","start":"2026-10-01T08:00:00Z","end":"2026-10-01T09:00:00Z","value":4}]}
        """))
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.rejected[.badType], 1)
        XCTAssertEqual(result.rejected[.badValue], 2)
        XCTAssertEqual(result.rejected[.badTime], 2)
        XCTAssertEqual(result.rejected[.tooOld], 1)
    }

    func testMaxAgeIsConfigurable() throws {
        let sample = #"{"samples":[{"type":"steps","start":"2026-11-02T08:00:00Z","end":"2026-11-02T09:00:00Z","value":5}]}"#
        XCTAssertEqual(try XCTUnwrap(parse(sample)).samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(parse(sample, maxAge: 3600)).rejected[.tooOld], 1)
        let totals = #"{"date":"2026-10-01","totals":{"steps":5}}"#
        XCTAssertEqual(try XCTUnwrap(parse(totals)).rejected[.tooOld], 1)
    }

    func testBodyWithoutSamplesOrTotalsIsNotAPayload() {
        XCTAssertNil(parse(#"{"device":"iphone"}"#))
    }

    func testUnitsAreNormalized() throws {
        let result = try XCTUnwrap(parse("""
        {"samples":[
          {"type":"body_mass_kg","start":"2026-11-03T08:00:00Z","value":200,"unit":"lb"},
          {"type":"walking_distance_m","start":"2026-11-03T08:00:00Z","end":"2026-11-03T09:00:00Z","value":2,"unit":"km"},
          {"type":"blood_oxygen_ratio","start":"2026-11-03T08:00:00Z","value":97,"unit":"%"},
          {"type":"sleep_minutes","start":"2026-11-03T01:00:00Z","end":"2026-11-03T07:00:00Z","value":6,"unit":"hr"}]}
        """))
        XCTAssertEqual(result.samples[0].value, 90.718474, accuracy: 0.0001)
        XCTAssertEqual(result.samples[1].value, 2000)
        XCTAssertEqual(result.samples[2].value, 0.97, accuracy: 0.0001)
        XCTAssertEqual(result.samples[3].value, 360)
    }

    func testDeviceNamesAreSanitized() {
        XCTAssertEqual(HealthDevice.sanitize("Adam's iPhone 15!"), "adamsiphone15")
        XCTAssertEqual(HealthDevice.sanitize(nil), "unknown")
        XCTAssertEqual(HealthDevice.sanitize("   "), "unknown")
        XCTAssertEqual(HealthDevice.sanitize(String(repeating: "a", count: 80)).count, HealthLimits.maxDeviceLength)
        XCTAssertEqual(HealthDevice.sanitize("watch_series-9"), "watch_series-9")
    }

    // MARK: bedtime math

    func testBedtimeSecondsCountPastMidnight() {
        XCTAssertEqual(HealthTime.bedtimeSeconds(23 * 3600 + 30 * 60), 84600)
        XCTAssertEqual(HealthTime.bedtimeSeconds(1 * 3600 + 15 * 60), 90900)
        XCTAssertEqual(HealthTime.bedtimeSeconds(HealthLimits.bedtimeWrapSeconds), Double(HealthLimits.bedtimeWrapSeconds))
    }

    func testBedtimeSampleBelongsToTheMorningYouWakeUp() throws {
        let late = try XCTUnwrap(parse(#"{"samples":[{"type":"bedtime","value":"2026-11-02T23:30:00Z"}]}"#)).samples
        XCTAssertEqual(late.first?.day, "2026-11-03")
        XCTAssertEqual(late.first?.value, 84600)
        let early = try XCTUnwrap(parse(#"{"samples":[{"type":"bedtime","value":"2026-11-03T01:15:00Z"}]}"#)).samples
        XCTAssertEqual(early.first?.day, "2026-11-03")
        XCTAssertEqual(early.first?.value, 90900)
        let wake = try XCTUnwrap(parse(#"{"samples":[{"type":"wake_time","value":"2026-11-03T07:05:00Z"}]}"#)).samples
        XCTAssertEqual(wake.first?.value, 7 * 3600 + 5 * 60)
    }

    func testBedtimeUsesTheCalendarsTimezone() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let parser = HealthPayloadParser(now: now, maxAge: HealthLimits.defaultMaxAgeSeconds, calendar: newYork)
        let result = parser.parse(object(#"{"samples":[{"type":"bedtime","value":"2026-11-03T04:30:00Z"}]}"#))
        XCTAssertEqual(result?.samples.first?.value, 84600 + 0, "04:30Z is 23:30 the evening before in New York")
        XCTAssertEqual(result?.samples.first?.day, "2026-11-03")
    }
}

final class HealthAggregationTests: XCTestCase {
    private func sample(_ type: HealthType, _ value: Double, key: String = "k", at: TimeInterval = 100,
                        day: String = "2026-11-03", replaces: Bool = false) -> HealthSample {
        HealthSample(type: type, day: day, at: Date(timeIntervalSince1970: at), key: key, value: value, replacesDay: replaces)
    }

    func testSumAddsDistinctSamplesAndDedupesRepeats() {
        var days = HealthDays()
        days.apply(sample(.steps, 100, key: "a"))
        days.apply(sample(.steps, 50, key: "b"))
        days.apply(sample(.steps, 120, key: "a"))
        XCTAssertEqual(days.value(.steps, day: "2026-11-03"), 170)
    }

    func testTotalReplacesWhatTheDayHeld() {
        var days = HealthDays()
        days.apply(sample(.steps, 100, key: "a"))
        days.apply(sample(.steps, 9000, key: "total", replaces: true))
        XCTAssertEqual(days.value(.steps, day: "2026-11-03"), 9000)
    }

    func testLatestKeepsTheNewestAndMaximumKeepsTheLoudest() {
        var days = HealthDays()
        days.apply(sample(.restingHeartRateBpm, 58, at: 200))
        days.apply(sample(.restingHeartRateBpm, 61, at: 100))
        XCTAssertEqual(days.value(.restingHeartRateBpm, day: "2026-11-03"), 58)
        days.apply(sample(.headphoneAudioDb, 70))
        days.apply(sample(.headphoneAudioDb, 82))
        days.apply(sample(.headphoneAudioDb, 75))
        XCTAssertEqual(days.value(.headphoneAudioDb, day: "2026-11-03"), 82)
    }

    func testPruneKeepsOnlyListedDays() {
        var days = HealthDays()
        days.apply(sample(.steps, 1, day: "2026-11-01"))
        days.apply(sample(.steps, 2, day: "2026-11-03"))
        days.prune(keeping: ["2026-11-03"])
        XCTAssertNil(days.value(.steps, day: "2026-11-01"))
        XCTAssertEqual(days.value(.steps, day: "2026-11-03"), 2)
    }
}

final class HealthCollectorTests: TempFolderTestCase {
    private var clock = iso("2026-11-03T12:00:00Z")

    private func make(_ raw: [String: JSONValue] = ["token": .string("s3cret")], bind: String = "127.0.0.1",
                      folder: URL? = nil) throws -> (HealthCollector, MetricsRegistry) {
        let collector = HealthCollector(settings: settings("health", raw), bind: bind, now: { self.clock },
                                        calendar: utc, stateFolder: folder ?? makeTempFolder())
        let registry = MetricsRegistry()
        try collector.start(registry: registry)
        return (collector, registry)
    }

    private func post(_ collector: HealthCollector, _ json: String, auth: String? = "Bearer s3cret") -> HealthCollector.Outcome {
        collector.handle(body: Data(json.utf8), authorization: auth)
    }

    private let stepsPost = #"{"device":"iphone","samples":[{"type":"steps","start":"2026-11-03T08:00:00Z","end":"2026-11-03T09:00:00Z","value":812}]}"#

    func testAcceptedPostPublishesGaugesAndCounters() throws {
        let (c, r) = try make()
        XCTAssertEqual(post(c, stepsPost), .accepted(accepted: 1, rejected: [:]))
        XCTAssertEqual(value(r, "molly_health_today", ["type": "steps"]), 812)
        XCTAssertEqual(value(r, "molly_health_samples_total", ["type": "steps"]), 1)
        XCTAssertEqual(value(r, "molly_health_device_info", ["device": "iphone"]), 1)
        XCTAssertEqual(value(r, "molly_health_last_post_timestamp_seconds"), clock.timeIntervalSince1970)
        XCTAssertEqual(value(r, "molly_health_last_sample_timestamp_seconds", ["type": "steps"]), iso("2026-11-03T09:00:00Z").timeIntervalSince1970)
        XCTAssertEqual(value(r, "molly_health_samples_rejected_total", ["reason": "bad_type"]), 0)
    }

    func testRepostingTheSameHourDoesNotDoubleCount() throws {
        let (c, r) = try make()
        _ = post(c, stepsPost)
        _ = post(c, stepsPost)
        XCTAssertEqual(value(r, "molly_health_today", ["type": "steps"]), 812)
    }

    func testRejectedSamplesAreCountedByReason() throws {
        let (c, r) = try make()
        let outcome = post(c, #"{"samples":[{"type":"zzz","start":"2026-11-03T08:00:00Z","value":1}]}"#)
        XCTAssertEqual(outcome, .accepted(accepted: 0, rejected: ["bad_type": 1]))
        XCTAssertEqual(value(r, "molly_health_samples_rejected_total", ["reason": "bad_type"]), 1)
    }

    func testSleepLastNightAndBedtimeGauges() throws {
        let (c, r) = try make()
        _ = post(c, """
        {"date":"2026-11-03","totals":{"sleep_minutes":455,"bedtime":"2026-11-03T01:15:00Z","wake_time":"2026-11-03T08:50:00Z"}}
        """)
        XCTAssertEqual(value(r, "molly_health_sleep_minutes_last_night"), 455)
        XCTAssertEqual(value(r, "molly_health_bedtime_seconds"), 90900)
        XCTAssertEqual(value(r, "molly_health_today", ["type": "sleep_minutes"]), 455)
    }

    func testDayRollsOverAtLocalMidnightAndYesterdayIsKept() throws {
        let (c, r) = try make()
        _ = post(c, stepsPost)
        clock = iso("2026-11-04T00:30:00Z")
        try c.collect()
        XCTAssertNil(value(r, "molly_health_today", ["type": "steps"]))
        XCTAssertEqual(value(r, "molly_health_yesterday", ["type": "steps"]), 812)
        clock = iso("2026-11-05T00:30:00Z")
        try c.collect()
        XCTAssertEqual(value(r, "molly_health_yesterday", ["type": "steps"]), nil)
    }

    func testSleepFromYesterdayCountsAsLastNightUntilTodaysArrives() throws {
        let (c, r) = try make()
        _ = post(c, #"{"date":"2026-11-03","totals":{"sleep_minutes":400}}"#)
        clock = iso("2026-11-04T00:30:00Z")
        try c.collect()
        XCTAssertEqual(value(r, "molly_health_sleep_minutes_last_night"), 400)
        _ = post(c, #"{"date":"2026-11-04","totals":{"sleep_minutes":380}}"#)
        XCTAssertEqual(value(r, "molly_health_sleep_minutes_last_night"), 380)
    }

    func testDevicesAreCappedAtFiveThenOther() throws {
        let (c, r) = try make()
        for index in 1...7 {
            _ = post(c, #"{"device":"phone\#(index)","totals":{"steps":1}}"#)
        }
        XCTAssertEqual(value(r, "molly_health_device_info", ["device": "phone5"]), 1)
        XCTAssertNil(value(r, "molly_health_device_info", ["device": "phone6"]))
        XCTAssertEqual(value(r, "molly_health_device_info", ["device": "other"]), 1)
    }

    func testStateSurvivesARestart() throws {
        let folder = makeTempFolder()
        let (first, _) = try make(folder: folder)
        _ = post(first, stepsPost)
        let (_, registry) = try make(folder: folder)
        XCTAssertEqual(value(registry, "molly_health_today", ["type": "steps"]), 812)
        XCTAssertEqual(value(registry, "molly_health_device_info", ["device": "iphone"]), 1)
    }

    // MARK: auth and the local-only guard

    func testEmptyTokenRefusesEverything() throws {
        let (c, _) = try make(["token": .string("")])
        XCTAssertEqual(post(c, stepsPost, auth: "Bearer "), .unauthorized)
        XCTAssertEqual(post(c, stepsPost, auth: nil), .unauthorized)
    }

    func testWrongOrMissingTokenIsUnauthorizedEvenForGarbageBodies() throws {
        let (c, _) = try make()
        XCTAssertEqual(post(c, stepsPost, auth: "Bearer nope"), .unauthorized)
        XCTAssertEqual(post(c, "not json", auth: nil), .unauthorized)
        XCTAssertEqual(post(c, "not json"), .badRequest("body must be a JSON object"))
        XCTAssertEqual(post(c, #"{"device":"x"}"#), .badRequest("samples or totals is required"))
    }

    func testTokenInTheBodyIsAcceptedToo() throws {
        let (c, _) = try make()
        let body = #"{"token":"s3cret","totals":{"steps":10}}"#
        XCTAssertEqual(post(c, body, auth: nil), .accepted(accepted: 1, rejected: [:]))
        XCTAssertEqual(post(c, #"{"token":"wrong","totals":{"steps":10}}"#, auth: nil), .unauthorized)
    }

    func testNonLoopbackBindIsRefusedUnlessAllowed() throws {
        let collector = HealthCollector(settings: settings("health", ["token": .string("s3cret")]), bind: "0.0.0.0",
                                        now: { self.clock }, calendar: utc, stateFolder: makeTempFolder())
        XCTAssertThrowsError(try collector.start(registry: MetricsRegistry())) { error in
            XCTAssertTrue(error is CollectorUnavailable)
        }
        XCTAssertEqual(post(collector, stepsPost), .forbidden)

        let (allowed, _) = try make(["token": .string("s3cret"), "allowRemoteBind": .bool(true)], bind: "192.168.1.20")
        XCTAssertEqual(post(allowed, stepsPost), .accepted(accepted: 1, rejected: [:]))
    }

    func testLoopbackDetection() {
        for host in ["127.0.0.1", "127.0.0.2", "::1", "localhost", "LOCALHOST"] {
            XCTAssertTrue(HealthCollector.isLoopback(host), host)
        }
        for host in ["0.0.0.0", "192.168.1.20", "macbook.local", "::"] {
            XCTAssertFalse(HealthCollector.isLoopback(host), host)
        }
    }

    func testRouteMapsOutcomesToStatusCodes() throws {
        let registry = MetricsRegistry()
        let (c, _) = try make()
        let manager = CollectorManager(registry: registry, collectors: [c])
        let router = Router()
        Routes.register(on: router, manager: manager, config: Config())
        func request(_ auth: String?, _ body: String) -> HTTPResponse {
            var headers: [String: String] = [:]
            if let auth { headers["authorization"] = auth }
            return router.route(HTTPRequest(method: "POST", path: "/health", query: [:], headers: headers, body: Data(body.utf8)))
        }
        XCTAssertEqual(request(nil, stepsPost).status, 401)
        XCTAssertEqual(request("Bearer s3cret", "{}").status, 400)
        let ok = request("Bearer s3cret", stepsPost)
        XCTAssertEqual(ok.status, 200)
        XCTAssertTrue(String(decoding: ok.body, as: UTF8.self).contains("\"accepted\" : 1"))

        let remote = HealthCollector(settings: settings("health", ["token": .string("s3cret")]), bind: "0.0.0.0",
                                     now: { self.clock }, calendar: utc, stateFolder: makeTempFolder())
        let remoteRouter = Router()
        Routes.register(on: remoteRouter, manager: CollectorManager(registry: MetricsRegistry(), collectors: [remote]), config: Config())
        let refused = remoteRouter.route(HTTPRequest(method: "POST", path: "/health", query: [:],
                                                     headers: ["authorization": "Bearer s3cret"], body: Data(stepsPost.utf8)))
        XCTAssertEqual(refused.status, 403)

        let none = Router()
        Routes.register(on: none, manager: CollectorManager(registry: MetricsRegistry(), collectors: []), config: Config())
        XCTAssertEqual(none.route(HTTPRequest(method: "POST", path: "/health", query: [:], headers: [:])).status, 503)
    }

    func testConfigRouteHidesTheToken() {
        let json = (try? JSONValue.parse(Data(#"{"health":{"token":"s3cret","enabled":true}}"#.utf8))) ?? .null
        let redacted = Routes.redactSalts(json)
        XCTAssertEqual(redacted["health"]?["token"], .string("***"))
        XCTAssertEqual(redacted["health"]?["enabled"], .bool(true))
    }
}

final class HealthImportTests: XCTestCase {
    private let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE HealthData [
    <!ELEMENT HealthData (ExportDate,Me,(Record|Correlation|Workout|ActivitySummary)*)>
    <!ATTLIST Record type CDATA #REQUIRED value CDATA #IMPLIED>
    ]>
    <HealthData locale="en_US">
     <ExportDate value="2026-11-03 09:00:00 +0000"/>
     <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-11-02 08:00:00 +0000" endDate="2026-11-02 08:30:00 +0000" value="1200"/>
     <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-11-02 09:00:00 +0000" endDate="2026-11-02 09:30:00 +0000" value="800">
      <MetadataEntry key="HKWasUserEntered" value="1"/>
     </Record>
     <Record type="HKQuantityTypeIdentifierRestingHeartRate" unit="count/min" startDate="2026-11-02 00:00:00 +0000" endDate="2026-11-02 23:59:00 +0000" value="57"/>
     <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" unit="km" startDate="2026-11-02 08:00:00 +0000" endDate="2026-11-02 08:30:00 +0000" value="1.5"/>
     <Record type="HKCategoryTypeIdentifierAppleStandHour" startDate="2026-11-02 10:00:00 +0000" endDate="2026-11-02 11:00:00 +0000" value="HKCategoryValueAppleStandHourStood"/>
     <Record type="HKCategoryTypeIdentifierAppleStandHour" startDate="2026-11-02 11:00:00 +0000" endDate="2026-11-02 12:00:00 +0000" value="HKCategoryValueAppleStandHourIdle"/>
     <Record type="HKCategoryTypeIdentifierSleepAnalysis" startDate="2026-11-01 23:30:00 +0000" endDate="2026-11-02 07:00:00 +0000" value="HKCategoryValueSleepAnalysisInBed"/>
     <Record type="HKCategoryTypeIdentifierSleepAnalysis" startDate="2026-11-02 00:00:00 +0000" endDate="2026-11-02 03:00:00 +0000" value="HKCategoryValueSleepAnalysisAsleepCore"/>
     <Record type="HKCategoryTypeIdentifierSleepAnalysis" startDate="2026-11-02 02:00:00 +0000" endDate="2026-11-02 06:00:00 +0000" value="HKCategoryValueSleepAnalysisAsleepDeep"/>
     <Record type="HKCategoryTypeIdentifierSleepAnalysis" startDate="2026-11-02 06:00:00 +0000" endDate="2026-11-02 06:10:00 +0000" value="HKCategoryValueSleepAnalysisAwake"/>
     <Record type="HKQuantityTypeIdentifierBodyTemperature" startDate="2026-11-02 06:00:00 +0000" endDate="2026-11-02 06:10:00 +0000" value="36.6"/>
    </HealthData>
    """

    private func parsed() throws -> HealthExportParser {
        let parser = HealthExportParser(calendar: utc)
        try parser.parse(XMLParser(data: Data(fixture.utf8)))
        return parser
    }

    func testRecordsAggregateIntoLocalDays() throws {
        let parser = try parsed()
        let day = "2026-11-02"
        XCTAssertEqual(parser.days.value(.steps, day: day), 2000)
        XCTAssertEqual(parser.days.value(.restingHeartRateBpm, day: day), 57)
        XCTAssertEqual(parser.days.value(.walkingDistanceM, day: day), 1500)
        XCTAssertEqual(parser.days.value(.standHours, day: day), 1)
        XCTAssertEqual(parser.recordCount, 11)
    }

    func testSleepMergesOverlapsAndDerivesBedtimeAndWakeTime() throws {
        let days = try parsed().days
        let day = "2026-11-02"
        XCTAssertEqual(days.value(.sleepMinutes, day: day), 360, "00:00-03:00 and 02:00-06:00 merge to 6 hours")
        XCTAssertEqual(days.value(.sleepInBedMinutes, day: day), 450)
        XCTAssertEqual(days.value(.bedtime, day: day), 84600)
        XCTAssertEqual(days.value(.wakeTime, day: day), 7 * 3600)
    }

    func testOpenMetricsOutputFormat() throws {
        let text = HealthOpenMetrics.render(try parsed().days, user: "adam", host: "mbp", calendar: utc)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "# HELP molly_health_day Apple Health value for one local day, imported from an export.")
        XCTAssertEqual(lines[1], "# TYPE molly_health_day gauge")
        XCTAssertEqual(lines.last, "# EOF")
        let noon = Int(iso("2026-11-02T12:00:00Z").timeIntervalSince1970)
        XCTAssertTrue(lines.contains("molly_health_day{type=\"steps\",user=\"adam\",host=\"mbp\"} 2000 \(noon)"), text)
        XCTAssertTrue(lines.contains("molly_health_day{type=\"bedtime\",user=\"adam\",host=\"mbp\"} 84600 \(noon)"), text)
        XCTAssertTrue(text.hasSuffix("# EOF\n"))
    }

    func testSamplesOfOneSeriesAreContiguousAndAscending() {
        var days = HealthDays()
        for (day, value) in [("2026-11-03", 3.0), ("2026-11-01", 1.0), ("2026-11-02", 2.0)] {
            days.apply(HealthSample(type: .steps, day: day, at: Date(), key: "k", value: value, replacesDay: false))
            days.apply(HealthSample(type: .flightsClimbed, day: day, at: Date(), key: "k", value: value, replacesDay: false))
        }
        let lines = HealthOpenMetrics.render(days, user: "u", host: "h", calendar: utc).split(separator: "\n").map(String.init)
        let steps = lines.filter { $0.contains("type=\"steps\"") }.compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        XCTAssertEqual(steps, steps.sorted())
        let firstFlights = lines.firstIndex { $0.contains("flights_climbed") } ?? 0
        let lastSteps = lines.lastIndex { $0.contains("type=\"steps\"") } ?? 0
        XCTAssertLessThan(lastSteps, firstFlights)
    }

    func testMalformedXMLThrows() {
        let parser = HealthExportParser(calendar: utc)
        XCTAssertThrowsError(try parser.parse(XMLParser(data: Data("<HealthData><Record".utf8))))
    }

    func testInstructionsNameThePromtoolCommandAndTheDownTimeNote() {
        let text = HealthCommand.instructions(file: URL(fileURLWithPath: "/tmp/molly-health.om"),
                                              dataDir: URL(fileURLWithPath: "/repo/deploy/data/prometheus"))
        XCTAssertTrue(text.contains(#"promtool tsdb create-blocks-from openmetrics "/tmp/molly-health.om" "/repo/deploy/data/prometheus""#))
        XCTAssertTrue(text.contains("docker run --rm"))
        XCTAssertTrue(text.contains("make stack-down"))
        XCTAssertTrue(text.contains("make stack-up"))
    }
}

final class HealthDigestTests: XCTestCase {
    func testHealthQueriesAreWellFormed() {
        for q in DigestQueries.healthCoarse + DigestQueries.healthDetailed {
            XCTAssertTrue(q.promql.contains("{s}") || q.promql.contains("{s,"), q.key)
            XCTAssertTrue(q.promql.contains("[{r}"), q.key)
        }
        let all = (DigestQueries.all + DigestQueries.healthCoarse + DigestQueries.healthDetailed).map { $0.key }
        XCTAssertEqual(all.count, Set(all).count, "keys must be unique")
    }

    func testDigestIncludesNothingUnlessEnabledAndDetailedIsOptIn() throws {
        func queries(_ json: String) throws -> [DigestQuery] {
            DigestQueries.health(config: try Config.parse(Data(json.utf8)))
        }
        XCTAssertTrue(try queries("{}").isEmpty)
        XCTAssertTrue(try queries(#"{"collectors":{"health":{"enabled":false,"detailedInsights":true}}}"#).isEmpty)
        let coarse = try queries(#"{"collectors":{"health":{"enabled":true}}}"#)
        XCTAssertEqual(coarse.count, 3)
        XCTAssertTrue(coarse.allSatisfy { if case .bucket = $0.shape { return true } else { return false } })
        let detailed = try queries(#"{"collectors":{"health":{"enabled":true,"detailedInsights":true}}}"#)
        XCTAssertGreaterThan(detailed.count, coarse.count)
    }

    func testBucketsRenderAsWordsNotNumbers() {
        var digest = InsightsDigest(kind: .day, date: "2026-11-03", user: "u", host: "h",
                                    from: Date(), to: Date(), generatedAt: Date())
        digest.scalars["health_sleep"] = 0
        digest.scalars["health_movement"] = 2
        digest.scalars["health_rest"] = 1
        let text = digest.markdown()
        XCTAssertTrue(text.contains("Sleep last night: short"), text)
        XCTAssertTrue(text.contains("Movement: high"), text)
        XCTAssertTrue(text.contains("flat"), text)
        XCTAssertFalse(text.contains("health_steps"))
    }
}
