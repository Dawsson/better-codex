# Better Codex Bridge

The bridge is a protocol-compatible WebSocket proxy for Codex app-server. It
keeps persistent subscriptions open for active threads, stores live events in
SQLite for diagnostics/TTL retention, and lets mobile clients fetch current
thread history directly from Codex app-server before receiving live updates.

## Run

```sh
CODEX_APP_SERVER_TOKEN_FILE="$HOME/.codex/cxlb-mobile-app-server.token" \
BETTER_CODEX_BRIDGE_PORT=8877 \
bun run bridge
```

By default it writes SQLite state to:

```sh
$HOME/.better-codex/bridge.sqlite
```

## Environment

- `CODEX_APP_SERVER_URL`: upstream Codex app-server URL. Defaults to
  `ws://127.0.0.1:8876`.
- `CODEX_APP_SERVER_TOKEN` or `CODEX_APP_SERVER_TOKEN_FILE`: upstream auth.
- `BETTER_CODEX_BRIDGE_TOKEN`: mobile auth token. Defaults to the upstream token.
- `BETTER_CODEX_BRIDGE_TTL_MS`: event retention. Defaults to six hours.
- `BETTER_CODEX_BRIDGE_DB`: SQLite path.
- `BETTER_CODEX_BRIDGE_HOST`: listen host. Defaults to `0.0.0.0`.
- `BETTER_CODEX_BRIDGE_PORT`: listen port. Defaults to `8877`.
