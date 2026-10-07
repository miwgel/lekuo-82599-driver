import Foundation

struct TrafficRateSample: Equatable, Sendable {
    let interfaceID: String
    let receivedBytes: UInt64
    let transmittedBytes: UInt64
    let uptime: TimeInterval
}

struct TrafficRates: Equatable, Sendable {
    let receiveBitsPerSecond: Double?
    let transmitBitsPerSecond: Double?
    static let unavailable = TrafficRates(receiveBitsPerSecond: nil, transmitBitsPerSecond: nil)
}

struct MTUProbeProof: Sendable {
    let interface: String
    let mtu: Int
    let peer: AdapterService.LiteralPeer
    let uptime: TimeInterval
}

enum MTUKeepEvidence {
    static func isCurrent(trialInterface: String, trialMTU: Int, selectedID: String?,
                          selected: AdapterSnapshot?, sampledAt: TimeInterval?, now: TimeInterval,
                          requiresProbe: Bool, proof: MTUProbeProof?, currentPeer: String) -> Bool {
        guard selectedID == trialInterface, selected?.id == trialInterface, selected?.mtu == trialMTU,
              selected?.isEnabled == true, let sampledAt, now.isFinite, sampledAt.isFinite,
              (0...5).contains(now - sampledAt) else { return false }
        guard requiresProbe else { return true }
        guard let proof, proof.interface == trialInterface, proof.mtu == trialMTU,
              proof.uptime.isFinite, (0...15).contains(now - proof.uptime),
              AdapterService.literalPeer(currentPeer, interface: trialInterface) == proof.peer else { return false }
        return true
    }
}

enum TrafficRateCalculator {
    static func rates(previous: TrafficRateSample?, current: TrafficRateSample) -> TrafficRates {
        guard let previous, !current.interfaceID.isEmpty, previous.interfaceID == current.interfaceID,
              previous.uptime.isFinite, current.uptime.isFinite,
              current.receivedBytes >= previous.receivedBytes,
              current.transmittedBytes >= previous.transmittedBytes else { return .unavailable }
        let interval = current.uptime - previous.uptime
        guard interval > 0, interval <= 10 else { return .unavailable }
        let receive = Double(current.receivedBytes - previous.receivedBytes) * 8 / interval
        let transmit = Double(current.transmittedBytes - previous.transmittedBytes) * 8 / interval
        guard receive.isFinite, transmit.isFinite else { return .unavailable }
        return TrafficRates(receiveBitsPerSecond: receive, transmitBitsPerSecond: transmit)
    }
}

enum NumericVersion {
    static func components(_ text: String) -> [UInt64]? {
        guard !text.isEmpty, text.utf8.count <= 64 else { return nil }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var result: [UInt64] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.count <= 16,
                  field.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(field) else { return nil }
            result.append(value)
        }
        return result
    }
    static func sanitized(_ text: String?) -> String? {
        guard let text, components(text) != nil else { return nil }
        return text
    }
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
    static func permitsReplacement(existingShort: String, existingBuild: String,
                                   candidateShort: String, candidateBuild: String) -> Bool {
        guard let marketing = compare(candidateShort, existingShort),
              let build = compare(candidateBuild, existingBuild) else { return false }
        return marketing == .orderedDescending || (marketing == .orderedSame && build != .orderedAscending)
    }
}

/// Encoded allowlist. Names, addresses, identifiers, paths, errors and logs are
/// never represented, so their privacy does not depend on string redaction.
struct DiagnosticReport: Encodable, Sendable {
    struct Versions: Encodable, Sendable { let app: String?; let driver: String?; let driverBuild: String? }
    struct OSVersion: Encodable, Sendable { let major: Int; let minor: Int; let patch: Int }
    struct Adapter: Encodable, Sendable {
        let number: Int
        let mtu: Int
        let minimumMTU: Int
        let maximumMTU: Int
        let enabled: Bool
        let link: String
        let negotiatedLinkBitsPerSecond: UInt64?
        let receivedBytes: UInt64
        let transmittedBytes: UInt64
        let inputErrors: UInt64
        let outputErrors: UInt64
        let inputDrops: UInt64
    }
    let schemaVersion = 1
    let generatedAtUTC: String
    let versions: Versions
    let osVersion: OSVersion
    let driverEnabled: Bool
    let adapters: [Adapter]

    init(date: Date = Date(), appVersion: String?, driverVersion: String?, driverBuild: String?,
         osVersion: OperatingSystemVersion, driverEnabled: Bool, adapters: [AdapterSnapshot]) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        generatedAtUTC = formatter.string(from: date)
        versions = Versions(app: NumericVersion.sanitized(appVersion), driver: NumericVersion.sanitized(driverVersion),
                            driverBuild: NumericVersion.sanitized(driverBuild))
        self.osVersion = OSVersion(major: max(0, osVersion.majorVersion), minor: max(0, osVersion.minorVersion),
                                   patch: max(0, osVersion.patchVersion))
        self.driverEnabled = driverEnabled
        self.adapters = adapters.enumerated().map { offset, s in
            Adapter(number: offset + 1, mtu: s.mtu, minimumMTU: s.minimumMTU, maximumMTU: s.maximumMTU,
                    enabled: s.isEnabled, link: s.linkState.rawValue, negotiatedLinkBitsPerSecond: s.linkSpeedBitsPerSecond,
                    receivedBytes: s.receivedBytes, transmittedBytes: s.transmittedBytes,
                    inputErrors: s.inputErrors, outputErrors: s.outputErrors, inputDrops: s.inputDrops)
        }
    }
    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct PendingDriverRestart: Codable, Equatable, Sendable {
    enum Operation: String, Codable { case activation, deactivation }
    let operation: Operation
    let shortVersion: String
    let buildVersion: String
    let bootMarker: String?
    var isValid: Bool {
        NumericVersion.components(shortVersion) != nil && NumericVersion.components(buildVersion) != nil &&
            (bootMarker == nil || NumericVersion.components(bootMarker!) != nil)
    }
}
