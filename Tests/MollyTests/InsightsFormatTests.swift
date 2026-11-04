import XCTest
@testable import Molly

final class InsightsFormatTests: XCTestCase {
    func testAcceptSelectionTable() {
        let cases: [(String?, InsightsFormat.Choice)] = [
            (nil, .format(.html)),
            ("", .format(.html)),
            ("*/*", .format(.html)),
            ("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", .format(.html)),
            ("text/markdown", .format(.markdown)),
            ("application/json", .format(.json)),
            ("application/yaml", .format(.yaml)),
            ("text/yaml", .format(.yaml)),
            ("application/x-yaml", .format(.yaml)),
            ("application/json;q=0.5, text/markdown;q=0.9", .format(.markdown)),
            ("application/json, text/html", .format(.html)),
            ("application/yaml, application/json", .format(.json)),
            ("application/json, */*;q=0.1", .format(.json)),
            ("text/html;q=0, application/json", .format(.json)),
            ("garbage", .format(.html)),
            ("application/xml", .notAcceptable),
            ("image/png, text/csv", .notAcceptable),
            ("text/html;q=0", .notAcceptable),
        ]
        for (accept, expected) in cases {
            XCTAssertEqual(InsightsFormat.choose(accept: accept), expected, "Accept: \(accept ?? "nil")")
        }
    }

    func testPathSuffixParsing() {
        XCTAssertNil(InsightsPath(path: "/insights/latest")?.suffix)
        XCTAssertEqual(InsightsPath(path: "/insights/latest.json")?.suffix, .json)
        XCTAssertEqual(InsightsPath(path: "/insights/latest.yml")?.suffix, .yaml)
        XCTAssertEqual(InsightsPath(path: "/insights/2026-11-03.md")?.name, "2026-11-03")
        XCTAssertEqual(InsightsPath(path: "/insights/2026-11-02-week.html")?.name, "2026-11-02-week")
        XCTAssertEqual(InsightsPath(path: "/insights/2026-11-02-week.html")?.suffix, .html)
        XCTAssertNil(InsightsPath(path: "/insights/"))
    }

    func testRendererConstructs() {
        XCTAssertEqual(MarkdownHTML.render("# One\n## Two\n### Three"), "<h1>One</h1>\n<h2>Two</h2>\n<h3>Three</h3>\n")
        XCTAssertEqual(MarkdownHTML.render("line one\nline two\n\nnext"), "<p>line one\nline two</p>\n<p>next</p>\n")
        XCTAssertEqual(MarkdownHTML.render("- a\n- b"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        XCTAssertEqual(MarkdownHTML.render("1. a\n2. b"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
        XCTAssertEqual(MarkdownHTML.render("**bold** and *it*"), "<p><strong>bold</strong> and <em>it</em></p>\n")
        XCTAssertEqual(MarkdownHTML.render("use `a*b*c` here"), "<p>use <code>a*b*c</code> here</p>\n")
        XCTAssertEqual(MarkdownHTML.render("```\nx < y\n# not a heading\n```"),
                       "<pre><code>x &lt; y\n# not a heading</code></pre>\n")
        XCTAssertEqual(MarkdownHTML.render("[Grafana](http://localhost:3030/d/x)"),
                       "<p><a href=\"http://localhost:3030/d/x\">Grafana</a></p>\n")
        XCTAssertEqual(MarkdownHTML.render("above\n\n---\n\nbelow"), "<p>above</p>\n<hr>\n<p>below</p>\n")
    }

    func testRendererTable() {
        let html = MarkdownHTML.render("| App | Hours |\n|---|---:|\n| Xcode | 3 |\n| Safari | **1** |\n\nafter")
        XCTAssertTrue(html.contains("<thead><tr><th>App</th><th>Hours</th></tr></thead>"), html)
        XCTAssertTrue(html.contains("<tr><td>Xcode</td><td>3</td></tr>"), html)
        XCTAssertTrue(html.contains("<tr><td>Safari</td><td><strong>1</strong></td></tr>"), html)
        XCTAssertTrue(html.hasSuffix("<p>after</p>\n"), html)
    }

    func testRendererEscapesEverything() {
        XCTAssertEqual(MarkdownHTML.render("<script>alert(1)</script> & \"q\""),
                       "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;</p>\n")
        XCTAssertEqual(MarkdownHTML.render("# <b>x</b>"), "<h1>&lt;b&gt;x&lt;/b&gt;</h1>\n")
        XCTAssertEqual(MarkdownHTML.render("- <i>x</i>"), "<ul>\n<li>&lt;i&gt;x&lt;/i&gt;</li>\n</ul>\n")
        XCTAssertEqual(MarkdownHTML.render("`<b>`"), "<p><code>&lt;b&gt;</code></p>\n")
        XCTAssertEqual(MarkdownHTML.render("| <h> |\n|---|\n| <td> |"),
                       "<table>\n<thead><tr><th>&lt;h&gt;</th></tr></thead>\n<tbody>\n<tr><td>&lt;td&gt;</td></tr>\n</tbody>\n</table>\n")
        XCTAssertFalse(MarkdownHTML.render("[x](javascript:alert(1))").contains("<a "))
    }

    func testDetailsWrapperPassesThroughOnlyExactTags() {
        let html = MarkdownHTML.render("<details>\n<summary>Digest <b></summary>\n\ntext\n</details>")
        XCTAssertTrue(html.contains("<details>"))
        XCTAssertTrue(html.contains("<summary>Digest &lt;b&gt;</summary>"), html)
        XCTAssertTrue(html.contains("</details>"))
    }

    func testYAMLCases() {
        func emit(_ value: JSONValue) -> String { YAML.emit(value) }
        XCTAssertEqual(emit(.object(["b": .number(2), "a": .string("plain")])), "a: plain\nb: 2\n")
        XCTAssertEqual(emit(.object(["nothing": .null, "t": .bool(true), "f": .number(1.5)])), "f: 1.5\nnothing: null\nt: true\n")
        XCTAssertEqual(emit(.object(["k": .string("a: b")])), "k: \"a: b\"\n")
        XCTAssertEqual(emit(.object(["k": .string("x # y")])), "k: \"x # y\"\n")
        XCTAssertEqual(emit(.object(["k": .string("- item")])), "k: \"- item\"\n")
        XCTAssertEqual(emit(.object(["k": .string("say \"hi\"")])), "k: \"say \\\"hi\\\"\"\n")
        XCTAssertEqual(emit(.object(["k": .string("12")])), "k: \"12\"\n")
        XCTAssertEqual(emit(.object(["k": .string("true")])), "k: \"true\"\n")
        XCTAssertEqual(emit(.object(["k": .string("null")])), "k: \"null\"\n")
        XCTAssertEqual(emit(.object(["k": .string("")])), "k: \"\"\n")
        XCTAssertEqual(emit(.object(["k": .string("2026-11-03")])), "k: 2026-11-03\n")
        XCTAssertEqual(emit(.object(["k": .string("one\ntwo\n")])), "k: |\n  one\n  two\n")
        XCTAssertEqual(emit(.object(["k": .string("one\ntwo")])), "k: |-\n  one\n  two\n")
        XCTAssertEqual(emit(.object(["k": .string("a\n\nb\n")])), "k: |\n  a\n\n  b\n")
        XCTAssertEqual(emit(.object(["k": .object([:]), "l": .array([])])), "k: {}\nl: []\n")
        XCTAssertEqual(emit(.object(["o": .object(["x": .number(1)]), "l": .array([.string("a"), .number(2)])])),
                       "l:\n  - a\n  - 2\no:\n  x: 1\n")
        XCTAssertEqual(emit(.array([.object(["a": .number(1), "b": .number(2)]), .string("z")])), "- a: 1\n  b: 2\n- z\n")
        XCTAssertEqual(emit(.string("top")), "top\n")
    }

    // MARK: Route

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("molly-insights-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fetch(_ port: Int, _ path: String, accept: String? = nil) -> (status: Int, type: String, vary: String, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 2
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let done = expectation(description: path)
        var result = (status: 0, type: "", vary: "", body: "")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            result = (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                      http?.value(forHTTPHeaderField: "Vary") ?? "", String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return result
    }

    func testRouteServesEveryFormat() throws {
        let store = InsightsStore(folder: tempFolder())
        try store.write("# Molly insights for 2026-11-02\n\nOlder & quieter.\n", kind: .day, date: "2026-11-02")
        try store.write("# Molly insights for 2026-11-03\n\nA <busy> day.\n\n| App | Hours |\n|---|---|\n| Xcode | 3 |\n",
                        kind: .day, date: "2026-11-03")
        let digest = InsightsDigest(kind: .day, date: "2026-11-03", user: "u", host: "h", from: Date(timeIntervalSince1970: 0),
                                    to: Date(timeIntervalSince1970: 3600), generatedAt: Date(timeIntervalSince1970: 7200),
                                    scalars: ["active_hours": 6.5])
        try store.writeDigest(digest, kind: .day, date: "2026-11-03")

        let router = Router()
        Routes.register(on: router, manager: CollectorManager(registry: MetricsRegistry(constLabels: [:]), collectors: []),
                        config: Config(), insights: store)
        let port = Int.random(in: 20000...40000)
        let server = try HTTPServer(bind: "127.0.0.1", port: port, router: router)
        server.start()
        defer { server.stop() }
        for _ in 0..<20 where DoctorCommand.fetch(URL(string: "http://127.0.0.1:\(port)/healthz")!, timeout: 1).0 != 200 {
            usleep(100_000)
        }

        let html = fetch(port, "/insights/latest", accept: "text/html")
        XCTAssertEqual(html.status, 200)
        XCTAssertEqual(html.type, "text/html; charset=utf-8")
        XCTAssertEqual(html.vary, "Accept")
        XCTAssertTrue(html.body.contains("<title>Molly insights 2026-11-03</title>"), html.body)
        XCTAssertTrue(html.body.contains("A &lt;busy&gt; day."), html.body)
        XCTAssertTrue(html.body.contains("<td>Xcode</td>"))
        XCTAssertTrue(html.body.contains("href=\"/insights/2026-11-02\""), "previous link")
        XCTAssertTrue(html.body.contains("href=\"/insights/2026-11-03.json\""), "format link")

        XCTAssertEqual(fetch(port, "/insights/latest").type, "text/html; charset=utf-8")

        let markdown = fetch(port, "/insights/latest.md", accept: "application/json")
        XCTAssertEqual(markdown.type, "text/markdown; charset=utf-8")
        XCTAssertTrue(markdown.body.hasPrefix("# Molly insights for 2026-11-03"))

        let json = fetch(port, "/insights/2026-11-03", accept: "application/json")
        XCTAssertEqual(json.type, "application/json")
        let tree = try JSONValue.parse(Data(json.body.utf8))
        XCTAssertEqual(tree["kind"], .string("day"))
        XCTAssertEqual(tree["digest"]?["scalars"]?["active_hours"], .number(6.5))
        XCTAssertNotNil(tree["digest"]?["generated_at"]?.stringValue)

        let yaml = fetch(port, "/insights/2026-11-03.yml")
        XCTAssertEqual(yaml.type, "application/yaml")
        XCTAssertTrue(yaml.body.contains("kind: day\n"), yaml.body)
        XCTAssertTrue(yaml.body.contains("markdown: |\n  # Molly insights for 2026-11-03"), yaml.body)

        let old = try JSONValue.parse(Data(fetch(port, "/insights/2026-11-02.json").body.utf8))
        XCTAssertEqual(old["digest"], .null, "reports from before digests were saved")

        XCTAssertEqual(fetch(port, "/insights/latest", accept: "application/xml").status, 406)
        XCTAssertEqual(fetch(port, "/insights/2026-01-01.json").status, 404)
        XCTAssertEqual(fetch(port, "/insights/nonsense").status, 404)
    }

    func testDigestIsSavedSnakeCaseBesideReport() throws {
        let store = InsightsStore(folder: tempFolder())
        let digest = InsightsDigest(kind: .week, date: "2026-11-02", user: "u", host: "h", from: Date(), to: Date(),
                                    generatedAt: Date(), scalars: ["x": 1])
        try store.writeDigest(digest, kind: .week, date: "2026-11-02")
        XCTAssertEqual(store.digestURL(kind: .week, date: "2026-11-02").lastPathComponent, "2026-11-02-week.json")
        XCTAssertEqual(store.readDigest(kind: .week, date: "2026-11-02")?["scalars"]?["x"], .number(1))
        XCTAssertNotNil(store.readDigest(kind: .week, date: "2026-11-02")?["generated_at"])
    }
}
