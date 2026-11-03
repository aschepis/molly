import Foundation

/// `molly shell-hook`: a prompt hook that tells Molly which directory the
/// shell is in, so the `projects` collector gets a shell signal. The hook
/// posts in the background and never prints, so a stopped Molly costs nothing.
enum ShellHookCommand {
    enum ShellKind: String, CaseIterable {
        case zsh, bash, fish

        var rcPath: String {
            switch self {
            case .zsh: return ".zshrc"
            case .bash: return ".bashrc"
            case .fish: return ".config/fish/config.fish"
            }
        }
    }

    struct Endpoint {
        let url: String
        let token: String

        init(config: Config) {
            url = "http://\(config.server.bind):\(config.server.port)/event"
            token = config.collector("events").string("token", default: "")
        }

        init(url: String, token: String = "") {
            self.url = url
            self.token = token
        }
    }

    static let beginMarker = "# >>> molly shell hook >>>"
    static let endMarker = "# <<< molly shell hook <<<"
    static let optOutVariable = "MOLLY_SHELL_HOOK"

    static func run(_ arguments: [String]) {
        var shell = ShellKind.zsh
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == "--shell", let name = iterator.next() {
                guard let kind = ShellKind(rawValue: name) else {
                    FileHandle.standardError.write(Data("unknown shell \(name); use zsh, bash or fish\n".utf8))
                    exit(2)
                }
                shell = kind
            }
        }
        let config = (try? Config.load()) ?? Config()
        let endpoint = Endpoint(config: config)
        switch arguments.first {
        case "snippet":
            print(snippet(for: shell, endpoint: endpoint))
        case "install":
            install(shell: shell, endpoint: endpoint, home: Paths.home)
        case "uninstall":
            uninstall(shell: shell, home: Paths.home)
        default:
            FileHandle.standardError.write(Data("usage: molly shell-hook snippet|install|uninstall [--shell zsh|bash|fish]\n".utf8))
            exit(2)
        }
    }

    // MARK: snippets

    /// The curl invocation shared by every shell; the body is interpolated by
    /// the shell at prompt time.
    static func curl(endpoint: Endpoint, body: String) -> String {
        var parts = ["curl -s -m 0.3 -o /dev/null -X POST -H 'Content-Type: application/json'"]
        if !endpoint.token.isEmpty {
            parts.append("-H 'Authorization: Bearer \(endpoint.token)'")
        }
        parts.append("--data \"\(body)\"")
        parts.append("'\(endpoint.url)'")
        return parts.joined(separator: " ")
    }

    static func body(shell: ShellKind) -> String {
        #"{\"source\":\"shell\",\"event\":\"prompt\",\"shell\":\"\#(shell.rawValue)\",\"exit\":$exit,\"cwd\":\"$PWD\"}"#
    }

    static func snippet(for shell: ShellKind, endpoint: Endpoint) -> String {
        let post = curl(endpoint: endpoint, body: body(shell: shell))
        let comment = "# Tells Molly which directory you are working in; counts only, see `molly shell-hook`."
        switch shell {
        case .zsh:
            return """
            \(beginMarker)
            \(comment)
            __molly_prompt() {
              local exit=$?
              [[ "${\(optOutVariable):-1}" == "0" ]] && return
              [[ "$PWD" == *'"'* ]] && return
              { \(post) } &>/dev/null &!
            }
            autoload -Uz add-zsh-hook
            add-zsh-hook precmd __molly_prompt
            \(endMarker)
            """
        case .bash:
            return """
            \(beginMarker)
            \(comment)
            __molly_prompt() {
              local exit=$?
              [[ "${\(optOutVariable):-1}" == "0" ]] && return
              [[ "$PWD" == *'"'* ]] && return
              { \(post) } >/dev/null 2>&1 &
              disown $! 2>/dev/null
            }
            case ";$PROMPT_COMMAND;" in
              *";__molly_prompt;"*) ;;
              *) PROMPT_COMMAND="__molly_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
            esac
            \(endMarker)
            """
        case .fish:
            return """
            \(beginMarker)
            \(comment)
            function __molly_prompt --on-event fish_prompt
              set -l exit $status
              if test "$\(optOutVariable)" = "0"
                return
              end
              if string match -q '*"*' -- $PWD
                return
              end
              \(post) >/dev/null 2>&1 &
              disown 2>/dev/null
            end
            \(endMarker)
            """
        }
    }

    // MARK: rc file editing

    /// Appends the block, replacing an existing one so re-running updates it.
    static func adding(block: String, to contents: String) -> String {
        let stripped = removing(from: contents)
        let separator: String
        if stripped.isEmpty || stripped.hasSuffix("\n\n") {
            separator = ""
        } else if stripped.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        return stripped + separator + block + "\n"
    }

    /// Removes exactly the delimited block, leaving everything else intact.
    static func removing(from contents: String) -> String {
        guard let begin = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: begin.upperBound..<contents.endIndex) else {
            return contents
        }
        var tail = contents[end.upperBound...]
        if tail.hasPrefix("\n") { tail = tail.dropFirst() }
        var head = contents[..<begin.lowerBound]
        if head.hasSuffix("\n\n") { head = head.dropLast() }
        return String(head) + String(tail)
    }

    static func rcURL(shell: ShellKind, home: URL) -> URL {
        home.appendingPathComponent(shell.rcPath)
    }

    static func install(shell: ShellKind, endpoint: Endpoint, home: URL) {
        let url = rcURL(shell: shell, home: home)
        rewrite(url) { adding(block: snippet(for: shell, endpoint: endpoint), to: $0) }
        print("shell hook installed in \(url.path); open a new shell to activate it")
    }

    static func uninstall(shell: ShellKind, home: URL) {
        let url = rcURL(shell: shell, home: home)
        rewrite(url) { removing(from: $0) }
        print("molly shell hook removed from \(url.path)")
    }

    private static func rewrite(_ url: URL, _ transform: (String) -> String) {
        let fm = FileManager.default
        var current = ""
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(Data("refusing to touch \(url.path): not readable as UTF-8\n".utf8))
                exit(1)
            }
            current = text
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(at: url, to: url.appendingPathExtension("molly-backup-\(stamp)"))
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(transform(current).utf8).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
