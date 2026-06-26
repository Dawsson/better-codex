import { Database } from "bun:sqlite";
import type { ServerWebSocket } from "bun";
import { existsSync, readFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

type JsonObject = Record<string, unknown>;
type RpcMessage = JsonObject & {
  id?: number | string;
  method?: string;
  params?: JsonObject;
  result?: unknown;
  error?: unknown;
};

type PendingUpstreamRequest = {
  client?: ClientConnection;
  clientRequestId?: number | string;
  method: string;
  params: JsonObject;
  internal?: boolean;
  bridgeResume?: {
    threadId: string;
  };
};

type TranscriptEntry = {
  id: string;
  kind: "user" | "assistant" | "command" | "exploration" | "output" | "status" | "error" | "tool" | "diff";
  title: string;
  text: string;
  detail?: string;
};

type ClientConnection = {
  id: number;
  socket: ServerWebSocket<ClientConnection>;
  pending: Map<number | string, { method: string; params: JsonObject }>;
  threadIds: Set<string>;
};

const env = Bun.env;
const listenHost = env.BETTER_CODEX_BRIDGE_HOST ?? "0.0.0.0";
const listenPort = Number(env.BETTER_CODEX_BRIDGE_PORT ?? "8877");
const upstreamUrl = env.CODEX_APP_SERVER_URL ?? "ws://127.0.0.1:8876";
const upstreamToken =
  env.CODEX_APP_SERVER_TOKEN ??
  readOptional(env.CODEX_APP_SERVER_TOKEN_FILE ?? `${env.HOME}/.codex/cxlb-mobile-app-server.token`);
const bridgeToken = env.BETTER_CODEX_BRIDGE_TOKEN ?? upstreamToken;
const ttlMs = Number(env.BETTER_CODEX_BRIDGE_TTL_MS ?? 6 * 60 * 60 * 1000);
const dbPath = env.BETTER_CODEX_BRIDGE_DB ?? `${env.HOME}/.better-codex/bridge.sqlite`;
const transcriptHeadEntries = Number(env.BETTER_CODEX_TRANSCRIPT_HEAD_ENTRIES ?? 40);
const transcriptTailEntries = Number(env.BETTER_CODEX_TRANSCRIPT_TAIL_ENTRIES ?? 420);
const transcriptMaxTextChars = Number(env.BETTER_CODEX_TRANSCRIPT_MAX_TEXT_CHARS ?? 8_000);
const transcriptMaxDetailChars = Number(env.BETTER_CODEX_TRANSCRIPT_MAX_DETAIL_CHARS ?? 2_500);

if (!upstreamToken) {
  throw new Error("Missing CODEX_APP_SERVER_TOKEN or CODEX_APP_SERVER_TOKEN_FILE");
}
if (!bridgeToken) {
  throw new Error("Missing BETTER_CODEX_BRIDGE_TOKEN");
}

mkdirSync(dirname(dbPath), { recursive: true });
const db = new Database(dbPath);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT NOT NULL,
    turn_id TEXT,
    method TEXT NOT NULL,
    params_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS events_thread_id_id ON events(thread_id, id);
  CREATE INDEX IF NOT EXISTS events_created_at_ms ON events(created_at_ms);
  CREATE TABLE IF NOT EXISTS subscriptions (
    thread_id TEXT PRIMARY KEY,
    cwd TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    updated_at_ms INTEGER NOT NULL
  );
`);

const insertEvent = db.query(`
  INSERT INTO events (thread_id, turn_id, method, params_json, created_at_ms)
  VALUES ($threadId, $turnId, $method, $paramsJson, $createdAtMs)
`);
const deleteOldEvents = db.query("DELETE FROM events WHERE created_at_ms < $cutoff");
const upsertSubscription = db.query(`
  INSERT INTO subscriptions (thread_id, cwd, status, updated_at_ms)
  VALUES ($threadId, $cwd, $status, $updatedAtMs)
  ON CONFLICT(thread_id) DO UPDATE SET
    cwd = excluded.cwd,
    status = excluded.status,
    updated_at_ms = excluded.updated_at_ms
`);
const activeSubscriptions = db.query("SELECT thread_id, cwd FROM subscriptions WHERE status = 'active'");
let nextClientId = 1;
let nextUpstreamId = 1;
let upstream: WebSocket | undefined;
let upstreamReady = false;
let reconnectTimer: Timer | undefined;
const clients = new Set<ClientConnection>();
const upstreamPending = new Map<number, PendingUpstreamRequest>();
const subscribedThreads = new Map<string, string>();

function readOptional(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8").trim() : "";
}

function now() {
  return Date.now();
}

function parseJson(data: string | Buffer): RpcMessage | undefined {
  try {
    return JSON.parse(data.toString()) as RpcMessage;
  } catch {
    return undefined;
  }
}

function send(socket: WebSocket | ServerWebSocket<ClientConnection>, message: RpcMessage) {
  socket.send(JSON.stringify(message));
}

function sendUpstream(method: string, params: JsonObject = {}, pending: Omit<PendingUpstreamRequest, "method" | "params"> = {}) {
  if (!upstream || upstream.readyState !== WebSocket.OPEN) {
    throw new Error("Upstream Codex app-server is not connected");
  }
  const id = nextUpstreamId++;
  upstreamPending.set(id, { method, params, ...pending });
  send(upstream, { id, method, params });
  return id;
}

function connectUpstream() {
  if (upstream && (upstream.readyState === WebSocket.CONNECTING || upstream.readyState === WebSocket.OPEN)) {
    return;
  }

  upstreamReady = false;
  upstream = new (WebSocket as unknown as {
    new (url: string, init: { headers: Record<string, string> }): WebSocket;
  })(upstreamUrl, {
    headers: { Authorization: `Bearer ${upstreamToken}` },
  });

  upstream.addEventListener("open", () => {
    sendUpstream(
      "initialize",
      {
        clientInfo: {
          name: "better_codex_bridge",
          title: "Better Codex Bridge",
          version: "0.1.0",
        },
        capabilities: {
          experimentalApi: true,
          requestAttestation: false,
        },
      },
      { internal: true },
    );
    send(upstream!, { method: "initialized", params: {} });
  });

  upstream.addEventListener("message", (event) => {
    const message = parseJson(event.data);
    if (!message) return;
    handleUpstreamMessage(message);
  });

  upstream.addEventListener("close", scheduleReconnect);
  upstream.addEventListener("error", scheduleReconnect);
}

function scheduleReconnect() {
  upstreamReady = false;
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    connectUpstream();
  }, 1_000);
}

function handleUpstreamMessage(message: RpcMessage) {
  if (message.id != null) {
    const pending = upstreamPending.get(Number(message.id));
    upstreamPending.delete(Number(message.id));
    if (!pending) return;
    if (pending.internal) {
      handleInternalResponse(pending, message);
      return;
    }
    if (pending.bridgeResume && pending.client) {
      handleBridgeResumeResponse(pending, message);
      return;
    }
    if (pending.client) {
      send(pending.client.socket, {
        ...message,
        id: pending.clientRequestId,
      });
    }
    return;
  }

  if (message.method) {
    storeNotification(message.method, message.params ?? {});
    for (const client of clients) {
      if (clientShouldReceive(client, message.params ?? {})) {
        send(client.socket, message);
      }
    }
  }
}

function handleBridgeResumeResponse(pending: PendingUpstreamRequest, message: RpcMessage) {
  const client = pending.client;
  if (!client) return;
  if (message.error) {
    if (isMissingRolloutError(message.error)) {
      const threadId = pending.bridgeResume?.threadId;
      if (threadId) {
        upsertSubscription.run({
          $threadId: threadId,
          $cwd: subscribedThreads.get(threadId) ?? "",
          $status: "inactive",
          $updatedAtMs: now(),
        });
        subscribedThreads.delete(threadId);
      }
    }
    send(client.socket, { ...message, id: pending.clientRequestId });
    return;
  }
  const result = isObject(message.result) ? message.result : {};
  const thread = isObject(result.thread) ? result.thread : {};
  const entries = transcriptEntriesForThread(thread);
  send(client.socket, {
    id: pending.clientRequestId,
    result: {
      ...result,
      bridgeTranscript: {
        entries,
        source: stringValue(thread.path) ?? "",
      },
    },
  });
}

function handleInternalResponse(pending: PendingUpstreamRequest, message: RpcMessage) {
  if (pending.method === "initialize") {
    upstreamReady = true;
    resubscribePersistedThreads();
    discoverActiveThreads();
    return;
  }
  if (pending.method === "thread/loaded/list" && isObject(message.result)) {
    const ids = Array.isArray(message.result.data) ? message.result.data.filter((id): id is string => typeof id === "string") : [];
    for (const threadId of ids) {
      sendUpstream("thread/read", { threadId, includeTurns: false }, { internal: true });
    }
    return;
  }
  if (pending.method === "thread/read" && isObject(message.result) && isObject(message.result.thread)) {
    const thread = message.result.thread;
    const threadId = stringValue(thread.id);
    const status = statusType(thread.status);
    const cwd = stringValue(thread.cwd) ?? "";
    if (threadId && status === "active") {
      subscribeThread(threadId, cwd);
    }
  }
}

function discoverActiveThreads() {
  if (!upstreamReady) return;
  sendUpstream("thread/loaded/list", { limit: 100 }, { internal: true });
}

function resubscribePersistedThreads() {
  for (const row of activeSubscriptions.all() as Array<{ thread_id: string; cwd: string }>) {
    subscribeThread(row.thread_id, row.cwd);
  }
}

function subscribeThread(threadId: string, cwd = "") {
  if (!upstreamReady || subscribedThreads.has(threadId)) return;
  subscribedThreads.set(threadId, cwd);
  upsertSubscription.run({
    $threadId: threadId,
    $cwd: cwd,
    $status: "active",
    $updatedAtMs: now(),
  });
  sendUpstream(
    "thread/resume",
    {
      threadId,
      cwd,
      approvalPolicy: "never",
      sandbox: "danger-full-access",
    },
    { internal: true },
  );
}

function storeNotification(method: string, params: JsonObject) {
  const threadId = notificationThreadId(params);
  if (!threadId) return;
  const turnId = notificationTurnId(params);
  insertEvent.run({
    $threadId: threadId,
    $turnId: turnId ?? null,
    $method: method,
    $paramsJson: JSON.stringify(params),
    $createdAtMs: now(),
  });
  if (
    method === "turn/completed"
    || method === "thread/deleted"
    || method === "thread/archived"
    || method === "thread/closed"
    || isNotLoadedStatus(method, params)
  ) {
    upsertSubscription.run({
      $threadId: threadId,
      $cwd: subscribedThreads.get(threadId) ?? "",
      $status: method === "turn/completed" ? "idle" : "inactive",
      $updatedAtMs: now(),
    });
    subscribedThreads.delete(threadId);
  }
}

function handleClientMessage(client: ClientConnection, message: RpcMessage) {
  if (!message.method) return;

  if (message.id == null) {
    return;
  }

  if (message.method === "initialize") {
    send(client.socket, {
      id: message.id,
      result: {
        userAgent: "better-codex-bridge",
        codexHome: "",
        platformFamily: "unix",
        platformOs: "macos",
        bridge: true,
      },
    });
    return;
  }

  const params = message.params ?? {};
  client.pending.set(message.id, { method: message.method, params });

  if (message.method === "bridge/thread/resume") {
    const threadId = stringValue(params.threadId);
    const cwd = stringValue(params.cwd) ?? "";
    if (!threadId) {
      send(client.socket, {
        id: message.id,
        error: { code: -32602, message: "Missing threadId" },
      });
      return;
    }
    client.threadIds.add(threadId);
    subscribeThread(threadId, cwd);
    try {
      sendUpstream(
        "thread/resume",
        {
          threadId,
          cwd,
          approvalPolicy: params.approvalPolicy ?? "never",
          sandbox: params.sandbox ?? "danger-full-access",
        },
        { client, clientRequestId: message.id, bridgeResume: { threadId } },
      );
    } catch (error) {
      send(client.socket, {
        id: message.id,
        error: {
          code: -32000,
          message: error instanceof Error ? error.message : "Bridge upstream unavailable",
        },
      });
    }
    return;
  }

  if (message.method === "thread/resume") {
    const threadId = stringValue(params.threadId);
    const cwd = stringValue(params.cwd) ?? "";
    if (threadId) {
      client.threadIds.add(threadId);
      subscribeThread(threadId, cwd);
    }
  }

  try {
    sendUpstream(message.method, params, {
      client,
      clientRequestId: message.id,
    });
  } catch (error) {
    send(client.socket, {
      id: message.id,
      error: {
        code: -32000,
        message: error instanceof Error ? error.message : "Bridge upstream unavailable",
      },
    });
  }
}

function transcriptEntriesForThread(thread: JsonObject): TranscriptEntry[] {
  const path = stringValue(thread.path);
  if (!path || !existsSync(path)) return [];

  const entries: TranscriptEntry[] = [];
  const entriesById = new Map<string, TranscriptEntry>();
  let lineNumber = 0;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    lineNumber += 1;
    if (!line.trim()) continue;
    const record = parseJson(line);
    if (!record || record.type !== "response_item" || !isObject(record.payload)) continue;
    appendResponseItem(entries, entriesById, record.payload, lineNumber);
  }
  return compactTranscriptEntries(entries);
}

function appendResponseItem(entries: TranscriptEntry[], entriesById: Map<string, TranscriptEntry>, item: JsonObject, lineNumber: number) {
  const type = stringValue(item.type);
  if (!type) return;

  if (type === "message") {
    const role = stringValue(item.role) ?? "assistant";
    if (role !== "user" && role !== "assistant") return;
    const text = responseContentText(Array.isArray(item.content) ? item.content : []);
    if (!text || (role === "user" && isInjectedContextMessage(text))) return;
    const id = stringValue(item.id) ?? `jsonl-${lineNumber}-message`;
    upsertEntry(entries, entriesById, id, {
      id,
      kind: role === "user" ? "user" : "assistant",
      title: role === "user" ? "You" : "Codex",
      text,
    });
    return;
  }

  if (type === "function_call") {
    const callId = stringValue(item.call_id);
    if (!callId) return;
    const name = stringValue(item.name) ?? "tool";
    const args = stringValue(item.arguments) ?? "";
    upsertEntry(entries, entriesById, callId, {
      id: callId,
      kind: "command",
      title: "running",
      text: displayBackfillCommand(name, args),
    });
    return;
  }

  if (type === "function_call_output") {
    const callId = stringValue(item.call_id);
    if (!callId) return;
    const output = stringValue(item.output) ?? "";
    const existing = entriesById.get(callId);
    if (existing) {
      existing.title = "completed";
      existing.detail = truncateField(output, transcriptMaxDetailChars);
    } else {
      upsertEntry(entries, entriesById, `output-${callId}`, {
        id: `output-${callId}`,
        kind: "output",
        title: "Output",
        text: output,
      });
    }
    return;
  }

  if (type === "custom_tool_call") {
    const callId = stringValue(item.call_id);
    if (!callId) return;
    const name = stringValue(item.name) ?? "tool";
    const input = stringValue(item.input) ?? "";
    upsertEntry(entries, entriesById, callId, {
      id: callId,
      kind: name === "apply_patch" ? "diff" : "tool",
      title: name === "apply_patch" ? "Patch" : name,
      text: name === "apply_patch" ? "Applied patch" : input,
      detail: name === "apply_patch" ? input : "",
    });
    return;
  }

  if (type === "custom_tool_call_output") {
    const callId = stringValue(item.call_id);
    if (!callId) return;
    const existing = entriesById.get(callId);
    const output = stringValue(item.output) ?? "";
    if (existing && output) existing.detail = truncateField(output, transcriptMaxDetailChars);
    return;
  }

  if (type === "reasoning") {
    const id = stringValue(item.id);
    if (!id) return;
    const summary = Array.isArray(item.summary)
      ? item.summary.map((part) => isObject(part) ? stringValue(part.text) ?? "" : "").filter(Boolean).join("\n")
      : "";
    if (!summary) return;
    upsertEntry(entries, entriesById, id, {
      id,
      kind: "status",
      title: "Reasoning",
      text: summary,
    });
  }
}

function upsertEntry(entries: TranscriptEntry[], entriesById: Map<string, TranscriptEntry>, id: string, next: TranscriptEntry) {
  next.text = truncateField(next.text, transcriptMaxTextChars);
  if (next.detail) {
    next.detail = truncateField(next.detail, transcriptMaxDetailChars);
  }
  const existing = entriesById.get(id);
  if (existing) {
    Object.assign(existing, next);
    return existing;
  }
  entriesById.set(id, next);
  entries.push(next);
  return next;
}

function compactTranscriptEntries(entries: TranscriptEntry[]) {
  const maxEntries = transcriptHeadEntries + transcriptTailEntries;
  if (entries.length <= maxEntries) return entries;

  const head = entries.slice(0, transcriptHeadEntries);
  const tail = entries.slice(-transcriptTailEntries);
  const omitted = entries.length - head.length - tail.length;
  return [
    ...head,
    {
      id: `bridge-omitted-${omitted}`,
      kind: "status",
      title: "Transcript compacted",
      text: `Skipped ${omitted.toLocaleString()} older items. Showing the beginning and the latest activity.`,
    } satisfies TranscriptEntry,
    ...tail,
  ];
}

function truncateField(value: string, maxChars: number) {
  if (value.length <= maxChars) return value;
  return `${value.slice(0, maxChars)}\n\n[truncated ${value.length - maxChars} characters by Better Codex bridge]`;
}

function responseContentText(content: unknown[]) {
  return content
    .map((part) => isObject(part) && ["output_text", "input_text", "text"].includes(String(part.type)) ? stringValue(part.text) ?? "" : "")
    .filter(Boolean)
    .join("\n");
}

function isInjectedContextMessage(text: string) {
  const trimmed = text.trim();
  return trimmed.startsWith("# AGENTS.md instructions")
    || trimmed.startsWith("<INSTRUCTIONS>")
    || trimmed.startsWith("<environment_context>");
}

function displayBackfillCommand(name: string, args: string) {
  const normalizedName = name.split(".").at(-1) ?? name;
  if (normalizedName !== "exec_command") return args ? `${name} ${args}` : name;
  try {
    const parsed = JSON.parse(args) as { cmd?: unknown };
    return typeof parsed.cmd === "string" ? displayCommand(parsed.cmd) : name;
  } catch {
    return name;
  }
}

function displayCommand(command: string) {
  return command.trim().replace(/\s+/g, " ");
}

function authorized(request: Request) {
  const header = request.headers.get("authorization") ?? "";
  return header === `Bearer ${bridgeToken}`;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function statusType(value: unknown): string {
  if (typeof value === "string") return value;
  if (isObject(value) && typeof value.type === "string") return value.type;
  return "unknown";
}

function isMissingRolloutError(error: unknown) {
  if (!isObject(error)) return false;
  const message = stringValue(error.message) ?? "";
  return message.includes("no rollout found") || message.includes("not materialized yet");
}

function notificationThreadId(params: JsonObject) {
  return stringValue(params.threadId)
    ?? (isObject(params.thread) ? stringValue(params.thread.id) : undefined)
    ?? (isObject(params.turn) ? stringValue(params.turn.threadId) : undefined)
    ?? (isObject(params.item) ? stringValue(params.item.threadId) : undefined);
}

function notificationTurnId(params: JsonObject) {
  return stringValue(params.turnId)
    ?? (isObject(params.turn) ? stringValue(params.turn.id) : undefined)
    ?? (isObject(params.item) ? stringValue(params.item.turnId) : undefined);
}

function clientShouldReceive(client: ClientConnection, params: JsonObject) {
  const threadId = notificationThreadId(params);
  return !threadId || client.threadIds.has(threadId);
}

function isNotLoadedStatus(method: string, params: JsonObject) {
  if (method !== "thread/status/changed") return false;
  return statusType(params.status) === "notLoaded";
}

setInterval(() => {
  deleteOldEvents.run({ $cutoff: now() - ttlMs });
  discoverActiveThreads();
}, 60_000);

connectUpstream();

const server = Bun.serve<ClientConnection>({
  hostname: listenHost,
  port: listenPort,
  fetch(request, server) {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") {
      return Response.json({
        ok: true,
        upstreamReady,
        clients: clients.size,
        subscribedThreads: subscribedThreads.size,
        ttlMs,
      });
    }
    if (!authorized(request)) {
      return new Response("unauthorized", { status: 401 });
    }
    if (server.upgrade(request, { data: undefined as unknown as ClientConnection })) {
      return undefined;
    }
    return new Response("Better Codex bridge", { status: 200 });
  },
  websocket: {
    open(socket) {
      const client: ClientConnection = {
        id: nextClientId++,
        socket,
        pending: new Map(),
        threadIds: new Set(),
      };
      socket.data = client;
      clients.add(client);
    },
    message(socket, data) {
      const message = parseJson(typeof data === "string" ? data : Buffer.from(data));
      if (message) handleClientMessage(socket.data, message);
    },
    close(socket) {
      clients.delete(socket.data);
    },
  },
});

console.log(`Better Codex bridge listening on ws://${server.hostname}:${server.port}`);
console.log(`Upstream Codex app-server: ${upstreamUrl}`);
