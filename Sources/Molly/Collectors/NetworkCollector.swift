import Foundation
import SystemConfiguration

// MARK: - Pure helpers (unit-tested)

/// One address of one interface, as getifaddrs reports it.
struct InterfaceAddress: Equatable {
    enum Kind { case ipv4, ipv6, ipv6LinkLocal }
    let name: String
    let flags: UInt32
    let kind: Kind
}

// MARK: - Collector

/// Connection context without any permission: which interface carries the
/// default route and what kind it is, VPN state, per-interface traffic, and
/// optional reachability and captive-portal probes.
final class NetworkCollector: Collector {
    let name = "network"
    let interval: TimeInterval

    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
    static let noInterface = "none"
    static let captiveURL = "http://captive.apple.com/hotspot-detect.html"
    static let captiveSuccessMarker = "Success"
    static let probeTimeout: TimeInterval = 5
    private static let thirtyTwoBit = 4_294_967_296.0
    // A counter that drops from this close to its limit wrapped; anything lower was reset.
    private static let wrapSuspicionLevel = thirtyTwoBit * 0.75

    private static let dynamicStoreName = "molly.network"
    private static let globalIPv4Key = "State:/Network/Global/IPv4"
    private static let serviceIPv4Pattern = "State:/Network/Service/.*/IPv4"

    private let probeURL: URL?
    private let captiveCheck: Bool
    private var previousCounters: [String: UInt32] = [:]
    private var knownInterfaces: Set<String> = []
    private var m: Instruments?

    init(settings: CollectorSettings) {
        interval = settings.interval(default: 30)
        captiveCheck = settings.bool("captiveCheck", default: false)
        let raw = settings.string("probeURL", default: "")
        if raw.isEmpty {
            probeURL = nil
        } else if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            probeURL = url
        } else {
            Log.warn("network: probeURL is not an http(s) URL; probe disabled")
            probeURL = nil
        }
    }

    private struct Instruments {
        let primaryInfo: Gauge
        let connected: Gauge
        let vpnActive: Gauge
        let vpnInterfaces: Gauge
        let rxBytes: Counter
        let txBytes: Counter
        let rxPackets: Counter
        let txPackets: Counter
        let rxErrors: Counter
        let txErrors: Counter
        let interfaceUp: Gauge
        let probeSuccess: Gauge?
        let probeLatency: Gauge?
        let captive: Gauge?
    }

    func start(registry r: MetricsRegistry) throws {
        let iface = ["interface"]
        m = Instruments(
            primaryInfo: r.gauge("molly_network_primary_interface_info", help: "Interface carrying the default route; type is wifi, ethernet, cellular, bridge, other or none.", labels: ["interface", "type"]),
            connected: r.gauge("molly_network_connected", help: "1 when the system has a primary network interface."),
            vpnActive: r.gauge("molly_network_vpn_active", help: "1 when a VPN tunnel interface has a routable address."),
            vpnInterfaces: r.gauge("molly_network_vpn_interfaces", help: "Tunnel interfaces that look like an active VPN."),
            rxBytes: r.counter("molly_network_receive_bytes_total", help: "Bytes received.", labels: iface),
            txBytes: r.counter("molly_network_transmit_bytes_total", help: "Bytes sent.", labels: iface),
            rxPackets: r.counter("molly_network_receive_packets_total", help: "Packets received.", labels: iface),
            txPackets: r.counter("molly_network_transmit_packets_total", help: "Packets sent.", labels: iface),
            rxErrors: r.counter("molly_network_receive_errors_total", help: "Receive errors.", labels: iface),
            txErrors: r.counter("molly_network_transmit_errors_total", help: "Transmit errors.", labels: iface),
            interfaceUp: r.gauge("molly_network_interface_up", help: "1 when the interface is up and running.", labels: iface),
            probeSuccess: probeURL == nil ? nil : r.gauge("molly_network_probe_success", help: "1 when the last probe got an HTTP response below 400."),
            probeLatency: probeURL == nil ? nil : r.gauge("molly_network_probe_latency_seconds", help: "Duration of the last successful probe."),
            captive: captiveCheck ? r.gauge("molly_network_captive_portal", help: "1 when the Apple captive-portal check was intercepted.") : nil
        )
    }

    func collect() throws {
        guard let m else { return }
        let snapshot = readInterfaces()
        let store = SCDynamicStoreCreate(nil, Self.dynamicStoreName as CFString, nil, nil)

        publishPrimary(m, store: store)
        publishVPN(m, addresses: snapshot.addresses, serviceTunnels: serviceTunnelNames(store))
        publishInterfaces(m, snapshot.links)
        if let probeURL { runProbe(m, url: probeURL) }
        if captiveCheck { runCaptiveCheck(m) }
    }

    // MARK: Interface state

    private struct LinkState {
        let name: String
        let flags: UInt32
        let counters: if_data
    }

    private func readInterfaces() -> (links: [LinkState], addresses: [InterfaceAddress]) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            Log.debug("network: getifaddrs failed")
            return ([], [])
        }
        defer { freeifaddrs(head) }
        var links: [LinkState] = []
        var addresses: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let ifa = entry.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                guard let data = ifa.ifa_data else { continue }
                links.append(LinkState(name: name, flags: ifa.ifa_flags, counters: data.assumingMemoryBound(to: if_data.self).pointee))
            case AF_INET:
                addresses.append(InterfaceAddress(name: name, flags: ifa.ifa_flags, kind: .ipv4))
            case AF_INET6:
                let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                }
                addresses.append(InterfaceAddress(name: name, flags: ifa.ifa_flags,
                                                  kind: Self.isLinkLocalIPv6(bytes) ? .ipv6LinkLocal : .ipv6))
            default:
                continue
            }
        }
        return (links, addresses)
    }

    private func publishInterfaces(_ m: Instruments, _ links: [LinkState]) {
        var counters: [String: UInt32] = [:]
        var seen: Set<String> = []
        for link in links where !link.name.hasPrefix("lo") {
            seen.insert(link.name)
            let labels = ["interface": link.name]
            m.interfaceUp.set(Self.isUpAndRunning(flags: link.flags) ? 1 : 0, labels: labels)

            // Virtual interfaces that never carried traffic would only add empty series.
            guard link.counters.ifi_ibytes > 0 || link.counters.ifi_obytes > 0 else { continue }
            let readings: [(String, Counter, UInt32)] = [
                ("rb", m.rxBytes, link.counters.ifi_ibytes), ("tb", m.txBytes, link.counters.ifi_obytes),
                ("rp", m.rxPackets, link.counters.ifi_ipackets), ("tp", m.txPackets, link.counters.ifi_opackets),
                ("re", m.rxErrors, link.counters.ifi_ierrors), ("te", m.txErrors, link.counters.ifi_oerrors),
            ]
            for (kind, counter, value) in readings {
                let key = "\(link.name)/\(kind)"
                counters[key] = value
                if let before = previousCounters[key] {
                    counter.add(Self.counterDelta(previous: before, current: value), labels: labels)
                } else {
                    counter.touch(labels: labels)
                }
            }
        }
        previousCounters = counters
        for gone in knownInterfaces.subtracting(seen) { m.interfaceUp.remove(labels: ["interface": gone]) }
        knownInterfaces = seen
    }

    // MARK: Primary interface and VPN

    private func publishPrimary(_ m: Instruments, store: SCDynamicStore?) {
        m.primaryInfo.reset()
        guard let primary = primaryInterfaceName(store) else {
            m.connected.set(0)
            m.primaryInfo.set(1, labels: ["interface": Self.noInterface, "type": Self.noInterface])
            return
        }
        let type = Self.classify(systemType: Self.systemInterfaceTypes()[primary], bsdName: primary)
        m.connected.set(1)
        m.primaryInfo.set(1, labels: ["interface": primary, "type": type])
    }

    private func primaryInterfaceName(_ store: SCDynamicStore?) -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, Self.globalIPv4Key as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String, !primary.isEmpty else { return nil }
        return primary
    }

    /// Tunnel interfaces that network services are routed through, which catches
    /// VPNs that have not yet been given an address by getifaddrs.
    private func serviceTunnelNames(_ store: SCDynamicStore?) -> Set<String> {
        guard let store,
              let keys = SCDynamicStoreCopyKeyList(store, Self.serviceIPv4Pattern as CFString) as? [String] else { return [] }
        var names: Set<String> = []
        for key in keys {
            guard let service = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let name = service["InterfaceName"] as? String else { continue }
            names.insert(name)
        }
        return names
    }

    private func publishVPN(_ m: Instruments, addresses: [InterfaceAddress], serviceTunnels: Set<String>) {
        let tunnels = Self.vpnInterfaces(addresses: addresses, serviceInterfaces: serviceTunnels)
        m.vpnInterfaces.set(Double(tunnels.count))
        m.vpnActive.set(tunnels.isEmpty ? 0 : 1)
    }

    private static func systemInterfaceTypes() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var types: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            types[bsd] = type
        }
        return types
    }

    // MARK: Probes

    private func runProbe(_ m: Instruments, url: URL) {
        let result = Self.fetch(url: url, method: "HEAD")
        let reached = result.status.map { (100..<400).contains($0) } ?? false
        m.probeSuccess?.set(reached ? 1 : 0)
        if reached {
            m.probeLatency?.set(result.latency)
        } else {
            m.probeLatency?.reset()
        }
    }

    private func runCaptiveCheck(_ m: Instruments) {
        guard let url = URL(string: Self.captiveURL) else { return }
        let result = Self.fetch(url: url, method: "GET")
        guard result.status != nil else {
            m.captive?.reset() // offline is not evidence either way
            return
        }
        m.captive?.set(Self.isCaptivePortal(body: result.body) ? 1 : 0)
    }

    private struct FetchResult {
        let status: Int?
        let body: String
        let latency: TimeInterval
    }

    /// Blocks the collector's own queue for at most `probeTimeout`.
    private static func fetch(url: URL, method: String) -> FetchResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.timeoutIntervalForResource = probeTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var body = ""
        let started = Date()
        session.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            done.signal()
        }.resume()
        done.wait()
        return FetchResult(status: status, body: body, latency: Date().timeIntervalSince(started))
    }
}

// MARK: - Pure helpers

extension NetworkCollector {
    /// Maps SCNetworkInterface types (and a few BSD name prefixes) to the `type` label.
    static func classify(systemType: String?, bsdName: String) -> String {
        if bsdName.hasPrefix("bridge") { return "bridge" }
        switch systemType {
        case "IEEE80211": return "wifi"
        case "Ethernet": return "ethernet"
        case "Bridge": return "bridge"
        case "WWAN": return "cellular"
        default: return "other"
        }
    }

    static func isTunnelName(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// macOS keeps link-local-only utun interfaces up permanently, so a tunnel
    /// counts only with a routable address. A tunnel that a network service
    /// routes through counts too.
    static func vpnInterfaces(addresses: [InterfaceAddress], serviceInterfaces: Set<String>) -> [String] {
        var tunnels = Set(serviceInterfaces.filter(isTunnelName))
        for address in addresses where isTunnelName(address.name) {
            let isUp = address.flags & UInt32(IFF_UP) != 0
            if isUp && address.kind != .ipv6LinkLocal { tunnels.insert(address.name) }
        }
        return tunnels.sorted()
    }

    static func isUpAndRunning(flags: UInt32) -> Bool {
        let wanted = UInt32(IFF_UP | IFF_RUNNING)
        return flags & wanted == wanted
    }

    static func isLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }

    /// Increment of a 32-bit interface counter. A drop from near the limit is a
    /// wrap; any other drop means the interface was recreated and counts from zero.
    static func counterDelta(previous: UInt32, current: UInt32) -> Double {
        if current >= previous { return Double(current - previous) }
        if Double(previous) >= wrapSuspicionLevel { return Double(current) + thirtyTwoBit - Double(previous) }
        return Double(current)
    }

    /// Apple's check page answers with a Success body; a portal replaces it.
    static func isCaptivePortal(body: String) -> Bool {
        !body.contains(captiveSuccessMarker)
    }
}
