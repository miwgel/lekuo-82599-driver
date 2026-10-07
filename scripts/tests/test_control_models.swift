import Foundation

@main
struct ControlModelTests {
    static func main() throws {
        let before = TrafficRateSample(interfaceID: "en42", receivedBytes: 10_000, transmittedBytes: 20_000, uptime: 100)
        let after = TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: 102)
        check(TrafficRateCalculator.rates(previous: before, current: after) ==
              TrafficRates(receiveBitsPerSecond: 40_000, transmitBitsPerSecond: 20_000), "byte deltas become bits per second")
        check(TrafficRateCalculator.rates(previous: nil, current: after) == .unavailable, "first sample has no rate")
        for invalid in [
            TrafficRateSample(interfaceID: "en43", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: 102),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 9_999, transmittedBytes: 25_000, uptime: 102),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 19_999, uptime: 102),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: 111),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: 100),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: 99),
            TrafficRateSample(interfaceID: "en42", receivedBytes: 20_000, transmittedBytes: 25_000, uptime: .nan)
        ] { check(TrafficRateCalculator.rates(previous: before, current: invalid) == .unavailable, "reset/interface/sleep invalidates rates") }
        let idle = TrafficRateSample(interfaceID: "en42", receivedBytes: 10_000, transmittedBytes: 20_000, uptime: 102)
        check(TrafficRateCalculator.rates(previous: before, current: idle) ==
              TrafficRates(receiveBitsPerSecond: 0, transmitBitsPerSecond: 0), "idle traffic is zero")

        check(NumericVersion.sanitized("2026.10.07") == "2026.10.07", "retain date version formatting")
        check(NumericVersion.compare("1.0", "1.0.0") == .orderedSame, "normalize missing trailing version fields")
        check(NumericVersion.compare("2026.10.07", "2026.9.30") == .orderedDescending, "numeric date comparison")
        check(!NumericVersion.permitsReplacement(existingShort: "2026.10.07", existingBuild: "16",
                                                 candidateShort: "2026.10.06", candidateBuild: "20"), "reject marketing downgrade")
        check(!NumericVersion.permitsReplacement(existingShort: "2026.10.07", existingBuild: "16",
                                                 candidateShort: "2026.10.07", candidateBuild: "15"), "reject build downgrade")
        check(NumericVersion.permitsReplacement(existingShort: "2026.10.07", existingBuild: "16",
                                                candidateShort: "2026.10.07", candidateBuild: "16"), "allow same-version reinstall")
        let exampleEmail = ["person", "example.invalid"].joined(separator: "@")
        let exampleHome = "/" + ["Users", "ExamplePerson", "private"].joined(separator: "/")
        for invalid in ["", "1..0", "1.0-private", exampleEmail, "192.0.2.10", "2001:db8::10",
                        exampleHome, "1\n2", "１２", "99999999999999999999999999"] {
            check(NumericVersion.sanitized(invalid) == nil, "reject non-version identity text")
        }

        let sensitiveFixture = ["ExamplePerson", exampleEmail, exampleHome, "192.0.2.10", "2001:db8::10",
                                "02:00:00:00:00:01", "SERIAL-EXAMPLE", "TEAM-EXAMPLE", "com.example.private"].joined(separator: " ")
        let snapshot = AdapterSnapshot(id: sensitiveFixture, displayName: sensitiveFixture, mtu: 9000,
            minimumMTU: 1280, maximumMTU: 9000, isEnabled: true, linkState: .active,
            linkSpeedBitsPerSecond: nil, receivedBytes: 9_000_000_000, transmittedBytes: 8_000_000_000,
            inputErrors: 3, outputErrors: 4, inputDrops: 5)
        let report = DiagnosticReport(date: Date(timeIntervalSince1970: 0), appVersion: sensitiveFixture,
            driverVersion: "2026.10.07", driverBuild: sensitiveFixture,
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1),
            driverEnabled: true, adapters: [snapshot])
        let text = try report.json()
        for marker in sensitiveFixture.split(separator: " ") {
            check(!text.contains(marker), "omit all identity fixtures")
        }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        check(Set(json.keys) == Set(["schemaVersion", "generatedAtUTC", "versions", "osVersion", "driverEnabled", "adapters"]),
              "closed top-level diagnostic allowlist")
        let adapters = json["adapters"] as! [[String: Any]]
        check(Set(adapters[0].keys) == Set(["number", "mtu", "minimumMTU", "maximumMTU", "enabled", "link",
            "receivedBytes", "transmittedBytes", "inputErrors", "outputErrors", "inputDrops"]), "closed adapter diagnostic allowlist")
        check(adapters[0]["number"] as? Int == 1, "use numbered adapters without BSD identifiers")
        check((adapters[0]["receivedBytes"] as? NSNumber)?.uint64Value == 9_000_000_000, "preserve useful 64-bit counters")
        check((json["versions"] as? [String: String]) == ["driver": "2026.10.07"], "omit invalid version strings")

        let adapter = AdapterSnapshot(id: "en42", displayName: "Example adapter", mtu: 9000,
            minimumMTU: 1280, maximumMTU: 9000, isEnabled: true, linkState: .active,
            linkSpeedBitsPerSecond: nil, receivedBytes: 0, transmittedBytes: 0, inputErrors: 0, outputErrors: 0, inputDrops: 0)
        let peer = AdapterService.literalPeer("192.0.2.10", interface: "en42")!
        let proof = MTUProbeProof(interface: "en42", mtu: 9000, peer: peer, uptime: 100)
        func mayKeep(id: String? = "en42", mtu: Int = 9000, sampled: Double = 100, now: Double = 102,
                     receiver: String = "192.0.2.10", requiresProbe: Bool = true, evidence: MTUProbeProof? = proof) -> Bool {
            MTUKeepEvidence.isCurrent(trialInterface: "en42", trialMTU: mtu, selectedID: id,
                selected: adapter, sampledAt: sampled, now: now, requiresProbe: requiresProbe,
                proof: evidence, currentPeer: receiver)
        }
        check(mayKeep(), "fresh exact adapter/MTU/peer proof permits keep")
        check(!mayKeep(id: "en43"), "selection changes invalidate proof")
        check(!mayKeep(mtu: 1500), "MTU changes invalidate proof")
        check(!mayKeep(receiver: "192.0.2.11"), "peer changes invalidate proof")
        check(!mayKeep(sampled: 90), "stale interface snapshot blocks keep")
        check(!mayKeep(sampled: 118, now: 118), "expired probe blocks keep")
        check(!mayKeep(evidence: nil), "enlargement needs proof")
        check(mayKeep(receiver: "", requiresProbe: false, evidence: nil), "shrink needs no peer proof")
        check(!mayKeep(now: .nan), "invalid clock data cannot authorize keep")

        let record = PendingDriverRestart(operation: .activation, shortVersion: "2026.10.07", buildVersion: "16", bootMarker: "100.1")
        let encoded = try JSONEncoder().encode(record)
        try check(JSONDecoder().decode(PendingDriverRestart.self, from: encoded) == record, "restart record survives serialization")
        check(record.isValid, "numeric restart metadata")
        check(!PendingDriverRestart(operation: .activation, shortVersion: "1", buildVersion: "16", bootMarker: sensitiveFixture).isValid,
              "restart record excludes nonnumeric identifiers")
        print("Control models: rates, version downgrade policy, diagnostic privacy, exact MTU keep evidence, and restart metadata tests passed.")
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        if try !condition() { fatalError("Failed: \(label)") }
    }
}
