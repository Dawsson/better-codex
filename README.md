# Better Codex

Better Codex is a small native client for working with Codex agents from an
iPhone or Mac. It connects to a Codex app-server over your private network,
shows open agents, streams the chat transcript, and lets you send follow-up
messages without jumping back to a terminal.

This is an early personal tool, but the goal is simple: make remote Codex
sessions feel calm, readable, and useful on mobile.

## What It Does

- Lists open Codex agents with status, branch, and local work signals.
- Opens an agent into a chat-like transcript.
- Formats assistant Markdown, command runs, read/search exploration, and output
  previews for small screens.
- Sends new messages back to the active Codex session.
- Works best over Tailscale with a Mac-hosted Codex app-server.

## Layout

- `herdi-ios/` - SwiftUI iOS app.
- `herdi-mac/` - macOS menu bar app experiments.
- `relay/` and `web/` - older relay/web surfaces kept while the project moves
  toward direct Codex app-server support.

## Build The iOS App

Open `herdi-ios/Herdi.xcodeproj` in Xcode, select the `Herdi` scheme, and run it
on your device.

For CLI builds against an iOS beta device:

```sh
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" \
  xcodebuild -scheme Herdi \
  -project herdi-ios/Herdi.xcodeproj \
  -configuration Debug \
  -destination 'platform=iOS' \
  build
```

## Status

This is pre-release software. The iOS app is the active surface; older Herdr
relay pieces are still present but are no longer the main direction.

## License

No license has been selected yet.
