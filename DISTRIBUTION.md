# Signed release setup

Releases use date tags in `YYYY.MM.DD` format. A date-tag push publishes only
after the app, embedded driver, rollback helper, and disk image pass the release
checks. Manual workflow runs produce a downloadable candidate without creating
a GitHub Release.

## Apple prerequisites

- Apple approval for **DriverKit**, **DriverKit Family Networking**, and
  **DriverKit PCI (PrimaryMatch)** distribution capabilities on the driver App ID.
  The development capabilities alone do not authorize public distribution.
- A **Developer ID Application** certificate and its private key, exported as a
  password-protected PKCS#12 (`.p12`) file. Apple Development and Apple
  Distribution certificates are not substitutes for Developer ID.
- All-device **Developer ID provisioning profiles** for both the host app and
  driver extension. The app needs system-extension installation permission;
  the driver needs networking and PCI access for the supported controller.
- An App Store Connect **team API key** authorized for Apple's notary service,
  with its key ID and issuer ID.

Apple may grant PCI access with an `IOPCIPrimaryMatch` value/mask rather than
an exact device ID. The release validator checks that the grant covers the
supported controller; the driver personality remains limited to the tested
hardware.

If macOS rejects an OpenSSL-generated PKCS#12 bundle with a MAC verification
error, verify the password first, then export with macOS-compatible PKCS#12
algorithms. Keep a strong random export password and test importing into a
temporary keychain before adding the bundle to CI.

The app, driver, helper, and profiles must belong to the same Apple team. Keep
keys, certificates, profiles, and account configuration outside Git. See
[PRIVACY.md](PRIVACY.md) for identity information inherently visible in Apple
signatures. Changing an existing driver's bundle identifier or team may break
upgrade continuity.

## GitHub release environment

Create an Actions environment named `release`, restricting deployment to
`main` and date tags. Protect `main` and release tags from unreviewed changes;
anyone able to change trusted release code could access signing credentials.
Use environment secrets, not plaintext repository variables:

| Secret | Content |
|---|---|
| `APP_BUNDLE_ID` | Distribution bundle identifier for the host app |
| `DRIVER_BUNDLE_ID` | Distribution bundle identifier for the driver extension |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `SIGNING_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID certificate and private key |
| `SIGNING_CERTIFICATE_PASSWORD` | PKCS#12 export password |
| `APP_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID app profile |
| `DRIVER_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID driver profile |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `NOTARY_KEY_ID` | API key identifier |
| `NOTARY_ISSUER_ID` | API issuer identifier |

For example, send file contents directly to GitHub without printing them or
using the clipboard:

```sh
base64 -i /secure/path/distribution.p12 | gh secret set SIGNING_CERTIFICATE_P12_BASE64 --env release
```

Run this from your authenticated repository checkout. Set each other secret
from an appropriately protected file via stdin, or enter it through GitHub's
secret form. Never put secret values in shell commands, commits, issue comments,
or workflow logs.

## Candidate verification

After the source CI passes on `main`, use **Actions → Signed release → Run
workflow**, choose `main`, and enter the date version. The workflow:

1. Checks the calendar date, requires the source commit to belong to `main`,
   scans source and reachable Git history for common private data, and tests
   distribution-profile validation before accessing signing secrets.
2. Runs control-app and rollback-protocol fixtures on a hosted Xcode 27 Mac.
3. Imports signing assets into a temporary keychain, validates profile scope,
   expiry, device matching, and certificate membership, then archives the app.
4. Checks nested signatures, remapped source paths, and profiles; notarizes,
   staples, and assesses the app with Gatekeeper.
5. Builds a DMG containing **Lekuo Control.app**, an Applications shortcut,
   installation instructions, and license notices. It then signs, notarizes,
   staples, and assesses the DMG.
6. Recomputes the final checksum after stapling, writes a build manifest, and
   removes the temporary keychain and profiles. Only the DMG, checksum, and
   manifest become workflow artifacts, retained for seven days.

Signing and notarization output is captured rather than printed because it
can contain account identity. A failed stage reports its category and exit
status. No unverified artifact is uploaded. A notarized build still needs real
hardware testing; successful signing does not prove driver compatibility.

The build number is independent of the date version and increases with the
workflow run number. It starts above existing development builds to preserve
system-extension upgrade ordering. Source archives are not installers.

## Publishing

After checking the candidate, create and push the date tag at the tested
`main` commit. Sign the Git tag if you have Git signing configured:

```sh
git tag -s 2026.01.02 -m "2026.01.02"
git push origin 2026.01.02
```

Git tag signatures and Apple code signatures are separate. The workflow checks
the tag's date and ancestry; it does not validate a maintainer Git signing key.
The tag run rebuilds and rechecks the artifact, then publishes the DMG,
SHA-256 checksum, and `release.json`. Its publishing job alone has repository
write access and receives no Apple secrets. Keep the original tag immutable;
use a later date for a replacement release.

The current workflow marks releases as experimental prereleases and includes
installation and hardware requirements in their notes. Remove that designation
only after the driver's validation and support policy justify a stable release.

## Local packaging

`scripts/package_local.py` can verify and package an existing signed app. It
does not sign, notarize, activate, or publish anything. Development previews
are restricted to registered Macs and must remain private. Public distribution
requires the full release process, not just successful local DMG creation.
