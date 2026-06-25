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

- `ios/` - SwiftUI iOS app.

## Build The iOS App

Open `ios/BetterCodex.xcodeproj` in Xcode, select the `BetterCodex` scheme, and
run it on your device.

## Status

This is pre-release software. The iOS app is the active surface.

## License

No license has been selected yet.
