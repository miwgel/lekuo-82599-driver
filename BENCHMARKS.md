# Sanitized benchmark summary

These are single-run development measurements from one Lekuo DTB3F21 link.
They demonstrate feasibility, not guaranteed performance on other systems.
Payload integrity was checked with SHA-256 after each file transfer.

## Link capacity

| Test | Host to peer | Peer to host |
|---|---:|---:|
| 3-second jumbo TCP | 9.04 Gb/s | 9.85 Gb/s |
| 1 GiB plain TCP file copy | 9.39 Gb/s | 9.82 Gb/s |

## SMB to a virtualized NAS

All SMB payload counters were attributed to the 10 GbE adapter. The host,
bridge, VM tap, and NAS guest used MTU 9000 for the jumbo results.

| Workload | Write | Read |
|---|---:|---:|
| One 1 GiB file | 7.66 Gb/s | 6.19 Gb/s |
| One 4 GiB file | 9.22 Gb/s | 5.91 Gb/s |
| Four 256 MiB files, two workers | 6.41 Gb/s | 9.53 Gb/s |
| Four 256 MiB files, four workers | 7.87 Gb/s | 9.58 Gb/s |
| 128 × 8 MiB files | 1.87 Gb/s | 4.96 Gb/s |
| 512 × 256 KiB files | 0.12 Gb/s | 0.37 Gb/s |

Large sequential or parallel transfers can approach the link limit. Small-file
workloads remain dominated by filesystem, protocol, and per-file overhead.

Raw evidence is excluded because it contains local network identifiers and
storage topology details.
