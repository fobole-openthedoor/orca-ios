# orca-ios

A native iPhone client for [Orca](https://github.com/stablyai/orca), written in Swift and UIKit for iOS 26.

The layout, copy and colours follow the official Orca mobile app screen for screen; the chrome uses the system's own Liquid Glass controls (tab bar, navigation bar, sheets, menus). Strings come from the official app's locales, so every screen reads as it does there, in English, Simplified Chinese and Traditional Chinese.

## What's in it

- Pairing by QR code, pasted code or `orca://pair` link, end-to-end encrypted like the official app
- Feed, Bots, Agents, Usage and Automations tabs
- A desktop's workspaces with Workspace options synced to the desktop (grouping, sort, filters)
- Agent chats with the official transcript layout, and terminals drawn by Ghostty
- Bots: their Home Chat, and making a new one, blank, from the official templates, from a shared link, or brought over from OpenClaw, Hermes or OpenBot
- New workspaces, and new terminal or agent chat tabs
- Terminal key row with Esc, Tab and latching Shift, Ctrl and Alt
- Live Activities on the Lock Screen and in the Dynamic Island while an agent works or needs you
- Push notifications and remote Live Activity updates through a self-hosted gateway (below)

## Build

Needs Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen
open Orca.xcodeproj
```

- `scripts/sim.sh <simulator udid> <screenshot.png>` builds, installs and launches on a simulator.
- `scripts/ipa.sh [out.ipa]` builds an unsigned Release IPA. Sign it with a profile for `com.thm.orcaios` (and `com.thm.orcaios.widgets` for the Live Activity extension) that includes Push Notifications.

`packages/OrcaCore` holds the protocol (pairing, E2EE, RPC) and has its own tests: `cd packages/OrcaCore && swift test`.

## Push notifications

The official Orca push service only delivers to the official app. For this app, run the gateway in [`gateway/`](gateway/README.md) with your own APNs key and start the desktop with `ORCA_PUSH_GATEWAY_URL` pointing at it. Without it, everything else works, and notifications and Live Activities update only while the app is open.

## Regenerating resources

- Bot templates: `node scripts/generate-bot-templates.mjs <path to orca>` (uses the gateway's esbuild).
- Strings: `node scripts/generate-strings.mjs <path to orca/mobile>`; strings the official app doesn't have live in `scripts/strings-extra.json`.
- Icons: `node scripts/generate-lucide-icons.mjs <path to orca/mobile> <lucide-react-native icons dir>`.

Design notes are in `docs/design/`, protocol notes in `docs/protocol/`.
