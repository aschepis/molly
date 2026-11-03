import XCTest
@testable import Molly

final class NetworkCollectorTests: XCTestCase {
    private let up = UInt32(IFF_UP | IFF_RUNNING)

    func testClassifyInterfaceTypes() {
        XCTAssertEqual(NetworkCollector.classify(systemType: "IEEE80211", bsdName: "en0"), "wifi")
        XCTAssertEqual(NetworkCollector.classify(systemType: "Ethernet", bsdName: "en5"), "ethernet")
        XCTAssertEqual(NetworkCollector.classify(systemType: "Bridge", bsdName: "bridge0"), "bridge")
        XCTAssertEqual(NetworkCollector.classify(systemType: nil, bsdName: "bridge0"), "bridge")
        XCTAssertEqual(NetworkCollector.classify(systemType: "WWAN", bsdName: "pdp_ip0"), "cellular")
        XCTAssertEqual(NetworkCollector.classify(systemType: nil, bsdName: "utun3"), "other")
    }

    func testVPNIgnoresLinkLocalAndDownTunnels() {
        let addresses = [
            InterfaceAddress(name: "utun0", flags: up, kind: .ipv6LinkLocal),
            InterfaceAddress(name: "en0", flags: up, kind: .ipv4),
            InterfaceAddress(name: "utun2", flags: 0, kind: .ipv4),
        ]
        XCTAssertEqual(NetworkCollector.vpnInterfaces(addresses: addresses, serviceInterfaces: []), [])
    }

    func testVPNCountsRoutableTunnelsAndServiceInterfaces() {
        let addresses = [
            InterfaceAddress(name: "utun4", flags: up, kind: .ipv4),
            InterfaceAddress(name: "utun4", flags: up, kind: .ipv6),
            InterfaceAddress(name: "ipsec0", flags: up, kind: .ipv6),
        ]
        let found = NetworkCollector.vpnInterfaces(addresses: addresses, serviceInterfaces: ["ppp0", "en0"])
        XCTAssertEqual(found, ["ipsec0", "ppp0", "utun4"])
    }

    func testCounterDeltaHandlesGrowthWrapAndReset() {
        XCTAssertEqual(NetworkCollector.counterDelta(previous: 100, current: 150), 50)
        XCTAssertEqual(NetworkCollector.counterDelta(previous: UInt32.max - 5, current: 4), 10)
        XCTAssertEqual(NetworkCollector.counterDelta(previous: 5_000, current: 40), 40)
    }

    func testInterfaceFlagsAndLinkLocal() {
        XCTAssertTrue(NetworkCollector.isUpAndRunning(flags: up))
        XCTAssertFalse(NetworkCollector.isUpAndRunning(flags: UInt32(IFF_UP)))
        XCTAssertTrue(NetworkCollector.isLinkLocalIPv6([0xfe, 0x80, 0, 0]))
        XCTAssertFalse(NetworkCollector.isLinkLocalIPv6([0x26, 0x01]))
    }

    func testCaptivePortalDetection() {
        XCTAssertFalse(NetworkCollector.isCaptivePortal(body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))
        XCTAssertTrue(NetworkCollector.isCaptivePortal(body: "<html>Please sign in</html>"))
    }

    func testCollectPublishesCoreFamiliesWithoutProbes() throws {
        let registry = MetricsRegistry()
        let collector = NetworkCollector(settings: CollectorSettings(name: "network", raw: [:]))
        try collector.start(registry: registry)
        try collector.collect()
        try collector.collect()
        let names = registry.familyNames
        for expected in ["molly_network_primary_interface_info", "molly_network_connected", "molly_network_vpn_active",
                         "molly_network_vpn_interfaces", "molly_network_receive_bytes_total",
                         "molly_network_transmit_bytes_total", "molly_network_interface_up"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        XCTAssertFalse(names.contains("molly_network_probe_success"))
        XCTAssertFalse(names.contains("molly_network_captive_portal"))
        let connected = try XCTUnwrap(registry.gauge("molly_network_connected", help: "").value())
        XCTAssertTrue([0.0, 1.0].contains(connected))
    }

    func testProbeAndCaptiveFamiliesAppearOnlyWhenConfigured() throws {
        let registry = MetricsRegistry()
        let raw: [String: JSONValue] = ["probeURL": .string("http://127.0.0.1:9/"), "captiveCheck": .bool(true)]
        let collector = NetworkCollector(settings: CollectorSettings(name: "network", raw: raw))
        try collector.start(registry: registry)
        let names = registry.familyNames
        XCTAssertTrue(names.contains("molly_network_probe_success"))
        XCTAssertTrue(names.contains("molly_network_probe_latency_seconds"))
        XCTAssertTrue(names.contains("molly_network_captive_portal"))
    }
}
