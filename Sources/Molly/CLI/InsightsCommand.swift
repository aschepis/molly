import Foundation

struct InsightsOptions: Equatable {
    var day: String?
    var week = false
    var force = false
    var digestOnly = false
    var backend: NarrativeBackend.Choice?

    enum ParseError: Error, CustomStringConvertible {
        case badDate(String)
        case badBackend(String)
        case unknown(String)

        var description: String {
            switch self {
            case .badDate(let d): return "bad --day \(d); want YYYY-MM-DD"
            case .badBackend(let b): return "bad --backend \(b); want api or cli"
            case .unknown(let a): return "unknown argument \(a)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> InsightsOptions {
        var options = InsightsOptions()
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--day":
                guard let value = iterator.next(), DigestBuilder.parseDate(value) != nil else {
                    throw ParseError.badDate(iterator.next() ?? "")
                }
                options.day = value
            case "--week": options.week = true
            case "--force": options.force = true
            case "--digest-only": options.digestOnly = true
            case "--backend":
                guard let value = iterator.next(), let choice = NarrativeBackend.Choice(rawValue: value), choice != .auto else {
                    throw ParseError.badBackend(arguments.joined(separator: " "))
                }
                options.backend = choice
            default: throw ParseError.unknown(arg)
            }
        }
        return options
    }
}

enum InsightsCommand {
    static func run(_ arguments: [String]) {
        do {
            let options = try InsightsOptions.parse(arguments)
            let config = try Config.load()
            Log.minimumLevel = Log.Level(rawValue: config.logLevel) ?? .info
            var settings = InsightsSettings(settings: config.collector("insights"), links: config.links)
            if let backend = options.backend { settings.backend = backend }
            let client = try PrometheusClient(baseURL: settings.prometheusURL)
            guard client.isReady() else {
                throw CollectorUnavailable(reason: "Prometheus at \(settings.prometheusURL) is not ready (run `make stack-up`)")
            }
            let generator = InsightsGenerator(
                client: client, store: InsightsStore(),
                user: config.constLabels["user"] ?? Config.defaultUser,
                host: config.constLabels["host"] ?? Config.defaultHost,
                makeCompleter: { try NarrativeBackend.make(choice: settings.backend, apiKey: settings.apiKey, model: settings.model) })
            let kind: InsightsDigest.Kind = options.week ? .week : .day
            let date = options.day.flatMap { DigestBuilder.parseDate($0) } ?? Date()
            if options.digestOnly {
                print(generator.digest(kind: kind, date: date).markdown(), terminator: "")
                return
            }
            let result = try generator.generate(kind: kind, date: date, force: options.force)
            print(result.markdown, terminator: "")
            let path = generator.store.url(kind: kind, date: result.date).path
            FileHandle.standardError.write(Data("\(result.cached ? "cached" : "written"): \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
