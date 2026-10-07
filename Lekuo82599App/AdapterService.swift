import Foundation
import Darwin
import IOKit

enum AdapterLinkState: String, Sendable {
    case active, inactive, unknown
}

struct AdapterSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let mtu: Int
    let minimumMTU: Int
    let maximumMTU: Int
    let isEnabled: Bool
    let linkState: AdapterLinkState
    let linkSpeedBitsPerSecond: UInt64?
    let receivedBytes: UInt64
    let transmittedBytes: UInt64
    let inputErrors: UInt64
    let outputErrors: UInt64
    let inputDrops: UInt64
}

struct JumboProbeResult: Equatable, Sendable {
    let succeeded: Bool
    let summary: String
}

enum AdapterServiceError: LocalizedError {
    case registryUnavailable
    case interfaceStatisticsUnavailable
    case malformedInterfaceStatistics

    var errorDescription: String? {
        switch self {
        case .registryUnavailable:
            return "macOS adapter ownership information is unavailable."
        case .interfaceStatisticsUnavailable, .malformedInterfaceStatistics:
            return "macOS adapter statistics are unavailable. Refresh to try again."
        }
    }
}

/// Read-only interface discovery and an explicitly requested, bounded peer test.
/// No shell is involved, and no addresses or identifiers are logged or persisted.
final class AdapterService: @unchecked Sendable {
    // The only mutable state is protected by this lock. Probes revalidate the
    // registry, using the bundle ID established by this instance's discovery.
    private let ownershipLock = NSLock()
    private var discoveredDriverBundleIdentifier: String?

    private final class ProbeCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    struct RegistryNode: Equatable {
        let className: String
        let properties: [String: String]
    }

    struct InterfaceMetrics: Equatable {
        let mtu: Int
        let isEnabled: Bool
        let receivedBytes: UInt64
        let transmittedBytes: UInt64
        let inputErrors: UInt64
        let outputErrors: UInt64
        let inputDrops: UInt64
    }

    enum IPFamily: Equatable, Sendable { case ipv4, ipv6 }

    struct LiteralPeer: Equatable, Sendable {
        let address: String
        let family: IPFamily
        let isLinkLocal: Bool
    }

    func snapshots(driverBundleIdentifier: String) throws -> [AdapterSnapshot] {
        guard !driverBundleIdentifier.isEmpty else { return [] }
        let interfaces = try Self.ownedInterfaces(driverBundleIdentifier: driverBundleIdentifier)
        ownershipLock.withLock { discoveredDriverBundleIdentifier = driverBundleIdentifier }
        // No ownership evidence means no selectable adapter, rather than a guess.
        guard !interfaces.isEmpty else { return [] }
        let metrics = try Self.interfaceMetrics()
        return interfaces.compactMap { name in
            guard let values = metrics[if_nametoindex(name)] else { return nil }
            let media = Self.mediaStatus(interface: name)
            return AdapterSnapshot(
                id: name, displayName: "Lekuo Ethernet (\(name))", mtu: values.mtu,
                // This is the supported range in this bundled Lekuo driver.
                minimumMTU: 1280, maximumMTU: 9000,
                isEnabled: values.isEnabled, linkState: media.state,
                linkSpeedBitsPerSecond: media.speed,
                receivedBytes: values.receivedBytes, transmittedBytes: values.transmittedBytes,
                inputErrors: values.inputErrors, outputErrors: values.outputErrors,
                inputDrops: values.inputDrops
            )
        }.sorted { $0.id < $1.id }
    }

    /// Test exactly two unfragmented packets at the selected interface's MTU.
    /// Accept only a literal unicast IP. Scoped route lookup plus socket binding
    /// prevents the test silently using Wi-Fi or another Ethernet interface.
    func probe(peer: String, interface: String, mtu: Int) async -> JumboProbeResult {
        guard Self.isEthernetBSDName(interface),
              let literal = Self.literalPeer(peer, interface: interface),
              (1280...9000).contains(mtu) else {
            return JumboProbeResult(succeeded: false,
                summary: "Enter a literal unicast IPv4 or IPv6 address and a supported packet size.")
        }
        guard !Task.isCancelled else {
            return JumboProbeResult(succeeded: false, summary: "Compatibility test cancelled.")
        }
        guard let bundleIdentifier = ownershipLock.withLock({ discoveredDriverBundleIdentifier }) else {
            return JumboProbeResult(succeeded: false, summary: "Refresh adapter status before testing this peer.")
        }
        let cancellation = ProbeCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                Self.performProbe(peer: literal, interface: interface, mtu: mtu,
                                  driverBundleIdentifier: bundleIdentifier, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Deterministic validation and parsing

    static func isEthernetBSDName(_ name: String) -> Bool {
        guard name.hasPrefix("en"), (3..<Int(IFNAMSIZ)).contains(name.utf8.count) else { return false }
        return name.dropFirst(2).utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isOwnedInterface(name: String, ancestors: [RegistryNode],
                                 driverBundleIdentifier: String) -> Bool {
        guard isEthernetBSDName(name), !driverBundleIdentifier.isEmpty else { return false }
        return ancestors.contains { node in
            let isLekuoClass = node.properties["IOUserClass"] == "Lekuo82599" ||
                node.className == "Lekuo82599" || node.className == "IOUserNetworkEthernet"
            let exactBundle = ["IOUserServerName", "CFBundleIdentifier", "IOBundleIdentifier",
                               "IOUserServerBundleIdentifier"].contains {
                node.properties[$0] == driverBundleIdentifier
            }
            return isLekuoClass && exactBundle
        }
    }

    static func parseInterfaceMessages(_ data: Data) throws -> [UInt32: InterfaceMetrics] {
        var result: [UInt32: InterfaceMetrics] = [:]
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw AdapterServiceError.malformedInterfaceStatistics }
            let length: UInt16 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            guard length >= 4, Int(length) <= data.count - offset else {
                throw AdapterServiceError.malformedInterfaceStatistics
            }
            let version = data[data.startIndex + offset + 2]
            let type = data[data.startIndex + offset + 3]
            if version == UInt8(RTM_VERSION), type == UInt8(RTM_IFINFO2) {
                guard Int(length) >= MemoryLayout<if_msghdr2>.size else {
                    throw AdapterServiceError.malformedInterfaceStatistics
                }
                let message = data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                let values = message.ifm_data
                if values.ifi_type == UInt8(IFT_ETHER), message.ifm_index > 0 {
                    result[UInt32(message.ifm_index)] = InterfaceMetrics(
                        mtu: Int(values.ifi_mtu), isEnabled: message.ifm_flags & IFF_UP != 0,
                        receivedBytes: values.ifi_ibytes, transmittedBytes: values.ifi_obytes,
                        inputErrors: values.ifi_ierrors, outputErrors: values.ifi_oerrors,
                        inputDrops: values.ifi_iqdrops
                    )
                }
            }
            offset += Int(length)
        }
        return result
    }

    static func literalPeer(_ input: String, interface: String) -> LiteralPeer? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count < 100,
              trimmed.utf8.allSatisfy({ (33...126).contains($0) }),
              isEthernetBSDName(interface) else { return nil }
        let parts = trimmed.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first, !first.isEmpty else { return nil }
        let address = String(first)
        if parts.count == 2, String(parts[1]) != interface { return nil }
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            guard parts.count == 1 else { return nil }
            let host = UInt32(bigEndian: ipv4.s_addr)
            let firstOctet = host >> 24
            // Exclude unspecified, loopback, multicast, and broadcast targets.
            guard firstOctet != 0, firstOctet != 127, firstOctet < 224,
                  host != UInt32.max else { return nil }
            return LiteralPeer(address: address, family: .ipv4,
                               isLinkLocal: firstOctet == 169 && (host >> 16) & 255 == 254)
        }
        var ipv6 = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        guard bytes.count == 16, bytes[0] != 255,
              !bytes.allSatisfy({ $0 == 0 }),
              !(bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1),
              !(bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255)
        else { return nil }
        let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        // A zone is meaningful only for a link-local address.
        guard parts.count == 1 || linkLocal else { return nil }
        return LiteralPeer(address: address, family: .ipv6, isLinkLocal: linkLocal)
    }

    static func payloadSize(mtu: Int, family: IPFamily) -> Int {
        mtu - (family == .ipv4 ? 20 : 40) - 8
    }

    static func routeInterface(from output: String) -> String? {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { return nil }
            return String(trimmed.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard values.count == 1, isEthernetBSDName(values[0]) else { return nil }
        return values[0]
    }

    static func receivedBothReplies(in output: String) -> Bool {
        // Locale is fixed for child tools. Match the summary, not a single reply.
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { return false }
            return fields[0] == "2 packets transmitted" &&
                (fields[1] == "2 packets received" || fields[1] == "2 received")
        }
    }

    static func receivedBothFullSizeReplies(in output: String, expectedReplyBytes: Int) -> Bool {
        guard receivedBothReplies(in: output) else { return false }
        var sequences = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, Int(fields[0]) == expectedReplyBytes,
                  fields[1] == "bytes", fields[2] == "from",
                  let sequence = fields.first(where: { $0.hasPrefix("icmp_seq=") }),
                  let value = Int(sequence.dropFirst("icmp_seq=".count)), (0...1).contains(value)
            else { continue }
            sequences.insert(value)
        }
        return sequences == Set([0, 1])
    }

    static func negotiatedSpeed(activeMedia: Int32, status: Int32) -> UInt64? {
        guard status & IFM_AVALID != 0, status & IFM_ACTIVE != 0,
              activeMedia & IFM_NMASK == IFM_ETHER else { return nil }
        let subtype = activeMedia & IFM_TMASK
        // IFM_AUTO and a nominal ifi_baudrate do not prove negotiated speed.
        let gigabit: [Int32] = [IFM_1000_SX, IFM_1000_LX, IFM_1000_CX, IFM_1000_T,
                                IFM_1000_CX_SGMII, IFM_1000_KX, extendedMediaSubtype(41)]
        let tenGigabit: [Int32] = [IFM_10G_SR, IFM_10G_LR, IFM_10G_CX4, IFM_10G_T,
                                   IFM_10G_KX4, IFM_10G_KR, IFM_10G_CR1, IFM_10G_ER,
                                   extendedMediaSubtype(33), extendedMediaSubtype(34),
                                   extendedMediaSubtype(35), extendedMediaSubtype(42),
                                   extendedMediaSubtype(59)]
        if gigabit.contains(subtype) { return 1_000_000_000 }
        if tenGigabit.contains(subtype) { return 10_000_000_000 }
        if subtype == IFM_100_TX { return 100_000_000 }
        if subtype == IFM_10_T { return 10_000_000 }
        return nil
    }

    private static func extendedMediaSubtype(_ value: Int32) -> Int32 {
        // The SDK's IFM_X macro cannot be imported into Swift. Mirror its
        // definition from net/if_media.h, preserving the extended type bits.
        ((value & ~IFM_TMASK_COMPAT) << IFM_TMASK_EXT_SHIFT) | (value & IFM_TMASK_COMPAT)
    }

    // MARK: - Operating system read-only queries

    private static func ownedInterfaces(driverBundleIdentifier: String) throws -> [String] {
        var names = Set<String>()
        // DriverKit interfaces may use their own kernel class rather than
        // conforming to the legacy IONetworkInterface class. Ownership evidence
        // is still mandatory for every candidate from every matching class.
        for interfaceClass in ["IONetworkInterface", "IOUserNetworkInterface", "IOUserEthernetInterface"] {
            guard let matching = IOServiceMatching(interfaceClass) else {
                throw AdapterServiceError.registryUnavailable
            }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                throw AdapterServiceError.registryUnavailable
            }
            defer { IOObjectRelease(iterator) }
            while true {
                let interface = IOIteratorNext(iterator)
                guard interface != 0 else { break }
                defer { IOObjectRelease(interface) }
                guard let name = properties(interface)["BSD Name"] else { continue }
                var ancestors: [RegistryNode] = []
                var entry = interface
                var ownedEntry = false
                // Interface -> controller -> DriverKit service. A bounded parent
                // walk cannot search unrelated siblings or global matches.
                for _ in 0..<12 {
                    var parent: io_registry_entry_t = 0
                    let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
                    if ownedEntry { IOObjectRelease(entry) }
                    ownedEntry = false
                    guard status == KERN_SUCCESS else { break }
                    entry = parent
                    ownedEntry = true
                    ancestors.append(RegistryNode(className: className(entry), properties: properties(entry)))
                }
                if ownedEntry { IOObjectRelease(entry) }
                if isOwnedInterface(name: name, ancestors: ancestors,
                                    driverBundleIdentifier: driverBundleIdentifier) { names.insert(name) }
            }
        }
        return names.sorted()
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: String] {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = raw?.takeRetainedValue() as? [String: Any] else { return [:] }
        let keys = ["BSD Name", "IOUserClass", "IOUserServerName", "CFBundleIdentifier",
                    "IOBundleIdentifier", "IOUserServerBundleIdentifier"]
        return keys.reduce(into: [:]) { result, key in
            if let value = dictionary[key] as? String { result[key] = value }
        }
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func interfaceMetrics() throws -> [UInt32: InterfaceMetrics] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Interfaces can appear while sizing the result, so retry a bounded
        // number of times rather than returning truncated statistics.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
                  size > 0, size <= 16 * 1024 * 1024 else {
                throw AdapterServiceError.interfaceStatisticsUnavailable
            }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if status == 0 {
                data.count = size
                return try parseInterfaceMessages(data)
            }
            guard errno == ENOMEM else { break }
        }
        throw AdapterServiceError.interfaceStatisticsUnavailable
    }

    private static func mediaStatus(interface: String) -> (state: AdapterLinkState, speed: UInt64?) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return (.unknown, nil) }
        defer { close(descriptor) }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { buffer in
            for (index, byte) in interface.utf8.enumerated() { buffer[index] = byte }
        }
        // _IOWR('i', 72, struct ifmediareq), from sys/sockio.h. This C macro
        // cannot be imported by Swift, so calculate it using the SDK layout.
        let getExtendedMedia = UInt(0xc0000000 | ((MemoryLayout<ifmediareq>.size & 0x1fff) << 16) |
                                    (0x69 << 8) | 72)
        let getCompatibleMedia = UInt(0xc0000000 | ((MemoryLayout<ifmediareq>.size & 0x1fff) << 16) |
                                      (0x69 << 8) | 56)
        guard (ioctl(descriptor, getExtendedMedia, &request) == 0 ||
               ioctl(descriptor, getCompatibleMedia, &request) == 0),
              request.ifm_status & IFM_AVALID != 0 else { return (.unknown, nil) }
        let state: AdapterLinkState = request.ifm_status & IFM_ACTIVE != 0 ? .active : .inactive
        return (state, negotiatedSpeed(activeMedia: request.ifm_active, status: request.ifm_status))
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
        let cancelled: Bool
        let outputLimitExceeded: Bool
    }

    private static func runTool(_ path: String, arguments: [String], timeout: TimeInterval,
                                cancellation: ProbeCancellation) -> ProcessResult? {
        guard !cancellation.isCancelled, timeout > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let existingFlags = fcntl(readDescriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(readDescriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else { return nil }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var outputLimitExceeded = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        func drainOutput() {
            while !outputLimitExceeded {
                let count = Darwin.read(readDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let remaining = 64 * 1024 - output.count
                    output.append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { outputLimitExceeded = true }
                } else if count < 0, errno == EINTR {
                    continue
                } else { break }
            }
        }
        while process.isRunning {
            drainOutput()
            if cancellation.isCancelled || outputLimitExceeded ||
               ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(20_000)
        }
        let timedOut = process.isRunning && ProcessInfo.processInfo.systemUptime >= deadline
        if process.isRunning {
            // These tools have no subprocesses. Kill the exact child and reap it,
            // so a failed or cancelled probe never leaves a listener or ping.
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        drainOutput()
        try? pipe.fileHandleForReading.close()
        return ProcessResult(status: process.terminationStatus,
                             output: String(decoding: output, as: UTF8.self), timedOut: timedOut,
                             cancelled: cancellation.isCancelled, outputLimitExceeded: outputLimitExceeded)
    }

    private static func performProbe(peer: LiteralPeer, interface: String, mtu: Int,
                                     driverBundleIdentifier: String,
                                     cancellation: ProbeCancellation) -> JumboProbeResult {
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        guard !cancellation.isCancelled else {
            return JumboProbeResult(succeeded: false, summary: "Compatibility test cancelled.")
        }
        guard let owned = try? ownedInterfaces(driverBundleIdentifier: driverBundleIdentifier),
              owned.contains(interface), if_nametoindex(interface) != 0,
              let values = try? interfaceMetrics()[if_nametoindex(interface)],
              values.isEnabled, values.mtu >= mtu else {
            return JumboProbeResult(succeeded: false,
                summary: "The selected adapter must be enabled and configured for this packet size first.")
        }
        let target = peer.address + (peer.isLinkLocal && peer.family == .ipv6 ? "%\(interface)" : "")
        let family = peer.family == .ipv4 ? "-inet" : "-inet6"
        guard let route = runTool("/sbin/route",
            arguments: ["-n", "get", family, "-ifscope", interface, target],
            timeout: min(1, deadline - ProcessInfo.processInfo.systemUptime), cancellation: cancellation),
            !route.timedOut, !route.cancelled, !route.outputLimitExceeded,
            route.status == 0, routeInterface(from: route.output) == interface else {
            return JumboProbeResult(succeeded: false,
                summary: cancellation.isCancelled ? "Compatibility test cancelled." :
                    "No route to this peer through the selected adapter was verified.")
        }
        let payload = String(payloadSize(mtu: mtu, family: peer.family))
        let arguments = peer.family == .ipv4 ?
            ["-n", "-D", "-b", interface, "-c", "2", "-t", "5", "-W", "1500", "-s", payload, target] :
            ["-n", "-D", "-B", interface, "-c", "2", "-s", payload, target]
        guard let ping = runTool(peer.family == .ipv4 ? "/sbin/ping" : "/sbin/ping6",
                                 arguments: arguments,
                                 timeout: min(5.5, deadline - ProcessInfo.processInfo.systemUptime),
                                 cancellation: cancellation) else {
            return JumboProbeResult(succeeded: false, summary: cancellation.isCancelled ?
                "Compatibility test cancelled." : "macOS could not start the compatibility test.")
        }
        if ping.cancelled {
            return JumboProbeResult(succeeded: false, summary: "Compatibility test cancelled.")
        }
        let replyBytes = mtu - (peer.family == .ipv4 ? 20 : 40)
        let success = !ping.timedOut && !ping.outputLimitExceeded && ping.status == 0 &&
            receivedBothFullSizeReplies(in: ping.output, expectedReplyBytes: replyBytes)
        return JumboProbeResult(succeeded: success,
            // DF/DONTFRAG proves the outbound probes were unfragmented. ping
            // receives reassembled replies; it cannot prove inbound fragmentation.
            summary: success ? "The peer answered both unfragmented \(mtu)-byte probes with full-sized replies. Reply fragmentation is not measured." :
                "The peer did not answer both \(mtu)-byte packets. Its MTU, the network path, or an ICMP filter may prevent this test.")
    }
}
