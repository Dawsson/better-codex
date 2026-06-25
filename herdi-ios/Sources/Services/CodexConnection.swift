import Foundation
import Observation

@Observable
final class CodexConnection {
    static let defaultServerURL = "ws://100.108.73.69:8876"
    static let defaultCwd = "/Users/dawson/projects/hosting-platform"

    var threads: [CodexThreadSummary] = []
    var selectedThread: CodexThreadSummary?
    var entries: [CodexEntry] = []
    var connectionState: ConnectionState = .disconnected
    var serverURL: String
    var bearerToken: String
    var cwd: String
    var lastError: String?
    var pendingInput: PendingCodexInput?
    var inputAnswer = ""
    var isWorking = false
    var isLoadingThreads = false
    var isLoadingThread = false

    var isConnected: Bool { connectionState == .connected }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var nextRequestId = 1
    private var requestKinds: [Int: String] = [:]
    private var activeThreadId: String?
    private var activeTurnId: String?
    private var entriesByItemId: [String: CodexEntry] = [:]
    private var loadingAgentIds: Set<String> = []
    private var loadingAgentsById: [String: CodexThreadSummary] = [:]
    private var freshThreadIds: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: "codex_server_url") ?? Self.defaultServerURL
        bearerToken = defaults.string(forKey: "codex_bearer_token") ?? ""
        cwd = defaults.string(forKey: "codex_cwd") ?? Self.defaultCwd
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: "codex_server_url")
        defaults.set(bearerToken, forKey: "codex_bearer_token")
        defaults.set(cwd, forKey: "codex_cwd")
    }

    func connect() {
        guard let url = URL(string: serverURL) else {
            lastError = "Invalid Codex server URL"
            return
        }

        saveSettings()
        disconnect(keepState: true)
        lastError = nil
        connectionState = .connecting

        var request = URLRequest(url: url)
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        task = session.webSocketTask(with: request)
        task?.resume()
        receive()
        initialize()
    }

    func disconnect(keepState: Bool = false) {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        activeTurnId = nil
        pendingInput = nil
        isWorking = false
        isLoadingThreads = false
        isLoadingThread = false
        connectionState = .disconnected
        requestKinds.removeAll()
        loadingAgentIds.removeAll()
        loadingAgentsById.removeAll()
        freshThreadIds.removeAll()
        if !keepState {
            threads.removeAll()
            selectedThread = nil
            activeThreadId = nil
            entries.removeAll()
            entriesByItemId.removeAll()
        }
    }

    func refreshThreads() {
        guard isConnected else { return }
        isLoadingThreads = true
        loadingAgentIds.removeAll()
        loadingAgentsById.removeAll()
        sendRequest(
            method: "thread/loaded/list",
            params: ["limit": 80],
            kind: "thread/loaded/list"
        )
    }

    func startNewThread() {
        guard isConnected else { return }
        let params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "threadSource": "better-codex-ios"
        ]
        sendRequest(method: "thread/start", params: params, kind: "thread/start:new")
    }

    func openThread(_ thread: CodexThreadSummary) {
        if freshThreadIds.contains(thread.id) {
            selectFreshThread(thread)
            return
        }

        selectedThread = thread
        activeThreadId = thread.id
        entries.removeAll()
        entriesByItemId.removeAll()
        isLoadingThread = true
        pendingInput = nil
        sendRequest(
            method: "thread/read",
            params: ["threadId": thread.id, "includeTurns": true],
            kind: "thread/read:\(thread.id)"
        )
        sendRequest(
            method: "thread/resume",
            params: [
                "threadId": thread.id,
                "cwd": cwd,
                "approvalPolicy": "never",
                "sandbox": "danger-full-access"
            ],
            kind: "thread/resume:\(thread.id)"
        )
    }

    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let threadId = activeThreadId else {
            append(.error, title: "Not ready", text: "Open or create a Codex session first.")
            return
        }

        HapticManager.shared.sent()
        freshThreadIds.remove(threadId)
        append(.user, title: "You", text: trimmed)

        let params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": trimmed, "text_elements": []]],
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "dangerFullAccess"]
        ]
        sendRequest(method: "turn/start", params: params, kind: "turn/start")
    }

    func answerPendingInput(_ answer: String) {
        guard let pendingInput else { return }
        let payload: [String: Any] = [
            "answers": [
                pendingInput.questionId: ["type": "text", "text": answer]
            ]
        ]
        sendResponse(id: pendingInput.id, result: payload)
        append(.user, title: "Input", text: answer)
        self.pendingInput = nil
        inputAnswer = ""
    }

    private func initialize() {
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "better_codex_ios",
                    "title": "Better Codex iOS",
                    "version": "0.1.0"
                ],
                "capabilities": ["experimentalApi": true]
            ],
            kind: "initialize"
        )
        sendNotification(method: "initialized", params: [:])
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    self.handle(String(data: data, encoding: .utf8) ?? "")
                @unknown default:
                    break
                }
                self.receive()
            case .failure(let error):
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.connectionState = .disconnected
                    self.isWorking = false
                    self.isLoadingThreads = false
                    self.isLoadingThread = false
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        DispatchQueue.main.async {
            if let id = message["id"] as? Int {
                self.handleResponse(id: id, message: message)
                return
            }
            if let method = message["method"] as? String {
                if message["id"] != nil {
                    self.handleServerRequest(method: method, message: message)
                } else {
                    self.handleNotification(method: method, params: message["params"] as? [String: Any] ?? [:])
                }
            }
        }
    }

    private func handleResponse(id: Int, message: [String: Any]) {
        let kind = requestKinds.removeValue(forKey: id)

        if let error = message["error"] as? [String: Any] {
            let errorMessage = error["message"] as? String ?? "Codex request failed"
            if recoverFreshThreadError(kind: kind, message: errorMessage) {
                return
            }

            lastError = errorMessage
            append(.error, title: "Error", text: lastError ?? "Codex request failed")
            if kind == "thread/loaded/list" { isLoadingThreads = false }
            if kind?.hasPrefix("thread/read:list:") == true {
                let threadId = String(kind?.dropFirst("thread/read:list:".count) ?? "")
                finishLoadingAgent(threadId)
            }
            if kind?.hasPrefix("thread/read:") == true { isLoadingThread = false }
            return
        }

        guard let result = message["result"] as? [String: Any] else { return }

        switch kind {
        case "initialize":
            connectionState = .connected
            refreshThreads()

        case "thread/loaded/list":
            let ids = result["data"] as? [String] ?? []
            guard !ids.isEmpty else {
                threads = []
                isLoadingThreads = false
                return
            }
            loadingAgentIds = Set(ids)
            loadingAgentsById.removeAll()
            for threadId in ids {
                sendRequest(
                    method: "thread/read",
                    params: ["threadId": threadId, "includeTurns": false],
                    kind: "thread/read:list:\(threadId)"
                )
            }

        case "thread/start:new":
            guard let thread = result["thread"] as? [String: Any],
                  let summary = CodexThreadSummary(json: thread) else { return }
            if !threads.contains(where: { $0.id == summary.id }) {
                threads.insert(summary, at: 0)
            }
            freshThreadIds.insert(summary.id)
            selectFreshThread(summary)

        default:
            if kind?.hasPrefix("thread/read:list:") == true,
               let thread = result["thread"] as? [String: Any],
               let summary = CodexThreadSummary(json: thread) {
                loadingAgentsById[summary.id] = summary
                finishLoadingAgent(summary.id)
            } else if kind?.hasPrefix("thread/read:") == true,
               let thread = result["thread"] as? [String: Any] {
                loadHistory(from: thread)
                isLoadingThread = false
            } else if kind?.hasPrefix("thread/resume:") == true,
                      let thread = result["thread"] as? [String: Any],
                      let summary = CodexThreadSummary(json: thread) {
                selectedThread = summary
                activeThreadId = summary.id
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let summary = CodexThreadSummary(json: thread),
               !threads.contains(where: { $0.id == summary.id }) {
                threads.insert(summary, at: 0)
            }

        case "thread/status/changed":
            guard let threadId = params["threadId"] as? String else { return }
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].status = CodexThreadSummary.status(params["status"])
            } else {
                refreshThreads()
            }

        case "thread/closed", "thread/deleted", "thread/archived":
            guard let threadId = params["threadId"] as? String else { return }
            threads.removeAll { $0.id == threadId }

        case "thread/unarchived":
            refreshThreads()

        case "turn/started":
            isWorking = true
            if let threadId = params["threadId"] as? String {
                activeThreadId = threadId
                touchThread(threadId)
            }
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                activeTurnId = id
            }
            append(.status, title: "Turn started", text: "")

        case "turn/completed":
            isWorking = false
            activeTurnId = nil
            append(.status, title: "Done", text: "")
            refreshThreads()

        case "item/started":
            if belongsToActiveThread(params), let item = params["item"] as? [String: Any] {
                upsertItem(item, completed: false)
            }

        case "item/completed":
            if belongsToActiveThread(params), let item = params["item"] as? [String: Any] {
                upsertItem(item, completed: true)
            }

        case "item/agentMessage/delta":
            guard belongsToActiveThread(params),
                  let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return }
            let entry = entriesByItemId[itemId] ?? append(.assistant, title: "Codex", text: "", itemId: itemId)
            entry.text += delta

        case "item/commandExecution/outputDelta":
            guard belongsToActiveThread(params),
                  let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return }
            let entry = entriesByItemId["output-\(itemId)"] ?? append(.output, title: "Output", text: "", itemId: "output-\(itemId)")
            entry.text += delta

        case "warning", "guardianWarning", "configWarning", "error":
            append(.error, title: method, text: String(describing: params))

        default:
            break
        }
    }

    private func handleServerRequest(method: String, message: [String: Any]) {
        guard let id = message["id"] as? Int else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "item/tool/requestUserInput":
            let questions = params["questions"] as? [[String: Any]] ?? []
            let first = questions.first ?? [:]
            let questionId = first["id"] as? String ?? "answer"
            let prompt = first["question"] as? String ?? "Codex needs input."
            pendingInput = PendingCodexInput(id: id, questionId: questionId, prompt: prompt)
            HapticManager.shared.blocked()

        case "item/commandExecution/requestApproval":
            sendResponse(id: id, result: ["decision": "accept"])

        case "item/fileChange/requestApproval", "item/permissions/requestApproval":
            sendResponse(id: id, result: ["decision": "accept"])

        default:
            sendError(id: id, code: -32601, message: "Unsupported request: \(method)")
        }
    }

    private func loadHistory(from thread: [String: Any]) {
        entries.removeAll()
        entriesByItemId.removeAll()
        let turns = thread["turns"] as? [[String: Any]] ?? []
        for turn in turns {
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                upsertItem(item, completed: true)
            }
        }
        if entries.isEmpty {
            append(.status, title: "No transcript", text: "This session has no loaded items yet.")
        }
    }

    private func selectFreshThread(_ thread: CodexThreadSummary) {
        selectedThread = thread
        activeThreadId = thread.id
        entries.removeAll()
        entriesByItemId.removeAll()
        isLoadingThread = false
        pendingInput = nil
    }

    private func recoverFreshThreadError(kind: String?, message: String) -> Bool {
        guard let threadId = threadId(from: kind),
              message.contains("not materialized yet") || message.contains("no rollout found") else {
            return false
        }

        if kind?.hasPrefix("thread/read:list:") == true {
            finishLoadingAgent(threadId)
            return true
        }

        guard let thread = selectedThread?.id == threadId
            ? selectedThread
            : threads.first(where: { $0.id == threadId }) else {
            return false
        }

        freshThreadIds.insert(threadId)
        selectFreshThread(thread)
        lastError = nil
        return true
    }

    private func threadId(from kind: String?) -> String? {
        guard let kind else { return nil }
        for prefix in ["thread/read:list:", "thread/read:", "thread/resume:"] {
            if kind.hasPrefix(prefix) {
                return String(kind.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private func upsertItem(_ item: [String: Any], completed: Bool) {
        guard let type = item["type"] as? String,
              let id = item["id"] as? String else { return }

        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { input -> String? in
                guard input["type"] as? String == "text" else { return nil }
                return input["text"] as? String
            }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            let entry = entriesByItemId[id] ?? append(.user, title: "You", text: "", itemId: id)
            entry.text = text

        case "agentMessage":
            let text = item["text"] as? String ?? ""
            let entry = entriesByItemId[id] ?? append(.assistant, title: "Codex", text: "", itemId: id)
            if !text.isEmpty { entry.text = text }

        case "commandExecution":
            let command = item["command"] as? String ?? ""
            let status = item["status"].map { String(describing: $0) } ?? (completed ? "completed" : "running")
            let entry = entriesByItemId[id] ?? append(.command, title: "Command", text: command, itemId: id)
            entry.title = "Command \(status)"
            if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                let outputEntry = entriesByItemId["output-\(id)"] ?? append(.output, title: "Output", text: "", itemId: "output-\(id)")
                outputEntry.text = output
            }

        case "plan":
            let text = item["text"] as? String ?? ""
            let entry = entriesByItemId[id] ?? append(.assistant, title: "Plan", text: "", itemId: id)
            entry.text = text

        case "reasoning":
            if let summary = item["summary"] as? [String], !summary.isEmpty {
                let entry = entriesByItemId[id] ?? append(.status, title: "Reasoning", text: "", itemId: id)
                entry.text = summary.joined(separator: "\n")
            }

        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            let status = item["status"].map { String(describing: $0) } ?? ""
            let entry = entriesByItemId[id] ?? append(.command, title: server, text: tool, itemId: id)
            entry.text = "\(tool)\n\(status)"

        default:
            break
        }
    }

    private func belongsToActiveThread(_ params: [String: Any]) -> Bool {
        guard let threadId = params["threadId"] as? String else { return true }
        return activeThreadId == nil || activeThreadId == threadId
    }

    private func touchThread(_ threadId: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].status = "active"
        let thread = threads.remove(at: index)
        threads.insert(thread, at: 0)
    }

    private func finishLoadingAgent(_ threadId: String) {
        loadingAgentIds.remove(threadId)
        guard loadingAgentIds.isEmpty else { return }
        threads = loadingAgentsById.values.sorted { $0.updatedAt > $1.updatedAt }
        loadingAgentsById.removeAll()
        isLoadingThreads = false
    }

    @discardableResult
    private func append(_ kind: CodexEntryKind, title: String, text: String, itemId: String? = nil) -> CodexEntry {
        let entry = CodexEntry(kind: kind, title: title, text: text)
        entries.append(entry)
        if let itemId {
            entriesByItemId[itemId] = entry
        }
        return entry
    }

    private func sendRequest(method: String, params: [String: Any], kind: String) {
        let id = nextRequestId
        nextRequestId += 1
        requestKinds[id] = kind
        send(["id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        send(["method": method, "params": params])
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        send(["id": id, "result": result])
    }

    private func sendError(id: Int, code: Int, message: String) {
        send(["id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }
}
