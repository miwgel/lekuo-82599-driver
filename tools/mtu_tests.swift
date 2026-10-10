// Pure fixture checks. This target imports no SystemConfiguration/Security and
// never starts the helper, requests authorization, or touches a live interface.
import Foundation

@main
struct MTUFixtureTests {
    static func main() throws {
        for mtu in [1280, 1500, 9000] {
            let request = MTUWatchdogRequest(interface: "en10", requestedMTU: mtu, driverBundleIdentifier: "com.example.Lekuo82599Driver")
            let roundTrip = try MTUWatchdogRequest.decode(JSONEncoder().encode(request))
            precondition(roundTrip == request)
        }
        for interface in ["en", "en-1", "en100000", "en10;anything", "utun1", "lo0", "en10\n"] {
            try rejects { try MTUWatchdogRequest(interface: interface, requestedMTU: 1500, driverBundleIdentifier: "com.example.Driver").validate() }
        }
        for mtu in [0, 1279, 9001, Int.max] {
            try rejects { try MTUWatchdogRequest(interface: "en10", requestedMTU: mtu, driverBundleIdentifier: "com.example.Driver").validate() }
        }
        for bundle in ["", "Driver", "com.example.Driver\"", "com.example.Driver\n", "com.example..Driver"] {
            try rejects { try MTUWatchdogRequest(interface: "en10", requestedMTU: 1500, driverBundleIdentifier: bundle).validate() }
        }
        try rejects {
            _ = try MTUWatchdogRequest.decode(Data(#"{"interface":"en10","requestedMTU":1500,"driverBundleIdentifier":"com.example.Driver","authorization":"bad"}"#.utf8))
        }
        try rejects {
            _ = try MTUWatchdogRequest.decode(Data(#"{"interface":"en10","requestedMTU":1500.5,"driverBundleIdentifier":"com.example.Driver"}"#.utf8))
        }
        try rejects {
            _ = try MTUWatchdogRequest.decode(Data(#"{"interface":"en10","requestedMTU":true,"driverBundleIdentifier":"com.example.Driver"}"#.utf8))
        }
        try rejects { _ = try MTUWatchdogRequest.decode(Data(repeating: 65, count: 1025)) }
        try rejects { _ = try MTUWatchdogCommand.decode(Data(#"{"command":"keep","verifiedMTU":9000,"sudo":true}"#.utf8)) }
        try rejects { _ = try MTUWatchdogCommand.decode(Data(#"{"command":"keep","verifiedMTU":16000}"#.utf8)) }
        try rejects { _ = try MTUWatchdogCommand.decode(Data(#"{"command":"anything"}"#.utf8)) }
        let directSave = try MTUWatchdogCommand.decode(Data(#"{"command":"save"}"#.utf8))
        precondition(directSave.command == .save && directSave.verifiedMTU == nil)

        var enlargement = MTUTrialDecision(originalMTU: 1500, requestedMTU: 9000)
        try rejects { try enlargement.authorizeKeep(claimedVerifiedMTU: nil, nowTicks: 0, deadlineTicks: 45) }
        try rejects { try enlargement.authorizeKeep(claimedVerifiedMTU: 1500, nowTicks: 0, deadlineTicks: 45) }
        try rejects { try enlargement.recordProbe(mtu: 2000, nowTicks: 0, deadlineTicks: 45) }
        try rejects { try enlargement.recordProbe(mtu: 9000, nowTicks: 45, deadlineTicks: 45) }
        precondition(enlargement.verifiedMTU == nil)
        try enlargement.recordProbe(mtu: 9000, nowTicks: 5, deadlineTicks: 45)
        try enlargement.authorizeKeep(claimedVerifiedMTU: enlargement.verifiedMTU, nowTicks: 10, deadlineTicks: 45)
        try rejects { try enlargement.authorizeKeep(claimedVerifiedMTU: enlargement.verifiedMTU, nowTicks: 46, deadlineTicks: 45) }
        try MTUTrialDecision(originalMTU: 9000, requestedMTU: 1500).authorizeKeep(claimedVerifiedMTU: nil, nowTicks: 0, deadlineTicks: 45)

        precondition(MTUTrialDecision.canRestore(currentPreference: nil, expectedPreference: nil))
        precondition(MTUTrialDecision.canRestore(currentPreference: 9000, expectedPreference: 9000))
        precondition(!MTUTrialDecision.canRestore(currentPreference: 1500, expectedPreference: nil))
        precondition(!MTUTrialDecision.canRestore(currentPreference: nil, expectedPreference: 1500))
        precondition(!MTUTrialDecision.canRestore(currentPreference: 2000, expectedPreference: 9000))
        precondition(MTUTrialDecision.durationSeconds == 45)

        let saved: [String: Any] = ["MediaSubType": "autoselect", "MediaOptions": ["full-duplex"], "MTU": 1500,
                                  "OtherSetting": ["nested": true]]
        let target = MTUPreferenceEditing.settingMTU(9000, in: saved)!
        precondition(target["MTU"] as? Int == 9000)
        var withoutMTU = target
        withoutMTU.removeValue(forKey: "MTU")
        var originalWithoutMTU = saved
        originalWithoutMTU.removeValue(forKey: "MTU")
        precondition(NSDictionary(dictionary: withoutMTU).isEqual(to: originalWithoutMTU))
        let absent = MTUPreferenceEditing.settingMTU(nil, in: saved)!
        precondition(absent["MTU"] == nil)
        precondition(NSDictionary(dictionary: absent).isEqual(to: originalWithoutMTU))
        precondition(MTUPreferenceEditing.settingMTU(nil, in: nil) == nil)
        let temporaryFromAbsent = MTUPreferenceEditing.settingMTU(9000, in: nil)
        precondition(temporaryFromAbsent?["MTU"] as? Int == 9000)
        precondition(MTUPreferenceEditing.settingMTU(nil, in: temporaryFromAbsent) == nil)
        precondition(MTUPreferenceEditing.settingMTU(nil, in: [:]) == nil)
        precondition(MTUPreferenceEditing.settingMTU(0, in: saved)?["MTU"] as? Int == 0)

        precondition(MTUTrialClock.remainingSeconds(nowTicks: 0, deadline: 45_000_000_000, numerator: 1, denominator: 1) == 45)
        precondition(MTUTrialClock.remainingSeconds(nowTicks: 2_000_000_000, deadline: 45_000_000_000, numerator: 1, denominator: 1) == 43)
        precondition(MTUTrialClock.remainingSeconds(nowTicks: 44_900_000_000, deadline: 45_000_000_000, numerator: 1, denominator: 1) == 1)
        precondition(MTUTrialClock.remainingSeconds(nowTicks: 45_000_000_000, deadline: 45_000_000_000, numerator: 1, denominator: 1) == 0)
        precondition(MTUTrialClock.remainingSeconds(nowTicks: 50_000_000_000, deadline: 45_000_000_000, numerator: 1, denominator: 1) == 0)
        precondition(MTUTrialClock.remainingSeconds(nowTicks: 0, deadline: 10_000_000_000, numerator: 125, denominator: 3) == 45)
        print("MTU fixtures passed: protocol bounds, probe gate, preference key preservation/conflicts, and shared deadline alignment.")
    }

    private static func rejects(_ work: () throws -> Void) throws {
        do {
            try work()
        } catch { return }
        throw NSError(domain: "MTUFixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected request or state to be rejected"])
    }
}
