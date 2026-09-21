# Security and safety policy

## Development status

This is an experimental hardware driver. It owns a PCI device, programs DMA,
and can replace the operating system's existing NIC driver. Treat installation
and activation as privileged hardware changes.

## Before testing

- Verify the PCI vendor, device, subsystem, and function match your hardware.
- Keep an independent recovery network path and local recovery access.
- Back up important data and stop active transfers before changing network MTU.
- Test end-to-end MTU before making jumbo settings persistent.
- Build and sign with bundle IDs and provisioning profiles you control.
- Review the exact source revision and entitlements before activation.

Do not redistribute a build signed with another developer's identity or
provisioning profile.

## Known limitations

- Long-run stability is not established.
- Polling can consume CPU and may lose packets under some workloads.
- Only one RX/TX queue is implemented.
- Hardware checksum and segmentation offloads are unavailable.
- Link media reporting is incomplete.
- The implementation has been exercised on one enclosure/controller pairing.

## Reporting issues

When reporting a problem, remove names, email addresses, Apple team IDs,
certificate fingerprints, hostnames, IP and MAC addresses, device serials,
filesystem paths, packet captures, and credentials. Include only the minimum
register, log, and hardware information needed to reproduce the issue.
