<p align="center"><img src="Brand/icon.svg" width="112" height="112" alt="Lekuo Control icon"></p>

# Lekuo Control

**10 GbE for macOS.** An open-source driver and native control app for the
Lekuo DTB3F21, with jumbo packets, live traffic counters, and recoverable
packet-size settings.

[Getting started](#getting-started) · [Hardware](#hardware-match) ·
[Build from source](#build-prerequisites) · [Benchmarks](BENCHMARKS.md) ·
[Release signing](DISTRIBUTION.md)

This repository contains an experimental macOS DriverKit network driver for
the Intel 82599ES controller used by the Lekuo DTB3F21 Thunderbolt/USB4 to
SFP+ adapter.

This is an independent community project, unaffiliated with Lekuo, Intel, or
Apple. The hardware vendor's name identifies the adapter we have tested.

The implementation began from Apple's NetworkingDriverKit sample and uses
82599 descriptor definitions adapted from the BSD-licensed ixy project. See
`LICENSE.txt` and `IXY-LICENSE.txt`.

## Getting started

Use a **signed and notarized** DMG from the repository's Releases page when
one is available. Source archives and development previews are not installers.

1. Copy **Lekuo Control** to Applications and open it.
2. Click **Install Driver**, then approve the driver in System Settings when
   macOS asks. The app shows whether approval or a restart is still needed.
3. Confirm that the adapter appears and reports an active Ethernet link.
4. Leave packets at **Standard (1500)** unless the complete network path
   supports jumbo packets. Selecting **Jumbo · 9000** applies and saves that
   local setting after macOS authorization. The receiver test in Diagnostics
   is optional; it does not gate configuration.

The current build targets **macOS 27** and is tested on Apple silicon. Keep a
second network connection available when installing or removing a driver.

## Status

The driver has carried 9,000-byte IP packets and real file transfers near the
10 GbE wire limit on one development system. It is still a prototype:

- one RX/TX queue;
- 250 microsecond polling rather than interrupts;
- no checksum or TSO offload;
- incomplete media reporting;
- limited hardware and long-run testing; and
- no production support or recovery guarantee.

The source enables PCI function 0 and directly programs NIC registers and
DMA. A faulty build can crash macOS or disconnect the network. Keep a separate
recovery connection and do not test on a system whose only access depends on
this adapter.

## Hardware match

The DriverKit personality matches:

- PCI vendor/device: `8086:10fb` (Intel 82599ES)
- PCI subsystem: `8086:000c`
- PCI function: `0`, enforced again before the driver opens the device

Confirm these identifiers for your enclosure before signing or activating the
extension. The match is intentionally independent of a machine-specific PCI
bus address.

## Build prerequisites

- A compatible macOS and Xcode release with DriverKit, PCIDriverKit, and
  NetworkingDriverKit SDKs.
- An Apple Developer Program team.
- Apple-approved DriverKit networking and PCI entitlements for bundle IDs you
  control.

The checked-in identifiers use the placeholder namespace `com.example`.
Set both bundle identifiers in `Configuration/SampleCode.xcconfig`, update the
driver product filename in the Xcode project to match, select your development
team, and choose your own provisioning profiles before building. The app reads
its driver identifier from its generated metadata. Do not commit certificates,
profiles, private keys, team IDs, or signed application bundles.

Open `Lekuo82599.xcodeproj`, select the `Lekuo82599App` scheme, and build for
macOS. Activation uses Apple's System Extensions API and normally requires
explicit approval in System Settings.

## Lekuo Control

The companion app provides native driver installation and removal, observed
extension status, ownership-verified adapter discovery, live interface counters,
and packet-size configuration. Standard (1500), jumbo (9000), and custom MTUs
are saved after macOS authorization and verification of the local interface.
Selecting Standard or Jumbo applies immediately; Custom has an Apply button.
An independent helper restores the original setting if an unfinished save
fails. An optional interface-bound peer test is available in Diagnostics;
changing the local MTU does not prove end-to-end jumbo support.

Diagnostics are previewed before export and contain an allowlist of versions,
packet sizes, link state, and counters. Addresses, serials, signing identifiers,
interface names, filesystem paths, and raw logs are excluded.

See [CONTROL.md](CONTROL.md) for configuration behavior, permissions, verification,
and limitations. Hardware offloads and performance profiles are future driver
work and are not exposed as working controls.

## Releases

Release versions use calendar tags such as `2026.01.02`. The intended user
download is a signed and notarized DMG containing the host app and its embedded
driver extension. The app must be copied to Applications before it requests
driver activation.

The source build and signed release workflows are in `.github/workflows`.
Signed releases require Apple distribution approval and repository secrets;
see [DISTRIBUTION.md](DISTRIBUTION.md). Certificates, private keys,
provisioning profiles, Apple identifiers, and personal email addresses must
never be committed.

## Jumbo frames

The driver reports an MTU range of 1280–9000. Jumbo traffic works only when
every hop in the path uses a compatible MTU, including bridges, VM tap
interfaces, guest interfaces, switches, and the peer NIC. Validate the whole
path with a non-destructive packet test before relying on it.

## Results

Sanitized benchmark summaries are in [BENCHMARKS.md](BENCHMARKS.md). Raw packet
captures, addresses, device serials, hostnames, storage inventories, signing
records, and machine-specific automation are deliberately excluded.

The most recent receive-path investigation found substantial packet reordering
in the test server's virtual-machine-to-physical-NIC transmit queues. A direct
host control reached 9.88 Gb/s with two retransmissions in a three-second test.
This is evidence about that test setup, not a guarantee for every adapter,
network, or NAS. See [BENCHMARKS.md](BENCHMARKS.md).

## Safety and reporting

Read [SECURITY.md](SECURITY.md) before testing or redistributing the driver.
This repository contains source only. It does not contain a signed driver or
Apple provisioning material. The app embeds a signed packet-size watchdog;
building or opening the app never automatically activates the driver or changes
network settings.
