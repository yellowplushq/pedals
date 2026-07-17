# Pedals Architecture

Monorepo layout:

```
pedals/
├── docs/            PROTOCOL.md (the contract — read it first), ARCHITECTURE.md
├── relay/           Node 24 zero-knowledge WebSocket relay (deploys to Cloud Run)
├── shared/
│   └── PedalsKit/   Swift package: frame codec, crypto (§2-4 of protocol), pairing
│                    URL parse/build, shared by iOS app + desktop
├── desktop/
│   ├── PedalsDaemon/  Swift package: `pedals` executable — daemon (PTY manager,
│   │                  relay host connection, unix socket server) + CLI subcommands
│   └── PedalsMenubar/ SwiftUI MenuBarExtra app (xcodegen project) — session list,
│                      close, pairing QR, relay status; thin client of the unix socket
├── ios/             UIKit app "Pedals" (xcodegen project), depends on PedalsKit +
│                    GhosttyKit (https://github.com/Lakr233/libghostty-spm,
│                    product: GhosttyTerminal → UIKit TerminalView, Metal renderer)
└── scripts/         deploy-relay.sh (gcloud run deploy), e2e.sh, dev helpers
```

## Build system

- Swift packages build with `swift build` (macOS targets) / via Xcode for iOS.
- Xcode projects are generated with **XcodeGen** (`project.yml` in ios/ and
  desktop/PedalsMenubar/). Never hand-edit .xcodeproj; regenerate with `xcodegen`.
- iOS builds: `xcodebuild -project ios/Pedals.xcodeproj -scheme Pedals
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Relay: plain Node 24, `npm start`, no build step, deps: `ws` only.
- Environment note: use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
  xcodebuild complains (xcode-select already points at Xcode.app on this machine).

## iOS app (bundle id `app.yellowplus.pedals`, iOS 17+, iPhone, portrait+landscape)

UIKit, no storyboards (code-only UI + a LaunchScreen storyboard). Structure:

- `AppDelegate/SceneDelegate` — URL scheme `pedals://` handling (pairing).
- `Core/` — `ConnectionController` (WSS to relay, PedalsKit crypto, reconnect with
  backoff, state publishing via Combine), `SessionStore` (list of remote sessions,
  active session id), `PairingStore` (Keychain).
- `UI/MainViewController` — the single main screen:
  - Full-bleed terminal area hosting `GhosttyTerminal.TerminalView` for the ACTIVE
    session. stdout/replay bytes are fed into the view; keyboard input + accessory bar
    (Esc, Tab, Ctrl, arrows, paste — a `UIToolbar`-style inputAccessoryView) is captured
    and sent as `stdin` frames. Session switch = swap fed terminal instance (keep one
    live emulator per attached session so switching is instant).
  - Leading icon rail (~64 pt, ultraThinMaterial): one circular icon per session
    (SF Symbol `terminal` / first letter, active highlighted with tint ring), a `+`
    button (create session), and at the bottom an expand button (`sidebar.leading`).
  - Expanded drawer (~320 pt overlay, thickMaterial, spring animation): session rows
    (title, cwd, live/exited badge), swipe-to-delete or trailing ✕ to close session,
    footer: connection status row (relay host, RTT, E2EE badge) + gear → Settings.
  - Empty/unpaired state: centered card with "Scan QR" (camera) and "Paste pairing
    link" (simulator-friendly) buttons.
- `UI/SettingsViewController` — grouped inset list: connection info, re-pair, font size,
  theme (GhosttyTheme), about.
- `UI/PairingScanViewController` — AVFoundation QR scanner + manual paste field.
- Design: Apple HIG. SF Symbols only, system materials, no custom chrome, dark-mode
  first (terminals are dark), respects safe areas, Dynamic Type where applicable.
  Minimal: nothing beyond what's specified.

## Desktop daemon (macOS 14+)

Swift package with targets: `PedalsDaemonCore` (library: PTY via openpty/login shell,
ring buffers, unix socket server, relay host client reusing PedalsKit) and `pedals`
(ArgumentParser executable: `serve`, `ls`, `new`, `kill`, `pair`, `status`).
QR in terminal: render with ANSI half-block characters (no dependency, ~25 lines) or
vendored pure-Swift QR encoder. Persist pairing in `~/.pedals/pairing.json`.

## Menubar app (macOS 14+, bundle id `app.yellowplus.pedals.menubar`)

SwiftUI `MenuBarExtra` (window style): sessions list with close buttons, "New session",
pairing QR (NSImage from CoreImage `CIQRCodeGenerator`), relay status dot, "Start/Stop
daemon" (spawns/terminates `pedals serve` as child if socket absent). LSUIElement=true.

## Relay deploy

`scripts/deploy-relay.sh`: `gcloud run deploy pedals-relay --source relay/
--project vigilant-willow-501102-i3 --region asia-northeast1 --allow-unauthenticated
--timeout 3600 --max-instances 1 --session-affinity`. Enables required services first
(`run.googleapis.com`, `cloudbuild.googleapis.com`, `artifactregistry.googleapis.com`).

## Testing

- PedalsKit: unit tests for frame codec round-trip, HKDF vectors (must match the Node
  reference impl in relay/test/crypto-ref.mjs), pairing URL parse/build.
- Relay: `node --test` — room join/forward/replace semantics.
- Daemon: spawn session, write "echo hi", read output; unix socket ls/kill.
- E2E (`scripts/e2e.sh`): local relay :8787 → `pedals serve` → headless Node test
  client (relay/test/client.mjs, uses reference crypto) pairs, creates session, runs
  `printf 'marker-%s\n' ok`, asserts stdout arrives decrypted. Then iOS simulator:
  build, install, `simctl openurl` the pairing URL, screenshot via `simctl io`.
