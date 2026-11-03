import XCTest
@testable import Molly

final class HTTPTests: XCTestCase {
    func testParsesRequestWithQuery() {
        let raw = Data("GET /metrics?x=1&y=a%20b HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n".utf8)
        guard case .request(let r) = HTTPRequestParser.parse(raw) else { return XCTFail("not parsed") }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/metrics")
        XCTAssertEqual(r.query, ["x": "1", "y": "a b"])
        XCTAssertEqual(r.headers["host"], "localhost")
    }

    func testIncompleteAndInvalid() {
        if case .incomplete = HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\n".utf8)) {} else { XCTFail() }
        if case .invalid = HTTPRequestParser.parse(Data("NOPE\r\n\r\n".utf8)) {} else { XCTFail() }
    }

    func testRouterMatchesExactPathsAndMethods() {
        let router = Router()
        router.get("/metrics") { _ in .text("m") }
        let ok = router.route(HTTPRequest(method: "GET", path: "/metrics", query: [:], headers: [:]))
        XCTAssertEqual(String(decoding: ok.body, as: UTF8.self), "m")
        XCTAssertEqual(router.route(HTTPRequest(method: "POST", path: "/metrics", query: [:], headers: [:])).status, 405)
        XCTAssertEqual(router.route(HTTPRequest(method: "GET", path: "/nope", query: [:], headers: [:])).status, 404)
    }

    func testSerializedResponse() {
        let text = String(decoding: HTTPResponse.text("hi").serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nhi"))
    }

    func testServerServesMetricsEndToEnd() throws {
        let registry = MetricsRegistry(constLabels: ["user": "t", "host": "h"])
        let manager = CollectorManager(registry: registry, collectors: [])
        let router = Router()
        Routes.register(on: router, manager: manager, config: Config())
        let port = Int.random(in: 20000...40000)
        let server = try HTTPServer(bind: "127.0.0.1", port: port, router: router)
        server.start()
        defer { server.stop() }

        var body = ""
        var status = 0
        for _ in 0..<20 {
            let (s, data) = DoctorCommand.fetch(URL(string: "http://127.0.0.1:\(port)/metrics")!, timeout: 1)
            if s == 200 {
                status = s
                body = String(decoding: data, as: UTF8.self)
                break
            }
            usleep(100_000)
        }
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("molly_up{host=\"h\",user=\"t\"} 1"), body)
        let (collectorsStatus, _) = DoctorCommand.fetch(URL(string: "http://127.0.0.1:\(port)/collectors")!, timeout: 1)
        XCTAssertEqual(collectorsStatus, 200)
    }

    func testSecondListenerOnSamePortReportsFailure() throws {
        let port = Int.random(in: 20000...40000)
        let first = try HTTPServer(bind: "127.0.0.1", port: port, router: Router())
        first.start()
        defer { first.stop() }
        var ready = false
        for _ in 0..<20 where !ready {
            ready = DoctorCommand.fetch(URL(string: "http://127.0.0.1:\(port)/")!, timeout: 1).0 != 0
            if !ready { usleep(100_000) }
        }
        XCTAssertTrue(ready, "first listener never came up")

        let failed = expectation(description: "second listener reports bind failure")
        let second = try HTTPServer(bind: "127.0.0.1", port: port, router: Router())
        second.onFailure = { _ in failed.fulfill() }
        second.start()
        defer { second.stop() }
        wait(for: [failed], timeout: 5)
    }
}
