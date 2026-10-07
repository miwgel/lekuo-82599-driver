# Lekuo Control

## Driver and adapter status

The app queries macOS System Extensions rather than assuming every launch starts
with the driver unloaded. Installation, approval, restart, and removal are
distinct states. An enabled extension does not prove that hardware is attached.
Adapter discovery requires exact owning-driver bundle evidence in the interface's
IORegistry parent chain. Unrelated Ethernet, Wi-Fi, and tunnel interfaces are
not selectable. Negotiated speed is shown only when macOS explicitly reports an
active media speed; automatic media does not justify a nominal 10 Gb/s claim.

Traffic rates use differences between 64-bit interface counters and monotonic
sample times. Counter resets, adapter changes, and long gaps invalidate a rate.
These rates are current interface traffic, not a speed benchmark.

## Packet-size changes

Standard MTU is 1500; this driver supports 1280–9000. All settings apply only to
the selected local adapter. No remote host, switch, VM, or storage service is
configured by the app.

1. Select the adapter and packet size. For an increase, supply a receiver's literal
   IP address before starting the trial.
2. macOS requests administrator authorization using its native security dialog.
3. The signed watchdog revalidates the exact interface and driver registry IDs,
   reads the current active and saved MTUs, and applies a temporary trial.
4. The previous saved MTU preference is immediately restored without applying it;
   the temporary MTU remains active. Readbacks verify both values.
5. A peer test sends two unfragmented echo requests at the trial packet size,
   bound to the selected interface after checking its scoped route. Increasing
   MTU cannot be kept until both full-sized replies arrive.
6. Keep Settings commits the trial value. Revert Now, timeout, malformed commands,
   or app pipe closure restores the old live and saved settings.

The watchdog runs independently of the window/app, uses short preferences locks,
and refuses to overwrite a conflicting MTU changed by another application. It
preserves an absent/default MTU key and unrelated network preferences. Authorization
tokens pass only through an anonymous pipe, never files, arguments, logs, or
diagnostics. Neither the app nor helper handles or stores passwords.

Normal app exit or crash triggers rollback. This does not guarantee recovery
from forcible watchdog termination, OS failure, or power loss during the short
initial commit/apply/readback interval. Once saved storage has been restored, a
restart uses the old saved setting. Keep an independent connection available
while configuring an adapter.

The peer test validates full-sized outgoing unfragmented requests and complete
echo replies. An echo reply may be fragmented on its return path: this test does
not prove a single jumbo receive frame, sustained throughput, every destination,
or an entire network's jumbo compatibility. A failed test can also mean the peer
filters ICMP. No listeners are started, and child processes have bounded runtime,
bounded output, cancellation, and cleanup.

## Permissions and build

The app uses Authorization Services with SystemConfiguration for scoped packet-size
changes. It is a normal macOS app with Hardened Runtime, without App Sandbox;
the sandbox does not support these authorized system-preference operations.
The driver retains its separate DriverKit entitlements. The watchdog has no root
daemon, install script, login item, or persistent service and must be signed by
the same Apple team under the app's derived helper identifier.

The Xcode build phase in `scripts/build_mtu_watchdog.sh` compiles and signs
`Contents/Helpers/LekuoMTUWatchdog` before the containing app is signed. Public
source keeps placeholder bundle IDs. Supply private signing settings locally;
never commit certificates, profiles, authorization tokens, or identifiers.

Local development packaging uses `scripts/package_local.py`. It verifies nested
signatures, entitlements and development-profile coverage before creating a DMG
and a relative SHA-256 checksum. It does not publish a release or run CI.
Development packages contain unavoidable signing/profile metadata and must
remain private. Production distribution still requires Apple entitlements,
Developer ID signing, and notarization.

## Validation

Fixture tests cover ownership matching, statistics parsing, peer address and route
validation, DF payload/reply sizes, media reporting, MTU request validation,
probe confirmation rules, preference-conflict behavior, diagnostic privacy, and
traffic-rate resets. They do not authorize or change real network settings.

The native app, driver, and watchdog must build locally. Validate nested signatures
again after mounting the packaged DMG. A read-only launch should show the actual
installed extension state and disconnected-adapter state when no hardware is bound.
Live temporary apply, Keep, timeout, and app-crash rollback need deliberate testing
with an attached enclosure and an independent connection before a production release.
