import XCTest
@testable import Molly

final class DockerParseTests: XCTestCase {
    private let psFixture = """
    {"Image":"postgres:17","Names":"db","State":"running","Status":"Up 2 hours"}
    {"Image":"redis","Names":"cache","State":"exited","Status":"Exited (0) 3 days ago"}
    {"Image":"nginx","Names":"web","Status":"Up 5 minutes (Paused)"}
    not json
    {"Image":"x"}
    """

    func testContainersParseAndSkipBadLines() {
        let containers = DockerParse.containers(psFixture)
        XCTAssertEqual(containers, [
            DockerContainer(name: "db", image: "postgres:17", state: "running"),
            DockerContainer(name: "cache", image: "redis", state: "exited"),
            DockerContainer(name: "web", image: "nginx", state: "paused"),
        ])
    }

    func testCountByStateAlwaysHasCoreStates() {
        let counts = DockerParse.countByState(DockerParse.containers(psFixture))
        XCTAssertEqual(counts["running"], 1)
        XCTAssertEqual(counts["exited"], 1)
        XCTAssertEqual(counts["paused"], 1)
        XCTAssertEqual(counts["created"], 0)
    }

    func testDistinctLineCount() {
        XCTAssertEqual(DockerParse.distinctLineCount("sha256:a\nsha256:b\nsha256:a\n\n"), 2)
        XCTAssertEqual(DockerParse.distinctLineCount(""), 0)
    }

    func testPercentAndByteParsing() throws {
        XCTAssertEqual(try XCTUnwrap(DockerParse.percentRatio("12.34%")), 0.1234, accuracy: 1e-9)
        XCTAssertNil(DockerParse.percentRatio("--"))
        XCTAssertEqual(DockerParse.byteCount("1.5GiB"), 1.5 * 1024 * 1024 * 1024)
        XCTAssertEqual(DockerParse.byteCount("512MiB"), 512 * 1024 * 1024)
        XCTAssertEqual(DockerParse.byteCount("2kB"), 2000)
        XCTAssertEqual(DockerParse.byteCount("0B"), 0)
        XCTAssertNil(DockerParse.byteCount("lots"))
        XCTAssertEqual(DockerParse.memoryUsage("1.2GiB / 16GiB"), 1.2 * 1024 * 1024 * 1024)
    }

    func testStatsParsing() {
        let fixture = """
        {"Name":"db","CPUPerc":"3.50%","MemUsage":"200MiB / 7.6GiB"}
        {"Name":"idle","CPUPerc":"--","MemUsage":"0B / 0B"}
        """
        XCTAssertEqual(DockerParse.stats(fixture), [DockerStat(name: "db", cpuRatio: 0.035, memoryBytes: 200 * 1024 * 1024)])
    }

    func testMissingDockerPublishesAvailableZeroAndThrowsUnavailable() throws {
        let registry = MetricsRegistry()
        let collector = try DockerCollector(settings: CollectorSettings(name: "docker", raw: ["path": .string("/nonexistent/docker")]))
        try collector.start(registry: registry)
        XCTAssertThrowsError(try collector.collect()) { XCTAssertTrue($0 is CollectorUnavailable) }
        XCTAssertEqual(registry.gauge("molly_docker_available", help: "").value(), 0)
    }
}
