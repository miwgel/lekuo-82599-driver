# Publication privacy notes

This source bundle was prepared from a private development workspace. The
following material is intentionally excluded:

- Apple developer team, certificate, and provisioning profile identifiers;
- signed apps, dexts, archives, and provisioning files;
- personal names, account names, email addresses, and local home paths;
- machine names, private addresses, MAC addresses, device serials, and PCI bus
  addresses;
- packet captures and detailed benchmark evidence;
- NAS datasets, pool inventories, VM configuration, and remote-management
  scripts; and
- local recovery and login automation.

The repository uses `com.example` bundle IDs. Each developer must substitute
identifiers they control locally and keep those values out of shared commits.

## Public identity versus secrets

Git commits are attributed to the maintainer's chosen public name and GitHub
noreply address. Third-party copyright notices remain intact.

Apple Developer ID signatures necessarily include the registered developer
identity and team identifier. Distribution profiles also contain signed
application identifiers and certificate metadata. This information is visible
inside a signed download, even when it is absent from the source repository.
Private signing keys, account passwords, notarization keys, personal email
addresses, and development device identifiers must never be released.

Release signing uses GitHub environment secrets and an ephemeral keychain.
Unsigned CI receives no Apple credentials. Release logs are limited to
sanitized status and error categories; raw signing and notarization logs are
not uploaded as artifacts.
