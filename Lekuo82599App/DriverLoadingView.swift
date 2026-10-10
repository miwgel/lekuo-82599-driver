/*
See the LICENSE.txt file for licensing information.

Lekuo Control presents observed driver and adapter status. All requests and
network changes are delegated to the view model.
*/

import AppKit
import SwiftUI

struct DriverLoadingView: View {
    @StateObject var viewModel = DriverLoadingViewModel()
    @State private var page: ControlPage = .adapter
    @State private var packetMode: PacketMode = .standard
    @State private var hasHandledLaunchRequest = false
    @State private var showUninstallConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 18) {
                driverStatus
                Picker("Section", selection: $page) {
                    ForEach(ControlPage.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Lekuo Control section")

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = viewModel.lastError, !error.isEmpty {
                            message(error, symbol: "exclamationmark.circle", color: .red)
                        }
                        switch page {
                        case .adapter:
                            adapterPage
                        case .settings:
                            settingsPage
                        case .diagnostics:
                            diagnosticsPage
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
            }
            .padding(24)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 640)
        .onAppear {
            viewModel.startMonitoring()
            syncPacketMode()
            guard !hasHandledLaunchRequest else { return }
            hasHandledLaunchRequest = true
            viewModel.handleLaunchRequest()
        }
        .onDisappear { viewModel.stopMonitoring() }
        .onChange(of: viewModel.selectedAdapterID) { _, _ in syncPacketMode() }
        .onChange(of: viewModel.selectedMTU) { _, _ in
            // Preset choices follow observed rollback/restore changes. Keep a
            // deliberately selected custom editor while its bound text updates.
            if packetMode != .custom { syncPacketMode() }
        }
        .alert("Uninstall the Lekuo driver?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall Driver", role: .destructive) { viewModel.uninstallDriver() }
        } message: {
            Text("The selected Ethernet connection may disconnect. Keep another connection available. macOS may require approval or a restart to finish removal.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lekuo Control").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("10 GbE for macOS").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(viewModel.buildKindLabel)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            Button { viewModel.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh driver and adapter status")
            .accessibilityLabel("Refresh status")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var driverStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(viewModel.driverStatusTitle).font(.headline)
                        if viewModel.isDriverBusy {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Driver request in progress")
                        }
                    }
                    Text(viewModel.driverStatusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let version = viewModel.driverInstalledVersion {
                        Text("Installed driver \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if !viewModel.isDriverActive {
                    Button("Install Driver") { viewModel.installDriver() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isDriverBusy || viewModel.needsRestart || settingsLocked || viewModel.isProbing)
                } else if viewModel.driverInstalledVersion != viewModel.bundledVersion {
                    Button("Update Driver") { viewModel.installDriver() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isDriverBusy || viewModel.needsRestart || settingsLocked || viewModel.isProbing)
                }
                Menu {
                    Button("Reinstall Driver") { viewModel.installDriver() }
                    Divider()
                    Button("Uninstall Driver…", role: .destructive) {
                        showUninstallConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(viewModel.isDriverBusy || viewModel.needsRestart || settingsLocked || viewModel.isProbing)
                .help("Driver actions")
                .accessibilityLabel("Driver actions")
            }
            if viewModel.needsApproval {
                Divider()
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Approve the driver in System Settings").font(.subheadline.weight(.medium))
                        Text("Open General → Login Items & Extensions → Driver Extensions, enable the Lekuo driver, then click Done.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open System Settings") { viewModel.openSystemSettings() }
                }
            }
            if viewModel.needsRestart {
                Divider()
                Label("Restart when convenient to finish the driver change. Keep an alternate connection available.", systemImage: "arrow.trianglehead.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }

    @ViewBuilder
    private var adapterPage: some View {
        if let adapter = viewModel.selectedAdapter {
            ControlCard("Adapter", symbol: "cable.connector") {
                adapterSelector
                HStack(spacing: 12) {
                    metric("Ethernet link", value: linkDescription(adapter), symbol: "point.3.connected.trianglepath.dotted")
                    metric("Packet size", value: "\(adapter.mtu) bytes", symbol: "shippingbox")
                    metric("Interface", value: adapter.isEnabled ? "Enabled" : "Disabled", symbol: "power")
                }
                Text("\(adapter.id) · \(adapter.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Configure Packet Size") { page = .settings }
                    .disabled(!viewModel.canConfigureSelectedAdapter)
            }
            ControlCard("Live traffic", subtitle: "Current interface traffic, refreshed automatically.", symbol: "arrow.up.arrow.down") {
                HStack(spacing: 12) {
                    metric("Receive", value: trafficRate(viewModel.receiveRateBitsPerSecond), symbol: "arrow.down")
                    metric("Transmit", value: trafficRate(viewModel.transmitRateBitsPerSecond), symbol: "arrow.up")
                }
                HStack {
                    Text("Received \(byteCount(adapter.receivedBytes))")
                    Spacer()
                    Text("Transmitted \(byteCount(adapter.transmittedBytes))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ControlCard("Interface counters", subtitle: "Totals reported by macOS for the selected interface.", symbol: "chart.bar.xaxis") {
                HStack(spacing: 12) {
                    metric("Receive errors", value: adapter.inputErrors.formatted(), symbol: "exclamationmark.circle")
                    metric("Transmit errors", value: adapter.outputErrors.formatted(), symbol: "exclamationmark.circle")
                    metric("Receive drops", value: adapter.inputDrops.formatted(), symbol: "tray.and.arrow.down")
                }
            }
        } else {
            noAdapter
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedAdapter == nil {
                noAdapter
            } else {
                ControlCard("Packet size", subtitle: "Configure the selected Ethernet interface on this Mac.", symbol: "shippingbox") {
                    adapterSelector
                    if let adapter = viewModel.selectedAdapter {
                        Text("Current MTU: \(adapter.mtu) bytes")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    // Only a user selection invokes apply. Synchronizing the
                    // picker from observed MTU changes never writes settings.
                    Picker("Packet size", selection: Binding(get: { packetMode }, set: { mode in
                        packetMode = mode
                        switch mode {
                        case .standard: viewModel.selectPresetMTU(1500)
                        case .jumbo: viewModel.selectPresetMTU(9000)
                        case .custom:
                            viewModel.customMTUText = String(viewModel.selectedAdapter?.mtu ?? 1500)
                            updateCustomMTU()
                        }
                    })) {
                        Text("Standard · 1500").tag(PacketMode.standard)
                        Text("Jumbo · 9000").tag(PacketMode.jumbo)
                        Text("Custom").tag(PacketMode.custom)
                    }
                    .pickerStyle(.segmented)
                    .disabled(settingsLocked || viewModel.isProbing || !viewModel.canConfigureSelectedAdapter)
                    if packetMode == .custom {
                        HStack {
                            TextField("MTU in bytes", text: $viewModel.customMTUText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .accessibilityLabel("Custom packet size in bytes")
                                .onChange(of: viewModel.customMTUText) { _, _ in updateCustomMTU() }
                                .disabled(settingsLocked)
                            Text("\(minimumMTU)–\(maximumMTU) bytes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(packetMode == .standard
                         ? "Standard packets work with typical Ethernet networks."
                         : "Jumbo packets reduce packet processing during large transfers. Your receiver and the network path must support the same packet size.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label("Selecting Standard or Jumbo applies and saves that packet size. macOS may request administrator authorization.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if packetMode == .custom {
                            Button("Apply Packet Size") { viewModel.applyMTU() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canApplyMTU)
                        }
                        if viewModel.isApplying {
                            ProgressView().controlSize(.small)
                            Text("Saving packet size…").font(.subheadline)
                        }
                        Spacer()
                        Button("Restore Standard MTU") {
                            packetMode = .standard
                            viewModel.restoreDefaults()
                        }
                        .disabled(!viewModel.canConfigureSelectedAdapter || settingsLocked || viewModel.isProbing || viewModel.selectedAdapter?.mtu == 1500)
                    }
                    if let saved = viewModel.mtuSaveMessage, !viewModel.isApplying {
                        Label(saved, systemImage: "checkmark.circle").font(.subheadline)
                    }
                    Text("You can optionally test the network path in Diagnostics. A receiver address is not required to change this adapter’s packet size.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !viewModel.canConfigureSelectedAdapter {
                        message("Configuration is available when the selected adapter is managed by the Lekuo driver.", symbol: "info.circle", color: .secondary)
                    } else if !mtuIsValid {
                        message("Choose a packet size between \(minimumMTU) and \(maximumMTU) bytes.", symbol: "exclamationmark.circle", color: .orange)
                    }
                }
            }
        }
    }

    private var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedAdapter != nil { jumboTestCard }
            ControlCard("Diagnostic report", subtitle: "Review adapter and driver information before saving a report.", symbol: "doc.text.magnifyingglass") {
                Text("The report removes network addresses, hardware identifiers, and personal paths by default. Preview its contents before sharing.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Preview Diagnostics") { viewModel.exportDiagnostics() }
                if let report = viewModel.diagnosticsText, !report.isEmpty {
                    HStack {
                        Text("Report preview").font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Save Report…") { viewModel.saveDiagnostics() }
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
                    .accessibilityLabel("Diagnostic report preview")
                }
            }
        }
    }

    private var jumboTestCard: some View {
        ControlCard("Test packet compatibility", subtitle: "Optional: test a local receiver at the adapter’s current packet size.", symbol: "checkmark.shield") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local peer IP address").font(.subheadline.weight(.medium))
                    TextField("Local receiver IP address", text: $viewModel.peerAddress)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Local peer IP address")
                        .disabled(viewModel.isProbing || viewModel.isApplying)
                }
                Button(viewModel.isProbing ? "Testing…" : "Test Connection") { viewModel.testJumboPath() }
                    .disabled(!canTest)
                    .padding(.top, 19)
                if viewModel.isProbing { ProgressView().controlSize(.small).padding(.top, 19) }
            }
            Text("The test sends a few packets through the selected interface. It checks the network path at the current MTU; it does not measure file transfer speed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = viewModel.probeSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Connection test result: \(summary)")
            }
        }
    }

    private var adapterSelector: some View {
        Picker("Adapter", selection: $viewModel.selectedAdapterID) {
            ForEach(viewModel.adapters, id: \.id) { adapter in
                Text("\(adapter.displayName) (\(adapter.id))").tag(Optional(adapter.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(settingsLocked || viewModel.isProbing)
        .accessibilityLabel("Selected Ethernet adapter")
    }

    private var noAdapter: some View {
        ControlCard(viewModel.isDriverActive ? "Connect your Lekuo adapter" : "Finish driver setup", symbol: "cable.connector") {
            Text(viewModel.isDriverActive
                 ? "No managed adapter is currently visible. Connect the enclosure directly to a compatible Thunderbolt or USB4 port, then refresh its status."
                 : "Install the driver and approve it in System Settings when requested. Finish any pending restart. Your adapter appears here when the driver connects to the enclosure.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh Status") { viewModel.refresh() }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(viewModel.adapters.count) \(viewModel.adapters.count == 1 ? "adapter" : "adapters") detected")
                Spacer()
                Text("App version \(viewModel.bundledVersion)")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch viewModel.driverStatusTone {
        case .neutral: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private var statusSymbol: String {
        switch viewModel.driverStatusTone {
        case .neutral: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var minimumMTU: Int { viewModel.selectedAdapter?.minimumMTU ?? 1280 }
    private var maximumMTU: Int { viewModel.selectedAdapter?.maximumMTU ?? 9000 }
    private var settingsLocked: Bool { viewModel.isApplying || viewModel.rollbackSecondsRemaining != nil }
    private var mtuIsValid: Bool {
        let mtu = packetMode == .custom ? Int(viewModel.customMTUText) : viewModel.selectedMTU
        guard let mtu else { return false }
        return (minimumMTU...maximumMTU).contains(mtu)
    }
    private var canApplyMTU: Bool {
        viewModel.canConfigureSelectedAdapter && mtuIsValid && !settingsLocked && !viewModel.isProbing
            && viewModel.selectedMTU != viewModel.selectedAdapter?.mtu
    }
    private var canTest: Bool {
        viewModel.canConfigureSelectedAdapter && !viewModel.isProbing && !viewModel.isApplying
            && !viewModel.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncPacketMode() {
        switch viewModel.selectedMTU {
        case 1500: packetMode = .standard
        case 9000: packetMode = .jumbo
        default:
            viewModel.customMTUText = String(viewModel.selectedMTU)
            packetMode = .custom
        }
    }

    private func updateCustomMTU() {
        guard let mtu = Int(viewModel.customMTUText) else { return }
        viewModel.selectedMTU = mtu
    }

    private func linkDescription(_ adapter: AdapterSnapshot) -> String {
        switch adapter.linkState {
        case .active:
            if let speed = adapter.linkSpeedBitsPerSecond {
                if speed >= 1_000_000_000, speed % 1_000_000_000 == 0 {
                    return "\(speed / 1_000_000_000) Gb/s"
                }
                return trafficRate(Double(speed))
            }
            return "Connected"
        case .inactive: return "Disconnected"
        case .unknown: return "Unknown"
        }
    }

    private func trafficRate(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond.isFinite, bitsPerSecond >= 0 else { return "—" }
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.2f Gb/s", bitsPerSecond / 1_000_000_000)
        }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
        }
        if bitsPerSecond >= 1_000 { return String(format: "%.0f Kb/s", bitsPerSecond / 1_000) }
        return String(format: "%.0f b/s", bitsPerSecond)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private enum ControlPage: String, CaseIterable, Identifiable {
    case adapter, settings, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adapter: "Adapter"
        case .settings: "Settings"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .adapter: "network"
        case .settings: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        }
    }
}

private enum PacketMode: String { case standard, jumbo, custom }

private struct ControlCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }
}
