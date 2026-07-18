# Desktop release

Pedals desktop releases are universal, notarized macOS disk images. The menu
bar app links `PedalsDaemonCore` directly and is itself the long-running PTY and
relay service process; it does not launch or embed a second daemon executable.

## GitHub configuration

The `Release desktop app` workflow needs Actions to have read/write repository
permissions and these repository secrets:

| Secret | Value |
|---|---|
| `MACOS_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `MACOS_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) with notarization access |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Private Ed25519 key exported by Sparkle's `generate_keys` tool |

Never add the source `.p12`, `.p8`, or Sparkle private key files to the
repository. The matching Sparkle public key is pinned in the desktop app's
Info.plist.

## Publish a release

Create and push a three-part version tag:

```bash
git tag desktop-v1.0.0
git push origin desktop-v1.0.0
```

The workflow tests the shared desktop service core, builds the app for both
`arm64` and `x86_64`, signs it with hardened runtime, creates a DMG, submits it
to Apple's notary service, staples the ticket, and publishes these GitHub
release assets:

- `Pedals-macOS.dmg`
- `Pedals-macOS.dmg.sha256`
- `appcast.xml`

The website's `/download/macos` route redirects to that exact asset on the
latest GitHub release. Set the Worker's `DESKTOP_RELEASE_REPOSITORY` variable to
the repository slug, for example `owner/pedals`, before deploying the website.
The stable `/appcast.xml` route redirects to the signed feed from the same
release. Pedals checks it on launch and every 24 hours, and users can also run
`Check for Updates…` from the menu or Settings. Both the feed and the update
archive are verified with the app's pinned Ed25519 public key before an update
is installed.

## Build locally

Local builds are unsigned. Xcode 26, Swift 6, and XcodeGen are required:

```bash
PEDALS_DESKTOP_VERSION=1.0.0 \
PEDALS_DESKTOP_BUILD_NUMBER=1 \
./scripts/build-desktop-release.sh

./scripts/package-desktop-dmg.sh
```

Outputs are written below `.artifacts/desktop-release/` and must not be
committed.
