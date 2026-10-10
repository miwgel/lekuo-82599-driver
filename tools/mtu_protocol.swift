// Shared by Lekuo Control and its independently running MTU watchdog.
// The protocol carries authorization only as a fixed-size binary prefix on stdin.
// It never writes authorization data to files, arguments, diagnostics, or stdout.
import Foundation
import Darwin

enum MTUControlError: LocalizedError {
    case invalidRequest
    case busy
    case unavailable(String)
    case authorization(Int32)
    case peerNotVerified
    case changedDevice
    case changedPreferences
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Choose an Ethernet interface and an MTU between 1280 and 9000."
        case .busy: return "Finish or revert the current packet-size test first."
        case .unavailable(let message): return message
        case .authorization: return "macOS did not authorize changing the network settings."
        case .peerNotVerified: return "Test this packet size successfully with a peer before keeping it."
        case .changedDevice: return "The selected adapter disconnected or changed. Settings were not applied to another device."
        case .changedPreferences: return "Another network configuration change occurred. Lekuo Control stopped to avoid overwriting it."
        case .expired: return "The temporary packet-size test expired."
        }
    }
}

struct MTUWatchdogRequest: Codable, Equatable {
    let interface: String
    let requestedMTU: Int
    let driverBundleIdentifier: String

    func validate() throws {
        guard interface.range(of: "^en[0-9]{1,5}$", options: .regularExpression) != nil,
              (1280...9000).contains(requestedMTU),
              driverBundleIdentifier.utf8.count <= 255,
              driverBundleIdentifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
        else { throw MTUControlError.invalidRequest }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["interface", "requestedMTU", "driverBundleIdentifier"]
        else { throw MTUControlError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

struct MTUWatchdogCommand: Codable {
    enum Action: String, Codable { case keep, save, revert }
    let command: Action
    let verifiedMTU: Int?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["command", "verifiedMTU"]),
              object["command"] != nil
        else { throw MTUControlError.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: data)
        if let verified = value.verifiedMTU, !(1280...9000).contains(verified) {
            throw MTUControlError.invalidRequest
        }
        return value
    }
}

struct MTUWatchdogReply: Codable {
    enum Event: String, Codable { case applied, kept, reverted, error }
    let event: Event
    let originalMTU: Int?
    let requestedMTU: Int?
    let message: String?
    let deadlineContinuousTicks: UInt64?

    init(_ event: Event, originalMTU: Int? = nil, requestedMTU: Int? = nil, message: String? = nil,
         deadlineContinuousTicks: UInt64? = nil) {
        self.event = event
        self.originalMTU = originalMTU
        self.requestedMTU = requestedMTU
        self.message = message
        self.deadlineContinuousTicks = deadlineContinuousTicks
    }
}

/// A shared machine clock aligns the UI with the helper's deadline and advances
/// during sleep. Clock values identify no machine, device, user, or network.
enum MTUTrialClock {
    static var nowTicks: UInt64 { mach_continuous_time() }

    static func deadline(afterSeconds seconds: Int) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0, seconds > 0 else {
            return nowTicks
        }
        let delta = UInt64(Double(seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        let (result, overflow) = nowTicks.addingReportingOverflow(delta)
        return overflow ? UInt64.max : result
    }

    static func remainingSeconds(until deadline: UInt64) -> Int {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return 0 }
        return remainingSeconds(nowTicks: nowTicks, deadline: deadline,
                                numerator: timebase.numer, denominator: timebase.denom)
    }

    static func remainingSeconds(nowTicks: UInt64, deadline: UInt64, numerator: UInt32, denominator: UInt32) -> Int {
        guard deadline > nowTicks, numerator > 0, denominator > 0 else { return 0 }
        let seconds = Double(deadline - nowTicks) * Double(numerator) / Double(denominator) / 1_000_000_000
        return Int(min(Double(MTUTrialDecision.durationSeconds), ceil(seconds)))
    }
}

/// Preserve every current unrelated key, including media configuration changed
/// by another app during the trial. An absent dictionary stays absent on restore.
enum MTUPreferenceEditing {
    static func settingMTU(_ mtu: Int?, in configuration: [String: Any]?) -> [String: Any]? {
        guard configuration != nil || mtu != nil else { return nil }
        var result = configuration ?? [:]
        if let mtu { result["MTU"] = NSNumber(value: mtu) }
        else { result.removeValue(forKey: "MTU") }
        // SystemConfiguration normalizes an empty configuration entity to nil.
        return result.isEmpty ? nil : result
    }
}

/// Decision rules are shared with fixture tests and do not touch a live interface.
struct MTUTrialDecision {
    static let durationSeconds = 45
    let originalMTU: Int
    let requestedMTU: Int
    private(set) var verifiedMTU: Int?

    mutating func recordProbe(mtu: Int, nowTicks: UInt64, deadlineTicks: UInt64) throws {
        guard nowTicks < deadlineTicks else { throw MTUControlError.expired }
        guard mtu == requestedMTU else { throw MTUControlError.peerNotVerified }
        verifiedMTU = mtu
    }

    func authorizeKeep(claimedVerifiedMTU: Int?, nowTicks: UInt64, deadlineTicks: UInt64) throws {
        guard nowTicks < deadlineTicks else { throw MTUControlError.expired }
        if requestedMTU > originalMTU && claimedVerifiedMTU != requestedMTU {
            throw MTUControlError.peerNotVerified
        }
    }

    /// Rollback never overwrites a MTU preference changed by another app.
    static func canRestore(currentPreference: Int?, expectedPreference: Int?) -> Bool {
        currentPreference == expectedPreference
    }
}
