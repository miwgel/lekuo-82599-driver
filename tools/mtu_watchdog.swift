// Build as a separate signed executable at Contents/Helpers/LekuoMTUWatchdog.
// This process remains alive if the containing app exits; EOF means revert.
import Darwin
import Foundation
import IOKit
import Security
import SystemConfiguration

private struct MTUDeviceIdentity: Equatable {
    let interfaceRegistryID: UInt64
    let driverRegistryID: UInt64

    static func read(interface: String, driverBundleIdentifier: String) throws -> Self {
        var matches: [UInt64: Self] = [:]
        var visited = Set<UInt64>()
        // Mirror AdapterService: DriverKit's interfaces need not conform to the
        // legacy kernel interface class. A candidate must still have the same
        // exact owner bundle and Lekuo class on one ancestor node.
        for interfaceClass in ["IONetworkInterface", "IOUserNetworkInterface", "IOUserEthernetInterface"] {
            var iterator: io_iterator_t = 0
            guard let matching = IOServiceMatching(interfaceClass),
                  IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                throw MTUControlError.changedDevice
            }
            defer { IOObjectRelease(iterator) }
            while true {
                let entry = IOIteratorNext(iterator)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                guard property(entry, "BSD Name") == interface else { continue }
                var interfaceID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &interfaceID) == KERN_SUCCESS,
                      visited.insert(interfaceID).inserted else { continue }
                var node = entry
                IOObjectRetain(node)
                defer { IOObjectRelease(node) }
                for _ in 0..<12 {
                    var parent: io_registry_entry_t = 0
                    guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                    IOObjectRelease(node)
                    node = parent
                    var classBuffer = [CChar](repeating: 0, count: 128)
                    let className = IOObjectGetClass(node, &classBuffer) == KERN_SUCCESS ? String(cString: classBuffer) : ""
                    let isLekuoClass = property(node, "IOUserClass") == "Lekuo82599" ||
                        className == "Lekuo82599" || className == "IOUserNetworkEthernet"
                    let ownership = isLekuoClass && ["CFBundleIdentifier", "IOUserServerName", "IOBundleIdentifier", "IOUserServerBundleIdentifier"]
                        .contains { property(node, $0) == driverBundleIdentifier }
                    if ownership {
                        var driverID: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(node, &driverID) == KERN_SUCCESS {
                            matches[interfaceID] = Self(interfaceRegistryID: interfaceID, driverRegistryID: driverID)
                        }
                        break
                    }
                }
            }
        }
        guard matches.count == 1, let result = matches.values.first else { throw MTUControlError.changedDevice }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

private func activeMTU(_ name: String) throws -> Int {
    var request = ifreq()
    let bytes = Array(name.utf8) + [0]
    guard bytes.count <= Int(IFNAMSIZ) else { throw MTUControlError.invalidRequest }
    withUnsafeMutablePointer(to: &request.ifr_name) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: Int(IFNAMSIZ)) { output in
            for (index, byte) in bytes.enumerated() { output[index] = byte }
        }
    }
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { throw MTUControlError.unavailable("Could not read the adapter packet size.") }
    defer { close(descriptor) }
    // Swift cannot import the structure-based SIOCGIFMTU macro. This is its
    // _IOWR('i', 51, struct ifreq) expansion, using the SDK structure's size.
    let getMTURequest = UInt(0xC0000000) | (UInt(MemoryLayout<ifreq>.size) << 16) | (UInt(0x69) << 8) | 51
    guard ioctl(descriptor, getMTURequest, &request) == 0 else { throw MTUControlError.changedDevice }
    return Int(request.ifr_ifru.ifru_mtu)
}

/// A credential-free per-user/interface lease prevents two app instances or a
/// relaunched app from starting competing watchdog transactions. The empty lock
/// file is deliberately retained: unlinking would let another process obtain a
/// different inode while an existing watchdog still holds its lock.
private final class MTUWatchdogLease {
    private var descriptor: Int32?

    init(interface: String) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lekuo-control-mtu-\(getuid())-\(interface).lock")
        let opened = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw MTUControlError.busy }
        var metadata = stat()
        guard fstat(opened, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_nlink == 1, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
              flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            throw MTUControlError.busy
        }
        descriptor = opened
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}

private final class MTUPreferencesTransaction {
    private struct PreferenceTarget {
        let interface: SCNetworkInterface
        let setID: String
        let serviceID: String
    }
    private let request: MTUWatchdogRequest
    private let authorization: AuthorizationRef
    private let identity: MTUDeviceIdentity
    private let networkLocationID: String
    private let networkServiceID: String
    let originalActiveMTU: Int
    let originalPreference: Int?
    private var expectedPreference: Int?
    private var trialWasCommitted = false

    init(request: MTUWatchdogRequest, authorization: AuthorizationRef) throws {
        self.request = request
        self.authorization = authorization
        identity = try .read(interface: request.interface, driverBundleIdentifier: request.driverBundleIdentifier)
        originalActiveMTU = try activeMTU(request.interface)
        guard (1280...9000).contains(originalActiveMTU) else {
            throw MTUControlError.unavailable("The existing packet size is outside this driver's supported range.")
        }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Lekuo Control MTU" as CFString, nil, authorization) else {
            throw Self.configurationError()
        }
        guard SCPreferencesLock(preferences, false) else { throw Self.configurationError() }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        let selected = try Self.targetInterface(preferences, name: request.interface)
        networkLocationID = selected.setID
        networkServiceID = selected.serviceID
        let target = selected.interface
        var minimum: Int32 = 0
        var maximum: Int32 = 0
        guard SCNetworkInterfaceCopyMTU(target, nil, &minimum, &maximum),
              minimum >= 0, maximum >= minimum,
              Int(minimum)...Int(maximum) ~= request.requestedMTU else {
            throw MTUControlError.unavailable("macOS does not report support for that packet size on this adapter.")
        }
        originalPreference = try Self.preferenceMTU(target)
        expectedPreference = originalPreference
    }

    func applyTrial() throws {
        guard try activeMTU(request.interface) == originalActiveMTU else { throw MTUControlError.changedPreferences }
        // Apply reads committed storage. Wait for the running interface to adopt
        // the trial before restoring saved storage, so configd cannot miss it.
        try updatePreference(request.requestedMTU, apply: true)
        trialWasCommitted = true
        try waitForActiveMTU(request.requestedMTU)
        try updatePreference(originalPreference, apply: false)
        try verifySavedAndActive(expectedActive: request.requestedMTU)
    }

    func keep(verifiedMTU: Int?, deadlineTicks: UInt64) throws {
        try MTUTrialDecision(originalMTU: originalActiveMTU, requestedMTU: request.requestedMTU)
            .authorizeKeep(claimedVerifiedMTU: verifiedMTU, nowTicks: MTUTrialClock.nowTicks, deadlineTicks: deadlineTicks)
        try save(deadlineTicks: deadlineTicks)
    }

    // An explicit local setting does not assert anything about a remote peer.
    // Preserve authorization, device ownership, concurrency and deadline checks.
    func save(deadlineTicks: UInt64) throws {
        guard MTUTrialClock.nowTicks < deadlineTicks else { throw MTUControlError.expired }
        try verifySavedAndActive(expectedActive: request.requestedMTU)
        try updatePreference(request.requestedMTU, apply: true)
        try waitForActiveMTU(request.requestedMTU)
        trialWasCommitted = false
    }

    func rollback() throws {
        guard trialWasCommitted || expectedPreference != originalPreference else { return }
        let currentActiveMTU = try activeMTU(request.interface)
        guard currentActiveMTU == originalActiveMTU || currentActiveMTU == request.requestedMTU else {
            throw MTUControlError.changedPreferences
        }
        // Restore the exact former runtime MTU, including a value set by ifconfig,
        // then restore the former preference key (including its absence).
        try updatePreference(originalActiveMTU, apply: true)
        try waitForActiveMTU(originalActiveMTU)
        try updatePreference(originalPreference, apply: false)
        try verifySavedAndActive(expectedActive: originalActiveMTU)
        trialWasCommitted = false
    }

    private func validateIdentity() throws {
        guard try MTUDeviceIdentity.read(interface: request.interface, driverBundleIdentifier: request.driverBundleIdentifier) == identity else {
            throw MTUControlError.changedDevice
        }
    }

    private func updatePreference(_ mtu: Int?, apply: Bool) throws {
        try validateIdentity()
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Lekuo Control MTU" as CFString, nil, authorization) else {
            throw Self.configurationError()
        }
        guard SCPreferencesLock(preferences, false) else { throw Self.configurationError() }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        let selected = try Self.targetInterface(preferences, name: request.interface)
        guard selected.setID == networkLocationID, selected.serviceID == networkServiceID else {
            throw MTUControlError.changedPreferences
        }
        let target = selected.interface
        let current = try Self.preferenceMTU(target)
        guard MTUTrialDecision.canRestore(currentPreference: current, expectedPreference: expectedPreference) else {
            throw MTUControlError.changedPreferences
        }
        try validateIdentity()
        let configurationBefore = SCNetworkInterfaceGetConfiguration(target) as? [String: Any]
        let desiredConfiguration = MTUPreferenceEditing.settingMTU(mtu, in: configurationBefore)
        guard SCNetworkInterfaceSetMTU(target, Int32(mtu ?? 0)) else {
            throw Self.configurationError()
        }
        // SetMTU validates the setting but does not promise how a zero/default
        // key is represented. Explicitly restore the freshly read dictionary,
        // changing only MTU; preserve MediaSubType, MediaOptions, and other keys.
        guard SCNetworkInterfaceSetConfiguration(target, desiredConfiguration as CFDictionary?) else {
            throw Self.configurationError()
        }
        let configurationAfter = SCNetworkInterfaceGetConfiguration(target) as? [String: Any]
        let savedMatches = configurationAfter.map(NSDictionary.init(dictionary:)) == desiredConfiguration.map(NSDictionary.init(dictionary:))
        guard savedMatches else { throw Self.configurationError() }
        guard try Self.preferenceMTU(target) == mtu else { throw Self.configurationError() }
        guard SCPreferencesCommitChanges(preferences) else { throw Self.configurationError() }
        expectedPreference = mtu
        // Set this before ApplyChanges, because an apply failure still leaves a
        // committed preference that the catch path must restore.
        trialWasCommitted = true
        if apply && !SCPreferencesApplyChanges(preferences) { throw Self.configurationError() }
    }

    private func verifySavedAndActive(expectedActive: Int) throws {
        try validateIdentity()
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Lekuo Control MTU" as CFString, nil, authorization) else {
            throw Self.configurationError()
        }
        guard SCPreferencesLock(preferences, false) else { throw Self.configurationError() }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        let selected = try Self.targetInterface(preferences, name: request.interface)
        guard selected.setID == networkLocationID, selected.serviceID == networkServiceID else {
            throw MTUControlError.changedPreferences
        }
        let target = selected.interface
        guard try Self.preferenceMTU(target) == expectedPreference else { throw MTUControlError.changedPreferences }
        guard try activeMTU(request.interface) == expectedActive else {
            throw MTUControlError.unavailable("macOS did not retain the temporary packet size. The previous setting is being restored.")
        }
    }

    private func waitForActiveMTU(_ mtu: Int) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        repeat {
            try validateIdentity()
            if try activeMTU(request.interface) == mtu { return }
            usleep(50_000)
        } while clock.now < deadline
        throw MTUControlError.unavailable("macOS did not apply the requested packet size.")
    }

    private static func targetInterface(_ preferences: SCPreferences, name: String) throws -> PreferenceTarget {
        guard let set = SCNetworkSetCopyCurrent(preferences),
              let setID = SCNetworkSetGetSetID(set) as String?,
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw MTUControlError.unavailable("The adapter has no service in the current network location.")
        }
        var matches: [PreferenceTarget] = []
        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service),
                  SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeEthernet,
                  SCNetworkInterfaceGetBSDName(interface) as String? == name,
                  let serviceID = SCNetworkServiceGetServiceID(service) as String? else { continue }
            matches.append(PreferenceTarget(interface: interface, setID: setID, serviceID: serviceID))
        }
        guard matches.count == 1, let target = matches.first else {
            throw MTUControlError.unavailable("The adapter must have exactly one Ethernet service in the current network location.")
        }
        // The interface setter writes every location containing this service.
        // Refuse a shared service, so only the current location can be changed.
        guard let sets = SCNetworkSetCopyAll(preferences) as? [SCNetworkSet] else {
            throw Self.configurationError()
        }
        var memberSets: [SCNetworkSet] = []
        for candidate in sets {
            guard let members = SCNetworkSetCopyServices(candidate) as? [SCNetworkService] else {
                throw Self.configurationError()
            }
            if members.contains(where: { SCNetworkServiceGetServiceID($0) as String? == target.serviceID }) {
                memberSets.append(candidate)
            }
        }
        guard memberSets.count == 1, SCNetworkSetGetSetID(memberSets[0]) as String? == target.setID else {
            throw MTUControlError.unavailable("This Ethernet service belongs to multiple network locations. Configure its packet size in System Settings to keep those locations intact.")
        }
        return target
    }

    private static func preferenceMTU(_ target: SCNetworkInterface) throws -> Int? {
        guard let configuration = SCNetworkInterfaceGetConfiguration(target) as? [String: Any],
              let value = configuration[kSCPropNetEthernetMTU as String] else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              (number.intValue == 0 || (1280...9000).contains(number.intValue)) else {
            throw MTUControlError.unavailable("The existing saved packet size could not be safely preserved.")
        }
        return number.intValue
    }

    private static func configurationError() -> MTUControlError {
        .unavailable("macOS could not update the network preferences (error \(SCError())).")
    }
}

private enum MTUWatchdogIO {
    static func readExact(_ count: Int, timeout: Duration) throws -> Data {
        let deadline = MTUTrialClock.deadline(afterSeconds: Int(timeout.components.seconds))
        var data = Data()
        while data.count < count {
            guard MTUTrialClock.nowTicks < deadline else { throw MTUControlError.expired }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; throw MTUControlError.invalidRequest }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let received = read(STDIN_FILENO, &buffer, buffer.count)
            guard received > 0 else { throw MTUControlError.invalidRequest }
            data.append(contentsOf: buffer.prefix(received))
        }
        return data
    }

    static func readLine(limit: Int, deadline: UInt64) throws -> Data? {
        var line = Data()
        while MTUTrialClock.nowTicks < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw MTUControlError.invalidRequest }
            if ready == 0 { continue }
            guard MTUTrialClock.nowTicks < deadline else { throw MTUControlError.expired }
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 0 { return nil }
            guard count == 1 else { throw MTUControlError.invalidRequest }
            if byte == 10 { return line }
            line.append(byte)
            guard line.count <= limit else { throw MTUControlError.invalidRequest }
        }
        throw MTUControlError.expired
    }

    static func emit(_ reply: MTUWatchdogReply) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

@main
private struct LekuoMTUWatchdog {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 1 else {
            MTUWatchdogIO.emit(.init(.error, message: MTUControlError.invalidRequest.localizedDescription))
            return
        }
        var authorization: AuthorizationRef?
        defer { if let authorization { AuthorizationFree(authorization, []) } }
        var lease: MTUWatchdogLease?
        defer { lease?.release() }
        var transaction: MTUPreferencesTransaction?
        do {
            // The helper never starts a password dialog. The app obtains this
            // authorization before launch and supplies the token only in memory.
            var externalForm = AuthorizationExternalForm()
            let data = try MTUWatchdogIO.readExact(MemoryLayout<AuthorizationExternalForm>.size, timeout: .seconds(10))
            _ = withUnsafeMutableBytes(of: &externalForm) { data.copyBytes(to: $0) }
            let importStatus = AuthorizationCreateFromExternalForm(&externalForm, &authorization)
            guard importStatus == errAuthorizationSuccess,
                  let authorization else { throw MTUControlError.authorization(importStatus) }
            let requestDeadline = MTUTrialClock.deadline(afterSeconds: 10)
            guard let requestData = try MTUWatchdogIO.readLine(limit: 1024, deadline: requestDeadline) else {
                throw MTUControlError.invalidRequest
            }
            let request = try MTUWatchdogRequest.decode(requestData)
            try verifyEmbeddedDriver(request.driverBundleIdentifier)
            lease = try MTUWatchdogLease(interface: request.interface)
            let current = try MTUPreferencesTransaction(request: request, authorization: authorization)
            transaction = current
            try current.applyTrial()
            let deadline = MTUTrialClock.deadline(afterSeconds: MTUTrialDecision.durationSeconds)
            MTUWatchdogIO.emit(.init(.applied, originalMTU: current.originalActiveMTU,
                                    requestedMTU: request.requestedMTU, deadlineContinuousTicks: deadline))
            guard let commandData = try MTUWatchdogIO.readLine(limit: 256, deadline: deadline) else {
                try current.rollback()
                MTUWatchdogIO.emit(.init(.reverted))
                return
            }
            let command = try MTUWatchdogCommand.decode(commandData)
            guard MTUTrialClock.nowTicks < deadline else { throw MTUControlError.expired }
            switch command.command {
            case .save:
                try current.save(deadlineTicks: deadline)
                MTUWatchdogIO.emit(.init(.kept))
            case .keep:
                try current.keep(verifiedMTU: command.verifiedMTU, deadlineTicks: deadline)
                MTUWatchdogIO.emit(.init(.kept))
            case .revert:
                try current.rollback()
                MTUWatchdogIO.emit(.init(.reverted))
            }
        } catch {
            var message = error.localizedDescription
            if let transaction {
                // Brief contention is recoverable; ownership/preference conflicts
                // are not retried by replacing another process's chosen value.
                var rollbackError: Error?
                for _ in 0..<20 {
                    do { try transaction.rollback(); rollbackError = nil; break }
                    catch { rollbackError = error; usleep(100_000) }
                }
                if let rollbackError {
                    message += " Automatic restore could not finish: \(rollbackError.localizedDescription)"
                }
            }
            MTUWatchdogIO.emit(.init(.error, message: message))
        }
    }

    private static func verifyEmbeddedDriver(_ identifier: String) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", executable.deletingLastPathComponent().lastPathComponent == "Helpers" else {
            throw MTUControlError.unavailable("The packet-size helper must run from the installed Lekuo Control app.")
        }
        let extensionDirectory = contents.appendingPathComponent("Library/SystemExtensions", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: extensionDirectory, includingPropertiesForKeys: nil)
        guard files.filter({ $0.pathExtension == "dext" }).contains(where: { Bundle(url: $0)?.bundleIdentifier == identifier }) else {
            throw MTUControlError.changedDevice
        }
    }
}
