# Signed release setup

Releases use date tags in `YYYY.MM.DD` format. Pushing a tag such as
`2026.01.02` starts the signed release workflow. The workflow publishes only
after the app and embedded driver pass signature checks and Apple notarization.

## Apple prerequisites

- Apple approval for the DriverKit networking and PCI entitlements for the
  distribution driver App ID.
- A Developer ID Application certificate and private key, exported together as
  a password-protected PKCS#12 (`.p12`) file.
- Developer ID provisioning profiles for both the host app and driver extension.
- An App Store Connect API key with access to the Apple notary service.

The app and driver must use the same Apple team. Keep all certificates, keys,
profiles, identifiers, and team data out of Git.

## GitHub release environment

Create a GitHub Actions environment named `release`. Add these environment
secrets:

| Secret | Content |
|---|---|
| `APP_BUNDLE_ID` | Distribution bundle identifier for the host app |
| `DRIVER_BUNDLE_ID` | Distribution bundle identifier for the driver extension |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `SIGNING_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key |
| `SIGNING_CERTIFICATE_PASSWORD` | Password used when exporting the PKCS#12 file |
| `APP_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID app provisioning profile |
| `DRIVER_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID driver provisioning profile |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `NOTARY_KEY_ID` | App Store Connect API key identifier |
| `NOTARY_ISSUER_ID` | App Store Connect API issuer identifier |

On macOS, encode a file without writing the encoded value to the terminal:

```sh
base64 -i path/to/file | pbcopy
```

Paste the clipboard contents directly into the matching GitHub secret. GitHub
Actions creates a temporary keychain on the hosted runner and discards it when
the job ends.

## Publishing

After CI passes on `main`, create and push the date tag:

```sh
git tag -s 2026.01.02 -m "2026.01.02"
git push origin 2026.01.02
```

Use a signed Git tag. The workflow then builds the app and embedded driver,
signs them with Developer ID, notarizes and staples the app, creates a DMG with
an Applications shortcut, notarizes and staples the DMG, and publishes the DMG
plus its SHA-256 checksum to GitHub Releases.
