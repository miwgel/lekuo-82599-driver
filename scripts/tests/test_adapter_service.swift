import Foundation
import Darwin

// Compile with AdapterService.swift. Fixtures use documentation-only addresses
// and invented interface names; no live interfaces, routes, or peers are queried.
@main
struct AdapterServiceTests {
    static func main() throws {
        let bundle = "com.example.Lekuo82599Driver"
        let driver = AdapterService.RegistryNode(className: "IOUserNetworkEthernet", properties: [
            "IOUserServerName": bundle, "IOUserClass": "Lekuo82599"
        ])
        let controller = AdapterService.RegistryNode(className: "IOEthernetController", properties: [:])
        check(AdapterService.isOwnedInterface(name: "en42", ancestors: [controller, driver],
                                             driverBundleIdentifier: bundle), "verified parent ownership")
        check(!AdapterService.isOwnedInterface(name: "en42", ancestors: [controller],
                                              driverBundleIdentifier: bundle), "generic Ethernet is not owned")
        check(!AdapterService.isOwnedInterface(name: "en42", ancestors: [driver],
                                              driverBundleIdentifier: bundle + ".other"), "exact bundle match")
        let unrelated = AdapterService.RegistryNode(className: "IOEthernetController",
                                                    properties: ["CFBundleIdentifier": bundle])
        check(!AdapterService.isOwnedInterface(name: "en42", ancestors: [unrelated],
                                              driverBundleIdentifier: bundle), "bundle alone is insufficient")
        check(!AdapterService.isOwnedInterface(name: "utun42", ancestors: [driver],
                                              driverBundleIdentifier: bundle), "reject tunnels")
        for name in ["en", "en42;whoami", "en4\n2", "en-1", "en４", "en12345678901234"] {
            check(!AdapterService.isEthernetBSDName(name), "reject invalid interface")
        }
        check(AdapterService.isEthernetBSDName("en0"), "valid Ethernet interface")

        var fixture = if_msghdr2()
        fixture.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        fixture.ifm_version = UInt8(RTM_VERSION)
        fixture.ifm_type = UInt8(RTM_IFINFO2)
        fixture.ifm_index = 42
        fixture.ifm_flags = IFF_UP
        fixture.ifm_data.ifi_type = UInt8(IFT_ETHER)
        fixture.ifm_data.ifi_mtu = 9000
        fixture.ifm_data.ifi_ibytes = 9_000_000_000
        fixture.ifm_data.ifi_obytes = 10_000_000_000
        fixture.ifm_data.ifi_ierrors = 7
        fixture.ifm_data.ifi_oerrors = 8
        fixture.ifm_data.ifi_iqdrops = 9
        let fixtureData = withUnsafeBytes(of: &fixture) { Data($0) }
        let parsed = try AdapterService.parseInterfaceMessages(fixtureData)
        check(parsed[42] == AdapterService.InterfaceMetrics(mtu: 9000, isEnabled: true,
            receivedBytes: 9_000_000_000, transmittedBytes: 10_000_000_000,
            inputErrors: 7, outputErrors: 8, inputDrops: 9), "preserve all 64-bit counters")
        let prefixed = Data([0, 0, 0, 0]) + fixtureData
        try check(AdapterService.parseInterfaceMessages(prefixed.dropFirst(4)) == parsed,
                  "parse Data slices with nonzero start indices")
        fixture.ifm_flags = 0
        let disabledData = withUnsafeBytes(of: &fixture) { Data($0) }
        try check(AdapterService.parseInterfaceMessages(disabledData)[42]?.isEnabled == false,
              "read actual enabled flag")
        fixture.ifm_data.ifi_type = UInt8(IFT_LOOP)
        let loopbackData = withUnsafeBytes(of: &fixture) { Data($0) }
        try check(AdapterService.parseInterfaceMessages(loopbackData).isEmpty, "exclude non-Ethernet counters")
        for malformed in [Data([0, 0, 0, 0]), Data(fixtureData.dropLast()), Data([1, 0]),
                          Data([4, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)])] {
            do {
                _ = try AdapterService.parseInterfaceMessages(malformed)
                fatalError("Malformed routing statistics were accepted")
            } catch AdapterServiceError.malformedInterfaceStatistics { }
        }

        check(AdapterService.literalPeer("192.0.2.10", interface: "en42")?.family == .ipv4,
              "literal IPv4")
        check(AdapterService.literalPeer("2001:db8::10", interface: "en42")?.family == .ipv6,
              "literal IPv6")
        check(AdapterService.literalPeer("fe80::10%en42", interface: "en42")?.isLinkLocal == true,
              "link-local scope matches selected interface")
        for invalid in ["server.example", "192.0.2.10;whoami", "127.0.0.1", "0.0.0.0",
                        "224.0.0.1", "255.255.255.255", "192.0.2.10%en42", "::", "::1",
                        "ff02::1", "::ffff:192.0.2.10", "fe80::10%en43", "fe80::10%",
                        "2001:db8::10%en42", "fe80::10%en42%en42", "192.0.2.10\0suffix",
                        "192.0.2.\n10", "-n", ""] {
            check(AdapterService.literalPeer(invalid, interface: "en42") == nil, "reject invalid or non-unicast peer")
        }
        check(AdapterService.payloadSize(mtu: 9000, family: .ipv4) == 8972, "IPv4 header accounting")
        check(AdapterService.payloadSize(mtu: 9000, family: .ipv6) == 8952, "IPv6 header accounting")
        check(AdapterService.routeInterface(from: "route to: 192.0.2.10\n  interface: en42\nflags: <UP>") == "en42",
              "parse selected route interface")
        check(AdapterService.routeInterface(from: "interface: en42\ninterface: en43") == nil,
              "reject ambiguous route")
        check(AdapterService.routeInterface(from: "interface: utun42") == nil, "reject tunnel route")
        check(AdapterService.receivedBothReplies(in: "2 packets transmitted, 2 packets received, 0.0% packet loss"),
              "two complete IPv4 replies")
        check(AdapterService.receivedBothReplies(in: "2 packets transmitted, 2 received, 0.0% packet loss"),
              "alternate two-reply summary")
        check(!AdapterService.receivedBothReplies(in: "2 packets transmitted, 1 packets received, 50.0% packet loss"),
              "one reply is insufficient")
        check(!AdapterService.receivedBothReplies(in: "2 packets transmitted, 20 packets received, 0.0% packet loss"),
              "summary is matched exactly")
        let summary = "2 packets transmitted, 2 packets received, 0.0% packet loss"
        let fullReplies = "8980 bytes from 192.0.2.10: icmp_seq=0 ttl=64 time=1.0 ms\n" +
                          "8980 bytes from 192.0.2.10: icmp_seq=1 ttl=64 time=1.0 ms\n" + summary
        check(AdapterService.receivedBothFullSizeReplies(in: fullReplies, expectedReplyBytes: 8980),
              "both IPv4 replies have full ICMP size")
        let v6Replies = "8960 bytes from 2001:db8::10: icmp_seq=0 hlim=64 time=1.0 ms\n" +
                        "8960 bytes from 2001:db8::10: icmp_seq=1 hlim=64 time=1.0 ms\n" + summary
        check(AdapterService.receivedBothFullSizeReplies(in: v6Replies, expectedReplyBytes: 8960),
              "both IPv6 replies have full ICMP size")
        check(!AdapterService.receivedBothFullSizeReplies(in: summary, expectedReplyBytes: 8980),
              "summary alone cannot prove reply size")
        check(!AdapterService.receivedBothFullSizeReplies(in: fullReplies.replacingOccurrences(of: "icmp_seq=1", with: "icmp_seq=0"),
                                                        expectedReplyBytes: 8980), "duplicate sequence is insufficient")
        check(!AdapterService.receivedBothFullSizeReplies(in: fullReplies.replacingOccurrences(of: "8980", with: "64"),
                                                        expectedReplyBytes: 8980), "short replies cannot prove jumbo compatibility")

        let active = IFM_AVALID | IFM_ACTIVE
        check(AdapterService.negotiatedSpeed(activeMedia: IFM_ETHER | IFM_AUTO, status: active) == nil,
              "automatic media does not claim wire speed")
        check(AdapterService.negotiatedSpeed(activeMedia: IFM_ETHER | IFM_10G_SR, status: active) == 10_000_000_000,
              "explicit negotiated 10 Gb/s")
        check(AdapterService.negotiatedSpeed(activeMedia: IFM_ETHER | IFM_1000_T, status: active) == 1_000_000_000,
              "explicit negotiated 1 Gb/s")
        check(AdapterService.negotiatedSpeed(activeMedia: IFM_ETHER | IFM_10G_SR, status: IFM_AVALID) == nil,
              "inactive media has no negotiated speed")
        check(AdapterService.negotiatedSpeed(activeMedia: IFM_ETHER | IFM_10G_SR, status: IFM_ACTIVE) == nil,
              "invalid media status has no negotiated speed")
        print("AdapterService: ownership, 64-bit statistics, address validation, route/reply parsing, MTU payloads, and media tests passed.")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        if try !condition() { fatalError("Failed: \(label)") }
    }
}
