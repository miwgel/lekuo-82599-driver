# Packet-size configuration integration

Add `Lekuo82599App/MTUConfiguration.swift` and `tools/mtu_protocol.swift` to the app's sources. Build `tools/mtu_protocol.swift` with `tools/mtu_watchdog.swift` as a separate executable, embed it at `Contents/Helpers/LekuoMTUWatchdog`, and sign it with the same Apple signing identity/team as the app and the identifier `${PRODUCT_BUNDLE_IDENTIFIER}.MTUWatchdog` before signing the containing app. Do not give the helper App Sandbox inheritance or root privileges. Authorization Services requires a containing app without App Sandbox; keep Hardened Runtime enabled.

Example helper build (the release build should supply the app's target and architectures):

```sh
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete tools/mtu_protocol.swift tools/mtu_watchdog.swift -o "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/LekuoMTUWatchdog"
```

The app validates a live `AdapterService.snapshots(driverBundleIdentifier:)` result before a trial and confirmation. The helper enumerates the same legacy/DriverKit interface classes, deduplicates registry entries, captures interface and owning driver registry IDs, and checks both before each write. It selects exactly one Ethernet service in the current network location, pins location/service IDs, and rejects a service shared between multiple locations because the public interface setter writes every member location. It compares the saved MTU against its expected value under a short preferences lock, preserves current unrelated media keys, and refuses to overwrite a conflicting MTU or location change. A credential-free empty per-user/interface lock file prevents competing watchdogs across app instances and relaunches.

The app obtains the `system.preferences.network` right using macOS Authorization Services. It verifies the containing app's nested code seal and the helper's exact derived signing identifier and Apple team before sending the authorization external form. The helper receives the external form as a fixed-size binary stdin prefix followed by one bounded, whitelisted JSON request. No token, credential, or password is stored in a file, argument, diagnostic, or log. The helper cannot create a password dialog itself.

The public `SCPreferencesApplyChanges` API applies **stored** preferences. The helper commits the trial MTU, applies it, waits for kernel readback, and immediately commits the original saved MTU **without applying**. It then checks that storage holds the original preference and the kernel still holds the trial. This preserves the reboot baseline while the test runs. Commit-only behavior is documented by the SDK and Apple's preferences monitor source: commit synchronizes stored preferences; active configuration updates require the apply notification. If macOS cannot hold this split, the test fails and attempts restoration.

After applying the trial, the helper starts a 45-second deadline and sends its absolute `mach_continuous_time` deadline with the success reply. The UI and helper use the same deadline, which advances during sleep, and reject stale probe results or keep commands. Timeout, malformed commands, EOF from app exit/crash, or other errors trigger restoration of the exact original active MTU, followed by restoration of the original saved preference without applying. This includes an originally absent MTU key and an explicitly saved zero/default key; empty configuration entities are normalized to nil. Normal confirmation commits/applies the requested value. The helper has no other configurable operation.

The UI calls `markProbeSucceeded(interface:mtu:)` only after a fresh, successful peer path test using that exact current adapter and packet size. `canKeep` permits reductions immediately; enlargements require this verified probe. The helper additionally rejects enlargement confirmation with a missing or mismatched probe MTU. `stop()` closes the pipe to request rollback when the app terminates; OS pipe closure also handles crashes.

An independent watchdog covers app exit/crash, not a watchdog crash, forcible kill, power loss, or OS failure during the short initial commit/apply/readback interval. After storage has been restored, a restart uses the original saved preference. Live MTU application remains a manual integration verification step; fixture tests never change a network or request authorization.

Run pure validation/state fixtures:

```sh
xcrun swiftc -parse-as-library tools/mtu_protocol.swift tools/mtu_tests.swift -o /tmp/lekuo-mtu-fixtures
/tmp/lekuo-mtu-fixtures
python3 tools/mtu_watchdog_smoke.py /path/to/LekuoMTUWatchdog
```

The helper smoke checks supply only missing/truncated/invalid authorization fixtures or an unsupported command-line argument. They cannot reach interface discovery or a preferences transaction, request no rights, and reap every process within a three-second bound.

Primary references:

- [Authorization Services and App Sandbox](https://developer.apple.com/documentation/security/authorization-services)
- [SCPreferencesCreateWithAuthorization](https://developer.apple.com/documentation/systemconfiguration/scpreferencescreatewithauthorization(_:_:_:_:))
- [SCPreferencesApplyChanges](https://developer.apple.com/documentation/systemconfiguration/scpreferencesapplychanges(_:))
- [Apple PreferencesMonitor source](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/PreferencesMonitor/prefsmon.c)
