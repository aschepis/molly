import Foundation

/// `molly mcp`: a Model Context Protocol server over stdio. Newline-delimited
/// JSON-RPC 2.0, one request per stdin line, at most one response per stdout
/// line. stdout carries protocol messages only; logging goes to stderr.
/// Never starts NSApplication.
enum MCPCommand {
    static func run(_ arguments: [String]) {
        guard arguments.isEmpty else {
            FileHandle.standardError.write(Data("usage: molly mcp\n".utf8))
            exit(1)
        }
        do {
            let config = try Config.load()
            Log.minimumLevel = Log.Level(rawValue: config.logLevel) ?? .info
            let source = try LiveMetricsSource(config: config)
            MCPServer(tools: MCPTools.all(source: source)).serveStdio()
        } catch {
            FileHandle.standardError.write(Data("mcp: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// JSON-RPC dispatch for the MCP handshake and tool calls. The transport is
/// separate from `handle(line:)` so tests drive round-trips as strings.
final class MCPServer {
    static let serverName = "molly"
    static let latestProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    private let tools: [MCPTool]

    init(tools: [MCPTool]) {
        self.tools = tools
    }

    func serveStdio() {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    /// One raw line in, one serialized response out, or nil for blank lines
    /// and notifications, which must produce no output.
    func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return serialize(errorResponse(id: NSNull(), code: -32700, message: "parse error"))
        }
        guard let request = parsed as? [String: Any] else {
            return serialize(errorResponse(id: NSNull(), code: -32600, message: "invalid request"))
        }
        let rawID = request["id"]
        let id: Any? = rawID is NSNull ? nil : rawID
        guard let method = request["method"] as? String else {
            guard let id else { return nil }
            return serialize(errorResponse(id: id, code: -32600, message: "invalid request: missing method"))
        }
        if method.hasPrefix("notifications/") { return nil }
        guard let id else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        return serialize(dispatch(method: method, params: params, id: id))
    }

    private func dispatch(method: String, params: [String: Any], id: Any) -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.latestProtocolVersion
            return resultResponse(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": Version.current],
            ])
        case "ping":
            return resultResponse(id: id, result: [String: Any]())
        case "tools/list":
            return resultResponse(id: id, result: ["tools": tools.map(\.listJSON)])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "params.name is required")
            }
            guard let tool = tools.first(where: { $0.name == name }) else {
                return errorResponse(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return resultResponse(id: id, result: tool.invoke(arguments).json)
        default:
            return errorResponse(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func resultResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func serialize(_ response: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            Log.error("mcp: response serialization failed")
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#
        }
        return text
    }
}
