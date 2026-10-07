import AppKit
import Combine
import Darwin
import Foundation
import SystemExtensions
import UniformTypeIdentifiers

enum StatusTone { case neutral, success, warning, error }

@MainActor
final class DriverLoadingViewModel: NSObject, ObservableObject {
    @Published private(set) var adapters: [AdapterSnapshot] = []
    @Published var selectedAdapterID: String? {
        didSet {
            guard selectedAdapterID != oldValue else { return }
            previousRateSample = nil
            receiveRateBitsPerSecond = nil
            transmitRateBitsPerSecond = nil
            verifiedProbe = nil
            probeSummary = nil
            if let adapter = selectedAdapter { selectedMTU = adapter.mtu; customMTUText = String(adapter.mtu) }
            recomputeKeepEligibility()
        }
    }
    @Published private(set) var driverStatusTitle = "Checking driver status"
    @Published private(set) var driverStatusDetail = "Reading the state reported by macOS."
    @Published private(set) var driverStatusTone: StatusTone = .neutral
    @Published private(set) var driverInstalledVersion: String?
    @Published private(set) var isDriverActive = false
    @Published private(set) var isDriverBusy = false
    @Published private(set) var needsApproval = false
    @Published private(set) var needsRestart = false
    @Published private(set) var lastError: String?
    @Published var selectedMTU = 1500
    @Published var customMTUText = "1500"
    @Published var peerAddress = "" {
        didSet {
            guard peerAddress != oldValue else { return }
            verifiedProbe = nil
            probeSummary = nil
            recomputeKeepEligibility()
        }
    }
    @Published private(set) var probeSummary: String?
    @Published private(set) var isProbing = false
    @Published private(set) var isApplying = false
    @Published private(set) var rollbackSecondsRemaining: Int?
    @Published private(set) var canKeepSettings = false
    @Published private(set) var diagnosticsText: String?
    @Published private(set) var receiveRateBitsPerSecond: Double?
    @Published private(set) var transmitRateBitsPerSecond: Double?

    var selectedAdapter: AdapterSnapshot? { adapters.first { $0.id == selectedAdapterID } }
    var canConfigureSelectedAdapter: Bool {
        guard driverIdentifier != nil, bundledDriver != nil, isDriverActive, !isDriverBusy, !needsApproval, !needsRestart,
              let adapter = selectedAdapter, adapter.isEnabled else { return false }
        return adapter.minimumMTU <= adapter.mtu && adapter.mtu <= adapter.maximumMTU
    }
    var bundledVersion: String {
        guard let bundledDriver else { return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
        return "\(bundledDriver.shortVersion) (\(bundledDriver.buildVersion))"
    }
    var buildKindLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "LekuoBuildKind") as? String ?? "Development Preview"
    }

    private struct DriverVersion { let shortVersion: String; let buildVersion: String }
    private enum RequestKind { case properties, activation, deactivation }
    private struct PendingRequest {
        let request: OSSystemExtensionRequest
        let kind: RequestKind
        let generation: Int
        let target: DriverVersion?
    }

    private let adapterService = AdapterService()
    private let mtuConfiguration = MTUConfiguration()
    private let driverIdentifier: String?
    private let bundledDriver: DriverVersion?
    private var installedDriver: DriverVersion?
    private var pendingRequests: [ObjectIdentifier: PendingRequest] = [:]
    private var requestGeneration = 0
    private var lastPropertiesRefresh: TimeInterval?
    private var propertyStatusKnown = false
    private var observedUninstalling = false
    private var pendingRestart: PendingDriverRestart?
    private static let restartDefaultsKey = "LekuoControl.PendingDriverRestart"
    private var monitoringTask: Task<Void, Never>?
    private var adapterRefreshTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var configurationOperationInProgress = false
    private var previousRateSample: TrafficRateSample?
    private var latestAdapterSampleUptime: TimeInterval?
    private var verifiedProbe: MTUProbeProof?
    private var subscriptions = Set<AnyCancellable>()
    private var handledLaunchRequest = false
    private var snapshotReadGeneration = 0
    private var publishedSnapshotGeneration = 0
    private var adapterRefreshGeneration = 0

    override init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "LekuoDriverBundleIdentifier") as? String
        driverIdentifier = identifier.flatMap { $0.isEmpty ? nil : $0 }
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let bundled = contents.compactMap { url -> Bundle? in
            guard url.pathExtension == "dext", let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier else { return nil }
            return bundle
        }.first
        if let short = bundled?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = bundled?.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            bundledDriver = DriverVersion(shortVersion: short, buildVersion: build)
        } else { bundledDriver = nil }
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.restartDefaultsKey),
           let value = try? JSONDecoder().decode(PendingDriverRestart.self, from: data), value.isValid {
            pendingRestart = value
            needsRestart = true
        }
        observeConfiguration()
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopMonitoring() }
            }
        AnyCancellable { NotificationCenter.default.removeObserver(observer) }.store(in: &subscriptions)
        if driverIdentifier == nil || bundledDriver == nil {
            lastError = "The bundled driver metadata is missing. Reinstall a complete signed build of Lekuo Control."
        }
        updateDriverPresentation()
    }

    func refresh() { refreshAdapters(); queryDriverProperties(force: true) }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        refresh()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.refreshAdapters()
                self.queryDriverProperties(force: false)
                self.recomputeKeepEligibility()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel(); monitoringTask = nil
        adapterRefreshGeneration += 1
        adapterRefreshTask?.cancel(); adapterRefreshTask = nil
        probeTask?.cancel(); probeTask = nil
        mutationTask?.cancel()
        // Closing input requests restoration. The child watchdog retains its
        // authorization and must remain running until restoration completes.
        mtuConfiguration.stop()
    }

    func handleLaunchRequest() {
        guard !handledLaunchRequest else { return }
        handledLaunchRequest = true
        let flags = Set(ProcessInfo.processInfo.arguments)
        let install = !flags.isDisjoint(with: ["--install-driver", "--activate-extension"])
        let uninstall = !flags.isDisjoint(with: ["--uninstall-driver", "--deactivate-extension"])
        guard !(install && uninstall) else {
            lastError = "Choose either installation or removal when launching the app, then try again."
            return
        }
        if install { installDriver() }
        else if uninstall { uninstallDriver() }
    }

    func installDriver() {
        guard !isDriverBusy, !needsRestart, !isApplying, !isProbing, rollbackSecondsRemaining == nil,
              let identifier = driverIdentifier, let candidate = bundledDriver else { return }
        if let existing = installedDriver,
           !NumericVersion.permitsReplacement(existingShort: existing.shortVersion, existingBuild: existing.buildVersion,
                                              candidateShort: candidate.shortVersion, candidateBuild: candidate.buildVersion) {
            lastError = "This app contains an older or incomparable driver version. Use an app with the same or a newer driver."
            return
        }
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .activation, target: candidate)
    }

    func uninstallDriver() {
        guard !isDriverBusy, !needsRestart, !isApplying, !isProbing, rollbackSecondsRemaining == nil,
              let identifier = driverIdentifier else { return }
        probeTask?.cancel()
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .deactivation,
               target: installedDriver ?? bundledDriver)
    }

    func openSystemSettings() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }

    func applyMTU() {
        guard canConfigureSelectedAdapter, !isApplying, !isProbing, rollbackSecondsRemaining == nil,
              let adapter = selectedAdapter, let identifier = driverIdentifier else { return }
        let mtu = selectedMTU
        guard (adapter.minimumMTU...adapter.maximumMTU).contains(mtu), mtu != adapter.mtu else {
            lastError = "Choose a different packet size within the adapter's supported range."
            return
        }
        let peer = peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if mtu > adapter.mtu && AdapterService.literalPeer(peer, interface: adapter.id) == nil {
            lastError = "Enter a literal IPv4 or IPv6 receiver address before testing a larger packet size."
            return
        }
        lastError = nil; verifiedProbe = nil; probeSummary = nil
        configurationOperationInProgress = true; updateApplyingState()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConfigurationOperation() }
            do {
                try await self.mtuConfiguration.applyTemporary(interface: adapter.id, mtu: mtu, driverBundleIdentifier: identifier)
                await self.readAdapters()
                guard !Task.isCancelled else { self.mtuConfiguration.stop(); return }
                if !peer.isEmpty { await self.runProbe(interface: adapter.id, mtu: mtu, peer: peer) }
            } catch { self.lastError = error.localizedDescription }
        }
    }

    func keepMTU() {
        guard canKeepSettings, !isApplying else { return }
        configurationOperationInProgress = true; updateApplyingState()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConfigurationOperation() }
            await self.readAdapters()
            guard !Task.isCancelled, self.keepProofIsCurrent() else {
                self.lastError = "The adapter, packet size, or receiver changed. Test the current connection again before keeping this setting."
                return
            }
            do { try await self.mtuConfiguration.keep() }
            catch { self.lastError = error.localizedDescription }
            await self.readAdapters()
        }
    }

    func revertMTU() {
        guard !isApplying, rollbackSecondsRemaining != nil else { return }
        probeTask?.cancel()
        configurationOperationInProgress = true; updateApplyingState()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConfigurationOperation() }
            do { try await self.mtuConfiguration.revert() }
            catch { self.lastError = error.localizedDescription }
            await self.readAdapters()
        }
    }

    func restoreDefaults() { selectedMTU = 1500; customMTUText = "1500"; applyMTU() }

    func testJumboPath() {
        guard canConfigureSelectedAdapter, !isProbing, !isApplying, probeTask == nil,
              let adapter = selectedAdapter else { return }
        let peer = peerAddress
        guard AdapterService.literalPeer(peer, interface: adapter.id) != nil else {
            probeSummary = "Enter a literal unicast IPv4 or IPv6 address for your receiver."
            return
        }
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.runProbe(interface: adapter.id, mtu: adapter.mtu, peer: peer)
            self.probeTask = nil
        }
    }

    func exportDiagnostics() {
        do {
            diagnosticsText = try DiagnosticReport(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                driverVersion: installedDriver?.shortVersion, driverBuild: installedDriver?.buildVersion,
                osVersion: ProcessInfo.processInfo.operatingSystemVersion,
                driverEnabled: isDriverActive, adapters: adapters).json()
        } catch { lastError = "The diagnostic preview could not be prepared." }
    }

    func saveDiagnostics() {
        guard let text = diagnosticsText else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Lekuo-Diagnostics.json"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) }
            catch { self?.lastError = "The diagnostic report could not be saved to the selected location." }
        }
    }

    // MARK: Read-only polling

    private func refreshAdapters() {
        guard adapterRefreshTask == nil else { return }
        adapterRefreshGeneration += 1
        let generation = adapterRefreshGeneration
        adapterRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.readAdapters()
            if generation == self.adapterRefreshGeneration { self.adapterRefreshTask = nil }
        }
    }

    private func readAdapters() async {
        guard let identifier = driverIdentifier else { return }
        snapshotReadGeneration += 1
        let generation = snapshotReadGeneration
        let service = adapterService
        let result = await Task.detached(priority: .utility) {
            let result = Result { try service.snapshots(driverBundleIdentifier: identifier) }
            return (result, ProcessInfo.processInfo.systemUptime)
        }.value
        guard !Task.isCancelled, generation >= publishedSnapshotGeneration else { return }
        publishedSnapshotGeneration = generation
        switch result.0 {
        case .success(let snapshots):
            let previous = selectedAdapter
            adapters = snapshots
            let uptime = result.1
            latestAdapterSampleUptime = uptime
            if !adapters.contains(where: { $0.id == selectedAdapterID }) { selectedAdapterID = adapters.first?.id }
            if let current = selectedAdapter {
                if previous?.id != current.id || previous?.mtu != current.mtu {
                    selectedMTU = current.mtu; customMTUText = String(current.mtu)
                    if let verifiedProbe, verifiedProbe.mtu != current.mtu {
                        self.verifiedProbe = nil
                        probeSummary = nil
                    }
                }
                let sample = TrafficRateSample(interfaceID: current.id, receivedBytes: current.receivedBytes,
                                               transmittedBytes: current.transmittedBytes, uptime: uptime)
                let rates = TrafficRateCalculator.rates(previous: previousRateSample, current: sample)
                receiveRateBitsPerSecond = rates.receiveBitsPerSecond
                transmitRateBitsPerSecond = rates.transmitBitsPerSecond
                previousRateSample = sample
            } else {
                previousRateSample = nil; receiveRateBitsPerSecond = nil; transmitRateBitsPerSecond = nil; verifiedProbe = nil
            }
        case .failure:
            adapters = []; selectedAdapterID = nil; latestAdapterSampleUptime = nil
            lastError = "Adapter ownership or statistics are unavailable. Refresh to try again."
        }
        recomputeKeepEligibility(); updateDriverPresentation()
    }

    private func queryDriverProperties(force: Bool) {
        guard let identifier = driverIdentifier, !hasMutationRequest,
              !pendingRequests.values.contains(where: { $0.kind == .properties }) else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force, let lastPropertiesRefresh, uptime - lastPropertiesRefresh < 15 { return }
        lastPropertiesRefresh = uptime
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequests[ObjectIdentifier(request)] = PendingRequest(request: request, kind: .properties,
                                                                  generation: requestGeneration, target: nil)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private var hasMutationRequest: Bool { pendingRequests.values.contains { $0.kind != .properties } }

    private func submit(_ request: OSSystemExtensionRequest, kind: RequestKind, target: DriverVersion?) {
        requestGeneration += 1
        lastError = nil; needsApproval = false
        request.delegate = self
        pendingRequests[ObjectIdentifier(request)] = PendingRequest(request: request, kind: kind,
                                                                  generation: requestGeneration, target: target)
        updateDriverPresentation()
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func updateDriverPresentation() {
        isDriverBusy = hasMutationRequest || observedUninstalling
        if let request = pendingRequests.values.first(where: { $0.kind != .properties }) {
            driverStatusTone = needsApproval ? .warning : .neutral
            driverStatusTitle = needsApproval ?
                (request.kind == .deactivation ? "Driver removal approval required" : "Driver approval required") :
                (request.kind == .activation ? "Installing driver" : "Removing driver")
            if needsApproval {
                driverStatusDetail = request.kind == .deactivation ?
                    "Follow macOS's prompt to approve removal. Open Driver Extensions to review the current driver state." :
                    "Open System Settings → General → Login Items & Extensions → Driver Extensions, enable the Lekuo driver, then click Done."
            } else { driverStatusDetail = "macOS is processing the request. Follow any authorization prompt." }
        } else if needsRestart {
            driverStatusTone = .warning; driverStatusTitle = "Restart required"
            driverStatusDetail = pendingRestart?.operation == .deactivation ?
                "macOS will finish removing the driver after a restart. Keep another connection available." :
                "macOS accepted the driver request and requires a restart before activation can finish."
        } else if observedUninstalling {
            driverStatusTone = .warning; driverStatusTitle = "Driver removal pending"
            driverStatusDetail = "macOS reports that this driver is being removed. Refresh after the operation finishes."
        } else if needsApproval {
            driverStatusTone = .warning; driverStatusTitle = "Driver approval required"
            driverStatusDetail = "Enable the Lekuo driver in System Settings → General → Login Items & Extensions → Driver Extensions."
        } else if isDriverActive {
            driverStatusTone = adapters.isEmpty ? .neutral : .success
            driverStatusTitle = adapters.isEmpty ? "Driver enabled" : "Driver ready"
            driverStatusDetail = adapters.isEmpty ?
                "macOS enabled the extension. No adapter currently has verified ownership by this driver." :
                "The Lekuo driver is managing \(adapters.count == 1 ? "one Ethernet adapter" : "\(adapters.count) Ethernet adapters"). Link status is shown below."
        } else if propertyStatusKnown {
            driverStatusTone = .neutral; driverStatusTitle = "Driver setup required"
            driverStatusDetail = "Install the bundled driver, then follow any macOS approval or restart prompt."
        } else if lastError != nil {
            driverStatusTone = .error; driverStatusTitle = "Driver status unavailable"
            driverStatusDetail = "Review the message below and refresh to retry."
        } else {
            driverStatusTone = .neutral; driverStatusTitle = "Checking driver status"
            driverStatusDetail = "Reading the state reported by macOS."
        }
    }

    // MARK: Trial and probe evidence

    private func observeConfiguration() {
        mtuConfiguration.$secondsRemaining.sink { [weak self] value in
            guard let self else { return }
            self.rollbackSecondsRemaining = value
            if value == nil { self.verifiedProbe = nil }
            Task { @MainActor [weak self] in self?.recomputeKeepEligibility() }
        }.store(in: &subscriptions)
        mtuConfiguration.$isApplying.sink { [weak self] applying in
            guard let self else { return }
            self.isApplying = applying || self.configurationOperationInProgress
            Task { @MainActor [weak self] in self?.recomputeKeepEligibility() }
        }.store(in: &subscriptions)
        mtuConfiguration.$lastError.sink { [weak self] error in
            if let error { self?.lastError = error }
        }.store(in: &subscriptions)
    }

    private func updateApplyingState() { isApplying = configurationOperationInProgress || mtuConfiguration.isApplying }
    private func finishConfigurationOperation() {
        configurationOperationInProgress = false; updateApplyingState(); mutationTask = nil; recomputeKeepEligibility()
    }

    private func runProbe(interface: String, mtu: Int, peer: String) async {
        guard !isProbing, selectedAdapterID == interface,
              let literal = AdapterService.literalPeer(peer, interface: interface) else { return }
        isProbing = true; verifiedProbe = nil; canKeepSettings = false
        defer { isProbing = false; recomputeKeepEligibility() }
        let result = await adapterService.probe(peer: peer, interface: interface, mtu: mtu)
        guard !Task.isCancelled else { return }
        probeSummary = result.summary
        await readAdapters()
        guard result.succeeded, selectedAdapterID == interface, selectedAdapter?.mtu == mtu,
              AdapterService.literalPeer(peerAddress, interface: interface) == literal else { return }
        verifiedProbe = MTUProbeProof(interface: interface, mtu: mtu, peer: literal, uptime: ProcessInfo.processInfo.systemUptime)
        mtuConfiguration.markProbeSucceeded(interface: interface, mtu: mtu)
    }

    private func keepProofIsCurrent() -> Bool {
        guard canConfigureSelectedAdapter, mtuConfiguration.canKeep,
              let trialInterface = mtuConfiguration.currentTrialInterface,
              let trialMTU = mtuConfiguration.currentTrialMTU else { return false }
        guard !mtuConfiguration.requiresProbeForKeep || mtuConfiguration.hasVerifiedProbe else { return false }
        return MTUKeepEvidence.isCurrent(trialInterface: trialInterface, trialMTU: trialMTU,
            selectedID: selectedAdapterID, selected: selectedAdapter, sampledAt: latestAdapterSampleUptime,
            now: ProcessInfo.processInfo.systemUptime, requiresProbe: mtuConfiguration.requiresProbeForKeep,
            proof: verifiedProbe, currentPeer: peerAddress)
    }
    private func recomputeKeepEligibility() {
        if let proof = verifiedProbe, ProcessInfo.processInfo.systemUptime - proof.uptime > 15,
           rollbackSecondsRemaining != nil, mtuConfiguration.requiresProbeForKeep {
            verifiedProbe = nil
            probeSummary = "The connection test has expired. Test the current receiver again before keeping a larger packet size."
        }
        canKeepSettings = !isApplying && !isProbing && keepProofIsCurrent()
    }

    // MARK: Pending restart survives app relaunch

    private static func bootMarker() -> String? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }
    private func recordRestart(_ request: PendingRequest) {
        guard let target = request.target,
              let short = NumericVersion.sanitized(target.shortVersion), let build = NumericVersion.sanitized(target.buildVersion) else { return }
        let record = PendingDriverRestart(operation: request.kind == .deactivation ? .deactivation : .activation,
                                          shortVersion: short, buildVersion: build, bootMarker: Self.bootMarker())
        pendingRestart = record
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: Self.restartDefaultsKey) }
    }
    private func reconcileRestart(properties: [OSSystemExtensionProperties]) {
        guard let record = pendingRestart else { return }
        let desired: Bool
        if record.operation == .deactivation { desired = properties.isEmpty }
        else {
            desired = properties.contains {
                $0.isEnabled && !$0.isUninstalling && !$0.isAwaitingUserApproval &&
                NumericVersion.compare($0.bundleShortVersion, record.shortVersion) == .orderedSame &&
                NumericVersion.compare($0.bundleVersion, record.buildVersion) == .orderedSame
            }
        }
        let currentBoot = Self.bootMarker()
        let bootChanged = record.bootMarker != nil && currentBoot != nil && record.bootMarker != currentBoot
        guard desired || bootChanged else { return }
        needsRestart = false; pendingRestart = nil
        UserDefaults.standard.removeObject(forKey: Self.restartDefaultsKey)
        if bootChanged && !desired { lastError = "The restart finished, but macOS has not reached the requested driver state. Review its status before trying again." }
    }
}

extension DriverLoadingViewModel: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        guard let pending = pendingRequests.removeValue(forKey: ObjectIdentifier(request)), pending.kind == .properties else { return }
        guard pending.generation == requestGeneration else { queryDriverProperties(force: true); return }
        let relevant = properties.filter { $0.bundleIdentifier == driverIdentifier }
        let selected = relevant.first { $0.isEnabled } ?? relevant.first { $0.isAwaitingUserApproval } ?? relevant.first
        propertyStatusKnown = true
        observedUninstalling = selected?.isUninstalling ?? false
        isDriverActive = selected?.isEnabled == true && !observedUninstalling
        needsApproval = selected?.isAwaitingUserApproval ?? false
        if let selected {
            installedDriver = DriverVersion(shortVersion: selected.bundleShortVersion, buildVersion: selected.bundleVersion)
            driverInstalledVersion = "\(selected.bundleShortVersion) (\(selected.bundleVersion))"
        } else { installedDriver = nil; driverInstalledVersion = nil }
        reconcileRestart(properties: relevant)
        updateDriverPresentation(); recomputeKeepEligibility()
    }
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard let pending = pendingRequests[ObjectIdentifier(request)], pending.kind == .activation,
              existing.bundleIdentifier == driverIdentifier, replacement.bundleIdentifier == driverIdentifier,
              NumericVersion.permitsReplacement(existingShort: existing.bundleShortVersion, existingBuild: existing.bundleVersion,
                                                candidateShort: replacement.bundleShortVersion, candidateBuild: replacement.bundleVersion) else {
            lastError = "macOS offered an older or incomparable driver version. Replacement was cancelled."
            return .cancel
        }
        return .replace
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard let pending = pendingRequests[ObjectIdentifier(request)], pending.kind != .properties else { return }
        needsApproval = true; updateDriverPresentation()
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard let pending = pendingRequests.removeValue(forKey: ObjectIdentifier(request)) else { return }
        if pending.kind != .properties {
            needsApproval = false; needsRestart = result == .willCompleteAfterReboot
            if needsRestart { recordRestart(pending) }
            // Request completion is acceptance. Properties prove enabled state;
            // independently observed registry ancestry proves adapter ownership.
            queryDriverProperties(force: true); refreshAdapters()
        }
        updateDriverPresentation(); recomputeKeepEligibility()
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: ObjectIdentifier(request)) else { return }
        guard pending.generation == requestGeneration else { queryDriverProperties(force: true); return }
        if pending.kind == .properties {
            let failure = error as NSError
            if failure.domain == OSSystemExtensionErrorDomain && failure.code == 4 {
                propertyStatusKnown = true; installedDriver = nil; driverInstalledVersion = nil
                isDriverActive = false; observedUninstalling = false
                reconcileRestart(properties: [])
            } else {
                propertyStatusKnown = false; isDriverActive = false; observedUninstalling = false
                lastError = "macOS driver status could not be read. Refresh to try again."
            }
        } else {
            needsApproval = false; lastError = Self.driverRequestMessage(error)
            queryDriverProperties(force: true)
        }
        updateDriverPresentation(); recomputeKeepEligibility()
    }
    private static func driverRequestMessage(_ error: Error) -> String {
        let failure = error as NSError
        guard failure.domain == OSSystemExtensionErrorDomain else {
            return "macOS could not complete the driver request. Refresh its status before trying again."
        }
        switch failure.code {
        case 2: return "The driver is missing required Apple entitlements. Use a build signed for DriverKit networking and PCI."
        case 3: return "Move Lekuo Control into Applications, then open it there before installing the driver."
        case 4, 5, 6: return "The bundled driver is missing or its identity is invalid. Reinstall a complete signed build."
        case 8, 9: return "macOS could not validate this driver's signature or provisioning. Use the signed build for this Mac."
        case 10: return "macOS policy prevented this driver from loading. Review Driver Extensions in System Settings."
        case 11, 12: return "The driver request was cancelled or replaced by another request. Refresh to see the current state."
        case 13: return "macOS requires authorization to finish this driver request. Try again and follow the authorization prompt."
        default: return "macOS could not complete the driver request. Refresh its status before trying again."
        }
    }
}
