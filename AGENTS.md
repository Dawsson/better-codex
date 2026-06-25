# Better Codex Agent Instructions

Better Codex is a native client for controlling Codex app-server sessions over
private networks like Tailscale. Keep it focused on Codex workflows.

## Product Direction

- The iOS app should feel like a compact Codex mobile client: list sessions,
  open a session, see streamed agent activity, and send follow-up messages.
- Prefer Codex app-server JSON-RPC APIs directly.
- Use Codex terms: threads, turns, items, commands, output, and approvals.
- Default to the Mac-hosted `codex-lb` app-server on Tailscale. Do not expose
  unauthenticated WebSocket listeners.

## iOS

- Use SwiftUI and native iOS navigation patterns.
- Use a thread list as the primary screen and push into a thread detail/chat
  view.
- Keep the mobile UI task-focused: one primary action per screen, comfortable
  touch targets, keyboard-safe composer, and readable command/output blocks.
- Do not store bearer tokens in source. Persist user-entered tokens in local
  app settings until a Keychain helper is added.

## Validation

- Validate app-server changes with an authenticated WebSocket smoke test when
  protocol behavior changes.
- Prefer focused iOS builds and device installs over broad repo checks.
