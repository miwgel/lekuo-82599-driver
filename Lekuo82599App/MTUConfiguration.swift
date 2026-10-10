import Combine
import Darwin
import Foundation
import Security

/// Authorizes a single local adapter test. The child watchdog owns rollback and
/// retains only an in-memory authorization token, independently of app lifetime.
@MainActor
final class MTUConfiguration: ObservableObject {
    @Published private(set) var secondsRemaining: Int?
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentTrialInterface: String?
    @Published private(set) var currentTrialMTU: Int?
    @Published private(set) var hasVerifiedProbe = false

    var requiresProbeForKeep: Bool {
        decision.map { $0.requestedMTU > $0.originalMTU } ?? false
    }

    var canKeep: Bool {
        guard !isApplying, let decision, let secondsRemaining, secondsRemaining > 0 else { return false }
        guard let trialDeadlineTicks, MTUTrialClock.nowTicks < trialDeadlineTicks else { return false }
        return decision.requestedMTU <= decision.originalMTU || hasVerifiedProbe
    }

    private var decision: MTUTrialDecision?
    private var trialDeadlineTicks: UInt64?
    private let adapterService = AdapterService()
    private var driverBundleIdentifier: String?
    private var connection: MTUWatchdogConnection?
    private var monitorTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var expectedFinishEvent: MTUWatchdogReply.Event?

    /// Save an explicitly selected local MTU. The helper can still restore the
    /// original settings if authorization, application, or acknowledgement fails.
    func applyAndSave(interface: String, mtu: Int, driverBundleIdentifier: String) async throws {
        try await applyTemporary(interface: interface, mtu: mtu, driverBundleIdentifier: driverBundleIdentifier)
        do {
            guard !Task.isCancelled, let connection, let trialDeadlineTicks,
                  MTUTrialClock.nowTicks < trialDeadlineTicks else { throw MTUControlError.expired }
            guard try validateSnapshot(interface: interface, driver: driverBundleIdentifier) == mtu else {
                throw MTUControlError.changedDevice
            }
            isApplying = true
            try await waitForFinish(expected: .kept) {
                try connection.send(.init(command: .save, verifiedMTU: nil))
            }
        } catch {
            connection?.requestRollbackByClosingInput()
            isApplying = false
            lastError = error.localizedDescription
            throw error
        }
    }

    func applyTemporary(interface: String, mtu: Int, driverBundleIdentifier: String) async throws {
        guard !isApplying, connection == nil else { throw MTUControlError.busy }
        let request = MTUWatchdogRequest(interface: interface, requestedMTU: mtu, driverBundleIdentifier: driverBundleIdentifier)
        try request.validate()
        let originalMTU = try validateSnapshot(interface: interface, driver: driverBundleIdentifier)
        guard originalMTU != mtu else {
            throw MTUControlError.unavailable("The adapter already uses that packet size.")
        }
        isApplying = true
        lastError = nil
        defer { isApplying = false }
        var created: MTUWatchdogConnection?
        do {
            let client = try MTUWatchdogConnection.start(request)
            created = client
            let reply = try await client.readReply()
            guard reply.event == .applied, reply.requestedMTU == mtu,
                  let helperOriginalMTU = reply.originalMTU, (1280...9000).contains(helperOriginalMTU),
                  let deadline = reply.deadlineContinuousTicks, MTUTrialClock.nowTicks < deadline else {
                throw MTUControlError.unavailable(reply.message ?? "The temporary packet-size test could not start.")
            }
            // It may take seconds to authorize. Recheck using AdapterService
            // after helper apply, while the helper independently checks registry
            // identity before each actual preference mutation.
            guard try validateSnapshot(interface: interface, driver: driverBundleIdentifier) == mtu else {
                throw MTUControlError.changedDevice
            }
            connection = client
            self.driverBundleIdentifier = driverBundleIdentifier
            currentTrialInterface = interface
            currentTrialMTU = mtu
            decision = MTUTrialDecision(originalMTU: helperOriginalMTU, requestedMTU: mtu)
            trialDeadlineTicks = deadline
            hasVerifiedProbe = false
            secondsRemaining = MTUTrialClock.remainingSeconds(until: deadline)
            beginCountdown(deadline: deadline)
            monitorTask = Task { [weak self, client] in
                do {
                    let result = try await client.readReply()
                    self?.finish(result)
                } catch {
                    self?.finish(.init(.error, message: error.localizedDescription))
                }
            }
        } catch {
            // Closing stdin always instructs the independently running child to
            // revert. Do not terminate it while it owns an unconfirmed test.
            created?.requestRollbackByClosingInput()
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Call only after a fresh peer path probe succeeded on this exact interface
    /// and MTU. Enlarging MTU cannot be kept merely by clicking a confirmation.
    func markProbeSucceeded(interface: String, mtu: Int) {
        guard interface == currentTrialInterface, mtu == currentTrialMTU,
              let trialDeadlineTicks, MTUTrialClock.nowTicks < trialDeadlineTicks,
              let driverBundleIdentifier,
              (try? validateSnapshot(interface: interface, driver: driverBundleIdentifier)) == mtu,
              var value = decision else { return }
        guard (try? value.recordProbe(mtu: mtu, nowTicks: MTUTrialClock.nowTicks, deadlineTicks: trialDeadlineTicks)) != nil else { return }
        decision = value
        hasVerifiedProbe = true
    }

    func keep() async throws {
        guard !isApplying, let connection, let decision, let interface = currentTrialInterface,
              let driverBundleIdentifier, let trialDeadlineTicks,
              MTUTrialClock.nowTicks < trialDeadlineTicks else { throw MTUControlError.expired }
        do {
            guard try validateSnapshot(interface: interface, driver: driverBundleIdentifier) == decision.requestedMTU else {
                throw MTUControlError.changedDevice
            }
            try decision.authorizeKeep(claimedVerifiedMTU: hasVerifiedProbe ? decision.requestedMTU : nil,
                                       nowTicks: MTUTrialClock.nowTicks, deadlineTicks: trialDeadlineTicks)
            isApplying = true
            try await waitForFinish(expected: .kept) {
                try connection.send(.init(command: .keep, verifiedMTU: hasVerifiedProbe ? decision.requestedMTU : nil))
            }
        } catch {
            isApplying = false
            lastError = error.localizedDescription
            throw error
        }
    }

    func revert() async throws {
        guard !isApplying, let connection else { return }
        // Parent-side validation before requesting a mutation; the child remains
        // responsible for rollback even if this read fails after disconnection.
        if let interface = currentTrialInterface, let driverBundleIdentifier {
            _ = try? validateSnapshot(interface: interface, driver: driverBundleIdentifier)
        }
        isApplying = true
        do {
            try await waitForFinish(expected: .reverted) { try connection.send(.init(command: .revert, verifiedMTU: nil)) }
        } catch {
            isApplying = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// App termination should close this pipe; the child restores before exiting.
    func stop() {
        connection?.requestRollbackByClosingInput()
    }

    private func validateSnapshot(interface: String, driver: String) throws -> Int {
        let snapshots = try adapterService.snapshots(driverBundleIdentifier: driver)
        let matches = snapshots.filter { $0.id == interface }
        guard matches.count == 1, let snapshot = matches.first, snapshot.isEnabled else {
            throw MTUControlError.changedDevice
        }
        return snapshot.mtu
    }

    private func beginCountdown(deadline: UInt64) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                let rounded = MTUTrialClock.remainingSeconds(until: deadline)
                self?.secondsRemaining = rounded
                if rounded == 0 { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func waitForFinish(expected: MTUWatchdogReply.Event, _ send: () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            expectedFinishEvent = expected
            do { try send() }
            catch {
                finishContinuation = nil
                expectedFinishEvent = nil
                connection?.requestRollbackByClosingInput()
                continuation.resume(throwing: error)
            }
        }
    }

    private func finish(_ reply: MTUWatchdogReply) {
        countdownTask?.cancel()
        countdownTask = nil
        connection?.requestRollbackByClosingInput()
        connection = nil
        currentTrialInterface = nil
        currentTrialMTU = nil
        driverBundleIdentifier = nil
        decision = nil
        trialDeadlineTicks = nil
        monitorTask = nil
        secondsRemaining = nil
        hasVerifiedProbe = false
        isApplying = false
        let continuation = finishContinuation
        finishContinuation = nil
        let expected = expectedFinishEvent
        expectedFinishEvent = nil
        if reply.event == .error {
            let error = MTUControlError.unavailable(reply.message ?? "The packet-size helper stopped unexpectedly. Check the adapter's current settings.")
            lastError = error.localizedDescription
            continuation?.resume(throwing: error)
        } else if reply.event == .kept || reply.event == .reverted {
            if let expected, expected != reply.event {
                let error = MTUControlError.unavailable("The packet size was not saved. Check the adapter's current setting and try again.")
                lastError = error.localizedDescription
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        } else {
            let error = MTUControlError.invalidRequest
            lastError = error.localizedDescription
            continuation?.resume(throwing: error)
        }
    }
}

private final class MTUWatchdogConnection: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    private var inputClosed = false

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func start(_ request: MTUWatchdogRequest) throws -> MTUWatchdogConnection {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LekuoMTUWatchdog")
        try verifySignature(helper)
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw MTUControlError.authorization(createStatus)
        }
        defer { AuthorizationFree(authorization, []) }
        let rightsStatus = "system.preferences.network".withCString { rightName in
            var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard rightsStatus == errAuthorizationSuccess else { throw MTUControlError.authorization(rightsStatus) }
        var externalForm = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authorization, &externalForm)
        guard externalStatus == errAuthorizationSuccess else { throw MTUControlError.authorization(externalStatus) }
        let stdin = Pipe()
        let stdout = Pipe()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw MTUControlError.unavailable("Could not prepare the packet-size helper connection.")
        }
        let child = Process()
        child.executableURL = helper
        child.arguments = []
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        // Reap independently of the UI's stream reader; never wait on MainActor.
        DispatchQueue.global(qos: .utility).async { child.waitUntilExit() }
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        let connection = MTUWatchdogConnection(process: child, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        do {
            var data = withUnsafeBytes(of: externalForm) { Data($0) }
            data.append(try JSONEncoder().encode(request))
            data.append(10)
            try connection.input.write(contentsOf: data)
            // Token bytes are never persisted, returned to UI, or logged.
            data.resetBytes(in: 0..<data.count)
            return connection
        } catch {
            connection.requestRollbackByClosingInput()
            throw error
        }
    }

    func send(_ command: MTUWatchdogCommand) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { throw MTUControlError.expired }
        var data = try JSONEncoder().encode(command)
        data.append(10)
        try input.write(contentsOf: data)
    }

    func requestRollbackByClosingInput() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        try? input.close()
    }

    func readReply() async throws -> MTUWatchdogReply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    var data = Data()
                    while data.count <= 4096 {
                        guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                            throw MTUControlError.unavailable("The packet-size helper closed unexpectedly. Check the current MTU before retrying.")
                        }
                        if byte.first == 10 {
                            continuation.resume(returning: try JSONDecoder().decode(MTUWatchdogReply.self, from: data))
                            return
                        }
                        data.append(byte)
                    }
                    throw MTUControlError.invalidRequest
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func verifySignature(_ url: URL) throws {
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess,
              let selfStaticCode,
              SecStaticCodeCheckValidity(selfStaticCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess,
              SecCodeCopySigningInformation(selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let appIdentifier = Bundle.main.bundleIdentifier,
              appIdentifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw MTUControlError.unavailable("Packet-size changes require a signed build of Lekuo Control.")
        }
        var helperCode: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(appIdentifier).MTUWatchdog\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(helperCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw MTUControlError.unavailable("The signed packet-size helper is missing or could not be verified. Reinstall Lekuo Control.")
        }
    }

    deinit {
        requestRollbackByClosingInput()
        try? output.close()
    }
}
