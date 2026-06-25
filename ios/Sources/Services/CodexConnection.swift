import Foundation
import Observation

private struct PendingImageTurn {
    let threadId: String
    let text: String
    let images: [CodexImageAttachment]
    var remainingImageIds: Set<String>
    var localPathsByImageId: [String: String] = [:]
}

private struct PendingImageUpload {
    let uploadTurnId: String
    let imageId: String
    let path: String
}

@Observable
final class CodexConnection {
    static let defaultServerURL = "ws://100.108.73.69:8876"
    static let defaultCwd = "/Users/dawson/projects/hosting-platform"
    private static let cachedThreadsKey = "codex_cached_threads"
    private static let hiddenThreadIdsKey = "codex_hidden_thread_ids"

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
    var transcriptRevision = 0

    var isConnected: Bool { connectionState == .connected }
    var workingStartedAt: Date? { activeTurnStartedAt }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var nextRequestId = 1
    private var requestKinds: [Int: String] = [:]
    private var activeThreadId: String?
    private var activeTurnId: String?
    private var activeTurnStartedAt: Date?
    private var entriesByItemId: [String: CodexEntry] = [:]
    private var activeExplorationEntry: CodexEntry?
    private var explorationItemIds: Set<String> = []
    private var explorationLabelsByItemId: [String: String] = [:]
    private var explorationItemOrder: [String] = []
    private var loadingAgentIds: Set<String> = []
    private var loadingAgentsById: [String: CodexThreadSummary] = [:]
    private var loadingAgentOrder: [String] = []
    private var freshThreadIds: Set<String> = []
    private var hiddenThreadIds: Set<String> = []
    private var pendingImageTurns: [String: PendingImageTurn] = [:]
    private var pendingImageUploads: [Int: PendingImageUpload] = [:]
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var shouldAutoReconnect = false

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: "codex_server_url") ?? Self.defaultServerURL
        bearerToken = defaults.string(forKey: "codex_bearer_token") ?? ""
        cwd = defaults.string(forKey: "codex_cwd") ?? Self.defaultCwd
        hiddenThreadIds = Self.loadHiddenThreadIds(from: defaults)
        threads = Self.loadCachedThreads(from: defaults)
            .filter { !hiddenThreadIds.contains($0.id) }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: "codex_server_url")
        defaults.set(bearerToken, forKey: "codex_bearer_token")
        defaults.set(cwd, forKey: "codex_cwd")
    }

    func configure(from url: URL) {
        guard url.scheme == "bettercodex", url.host == "configure" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let values = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )

        if let server = values["server"], URL(string: server) != nil {
            serverURL = server
        }
        if let token = values["token"], !token.isEmpty {
            bearerToken = token
        }
        if let configuredCwd = values["cwd"], !configuredCwd.isEmpty {
            cwd = configuredCwd
        }

        saveSettings()
        connect()
    }

    func connect() {
        guard let url = URL(string: serverURL) else {
            lastError = "Invalid Codex server URL"
            return
        }

        saveSettings()
        closeSocket()
        shouldAutoReconnect = true
        lastError = nil
        connectionState = .connecting

        var request = URLRequest(url: url)
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        task = session.webSocketTask(with: request)
        task?.resume()
        receive(on: task)
        initialize()
    }

    func disconnect(keepState: Bool = false) {
        shouldAutoReconnect = false
        closeSocket()
        activeTurnId = nil
        activeTurnStartedAt = nil
        pendingInput = nil
        isWorking = false
        isLoadingThreads = false
        isLoadingThread = false
        connectionState = .disconnected
        requestKinds.removeAll()
        pendingImageTurns.removeAll()
        pendingImageUploads.removeAll()
        loadingAgentIds.removeAll()
        loadingAgentsById.removeAll()
        loadingAgentOrder.removeAll()
        freshThreadIds.removeAll()
        if !keepState {
            selectedThread = nil
            activeThreadId = nil
            entries.removeAll()
            entriesByItemId.removeAll()
            resetExplorationState()
            transcriptRevision += 1
        }
    }

    func reconnectIfNeeded() {
        if connectionState == .disconnected, !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connect()
        }
    }

    func refreshThreads() {
        guard isConnected else { return }
        isLoadingThreads = true
        loadingAgentIds.removeAll()
        loadingAgentsById.removeAll()
        loadingAgentOrder.removeAll()
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

    func renameThread(_ thread: CodexThreadSummary, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index].title = trimmed
            saveCachedThreads()
        }
        sendRequest(
            method: "thread/name/set",
            params: ["threadId": thread.id, "name": trimmed],
            kind: "thread/name/set:\(thread.id)"
        )
    }

    func deleteThread(_ thread: CodexThreadSummary) {
        guard isConnected else { return }
        hiddenThreadIds.insert(thread.id)
        threads.removeAll { $0.id == thread.id }
        freshThreadIds.remove(thread.id)
        if selectedThread?.id == thread.id {
            selectedThread = nil
            activeThreadId = nil
            entries.removeAll()
            entriesByItemId.removeAll()
            resetExplorationState()
            transcriptRevision += 1
        }
        saveHiddenThreadIds()
        saveCachedThreads()
        sendRequest(
            method: "thread/delete",
            params: ["threadId": thread.id],
            kind: "thread/delete:\(thread.id)"
        )
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
        resetExplorationState()
        transcriptRevision += 1
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

    func sendPrompt(_ text: String, images: [CodexImageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        guard let threadId = activeThreadId else {
            append(.error, title: "Not ready", text: "Open or create a Codex session first.")
            return
        }

        HapticManager.shared.sent()
        freshThreadIds.remove(threadId)
        append(.user, title: "You", text: trimmed, images: images)

        let uploadableImages = images.filter { $0.dataBase64 != nil }
        guard !uploadableImages.isEmpty else {
            startTurn(threadId: threadId, text: trimmed, images: images)
            return
        }

        let uploadTurnId = UUID().uuidString
        pendingImageTurns[uploadTurnId] = PendingImageTurn(
            threadId: threadId,
            text: trimmed,
            images: images,
            remainingImageIds: Set(uploadableImages.map(\.id))
        )

        for image in uploadableImages {
            guard let dataBase64 = image.dataBase64 else { continue }
            let path = "/tmp/better-codex-\(image.id).jpg"
            let requestId = nextRequestId
            pendingImageUploads[requestId] = PendingImageUpload(
                uploadTurnId: uploadTurnId,
                imageId: image.id,
                path: path
            )
            sendRequest(
                method: "fs/writeFile",
                params: [
                    "path": path,
                    "dataBase64": dataBase64
                ],
                kind: "fs/writeFile:image"
            )
        }
    }

    private func startTurn(threadId: String, text: String, images: [CodexImageAttachment]) {
        var input: [[String: Any]] = []
        if !text.isEmpty {
            input.append(["type": "text", "text": text, "text_elements": []])
        }
        input.append(contentsOf: images.compactMap(Self.inputItem))

        let params: [String: Any] = [
            "threadId": threadId,
            "input": input,
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
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false
                ]
            ],
            kind: "initialize"
        )
        sendNotification(method: "initialized", params: [:])
    }

    private func receive(on socket: URLSessionWebSocketTask?) {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                guard self.task === socket else { return }
                switch message {
                case .string(let text):
                    self.handle(text)
                case .data(let data):
                    self.handle(String(data: data, encoding: .utf8) ?? "")
                @unknown default:
                    break
                }
                self.receive(on: socket)
            case .failure(let error):
                DispatchQueue.main.async {
                    guard self.task === socket else { return }
                    self.lastError = error.localizedDescription
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func closeSocket() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPingLoop()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func scheduleReconnect() {
        stopPingLoop()
        task?.cancel()
        task = nil
        isWorking = false
        isLoadingThreads = false
        isLoadingThread = false
        requestKinds.removeAll()

        guard shouldAutoReconnect else {
            connectionState = .disconnected
            return
        }

        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        let delay = min(Double(1 << min(reconnectAttempt - 1, 5)), 30.0)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.shouldAutoReconnect else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func startPingLoop() {
        stopPingLoop()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self.connectionState == .connected else { continue }
                let socket = self.task
                socket?.sendPing { _ in }
            }
        }
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
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
            if let upload = pendingImageUploads.removeValue(forKey: id) {
                failPendingImageTurn(upload.uploadTurnId, message: errorMessage)
                return
            }
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
            if kind?.hasPrefix("thread/delete:") == true || kind?.hasPrefix("thread/name/set:") == true {
                refreshThreads()
            }
            return
        }

        if let upload = pendingImageUploads.removeValue(forKey: id) {
            finishImageUpload(upload)
            return
        }

        guard let result = message["result"] as? [String: Any] else { return }

        switch kind {
        case "initialize":
            reconnectAttempt = 0
            lastError = nil
            startPingLoop()
            connectionState = .connected
            refreshThreads()

        case "thread/loaded/list":
            let ids = result["data"] as? [String] ?? []
            guard !ids.isEmpty else {
                threads = []
                saveCachedThreads()
                isLoadingThreads = false
                return
            }
            let visibleIds = ids.filter { !hiddenThreadIds.contains($0) }
            guard !visibleIds.isEmpty else {
                threads = []
                saveCachedThreads()
                isLoadingThreads = false
                return
            }
            loadingAgentIds = Set(visibleIds)
            loadingAgentOrder = visibleIds
            loadingAgentsById.removeAll()
            for threadId in visibleIds {
                sendRequest(
                    method: "thread/read",
                    params: ["threadId": threadId, "includeTurns": false],
                    kind: "thread/read:list:\(threadId)"
                )
            }

        case "thread/start:new":
            guard let thread = result["thread"] as? [String: Any],
                  let summary = CodexThreadSummary(json: thread) else { return }
            hiddenThreadIds.remove(summary.id)
            saveHiddenThreadIds()
            if !threads.contains(where: { $0.id == summary.id }) {
                threads.append(summary)
                saveCachedThreads()
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
               !hiddenThreadIds.contains(summary.id),
               !threads.contains(where: { $0.id == summary.id }) {
                threads.append(summary)
                saveCachedThreads()
            }

        case "thread/status/changed":
            guard let threadId = params["threadId"] as? String else { return }
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].status = CodexThreadSummary.status(params["status"])
                saveCachedThreads()
            } else {
                refreshThreads()
            }

        case "thread/name/updated":
            guard let threadId = params["threadId"] as? String else { return }
            let threadName = params["threadName"] as? String
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                let trimmedName = threadName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                threads[index].title = trimmedName.isEmpty ? threads[index].projectName : trimmedName
                saveCachedThreads()
            } else {
                refreshThreads()
            }

        case "thread/closed", "thread/deleted", "thread/archived":
            guard let threadId = params["threadId"] as? String else { return }
            threads.removeAll { $0.id == threadId }
            saveCachedThreads()

        case "thread/unarchived":
            if let threadId = params["threadId"] as? String {
                hiddenThreadIds.remove(threadId)
                saveHiddenThreadIds()
            }
            refreshThreads()

        case "turn/started":
            isWorking = true
            activeTurnStartedAt = Date()
            if let threadId = params["threadId"] as? String {
                activeThreadId = threadId
                updateThreadStatus(threadId, status: "active")
            }
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                activeTurnId = id
            }
            append(.status, title: "Turn started", text: "")

        case "turn/completed":
            isWorking = false
            activeTurnId = nil
            endActiveExplorationGroup()
            if let activeTurnStartedAt {
                append(.status, title: "Worked for \(Self.durationString(from: activeTurnStartedAt, to: Date()))", text: "")
            }
            activeTurnStartedAt = nil
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
            transcriptRevision += 1

        case "item/commandExecution/outputDelta":
            guard belongsToActiveThread(params),
                  let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return }
            if explorationItemIds.contains(itemId) {
                return
            }
            let entry = entriesByItemId["output-\(itemId)"] ?? append(.output, title: "Output", text: "", itemId: "output-\(itemId)")
            if let commandEntry = entriesByItemId[itemId], commandEntry.kind == .command {
                commandEntry.detail += delta
            } else {
                entry.text += delta
            }
            transcriptRevision += 1

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

        case "item/fileChange/requestApproval":
            appendFileChangeRequest(params, requestId: id)
            sendResponse(id: id, result: ["decision": "accept"])

        case "item/permissions/requestApproval":
            sendResponse(id: id, result: ["decision": "accept"])

        default:
            sendError(id: id, code: -32601, message: "Unsupported request: \(method)")
        }
    }

    private func loadHistory(from thread: [String: Any]) {
        entries.removeAll()
        entriesByItemId.removeAll()
        resetExplorationState()
        transcriptRevision += 1
        let turns = thread["turns"] as? [[String: Any]] ?? []
        for turn in turns {
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                upsertItem(item, completed: true)
            }
            endActiveExplorationGroup()
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
        resetExplorationState()
        transcriptRevision += 1
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
            endActiveExplorationGroup()
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { input -> String? in
                guard input["type"] as? String == "text" else { return nil }
                return input["text"] as? String
            }.joined(separator: "\n")
            let images = content.compactMap(Self.imageAttachment)
            guard !text.isEmpty || !images.isEmpty else { return }
            let entry = entriesByItemId[id] ?? append(.user, title: "You", text: "", itemId: id)
            entry.text = text
            entry.images = images
            transcriptRevision += 1

        case "agentMessage":
            endActiveExplorationGroup()
            let text = item["text"] as? String ?? ""
            let entry = entriesByItemId[id] ?? append(.assistant, title: "Codex", text: "", itemId: id)
            if !text.isEmpty { entry.text = text }
            transcriptRevision += 1

        case "commandExecution":
            let command = item["command"] as? String ?? ""
            if let explorationLabel = Self.explorationLabel(for: command) {
                upsertExplorationItem(id: id, label: explorationLabel)
                transcriptRevision += 1
                return
            }

            endActiveExplorationGroup()
            let status = item["status"].map { String(describing: $0) } ?? (completed ? "completed" : "running")
            let entry = entriesByItemId[id] ?? append(.command, title: "Ran", text: Self.displayCommand(for: command), itemId: id)
            entry.title = status
            entry.text = Self.displayCommand(for: command)
            if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                entry.detail = output
            }
            transcriptRevision += 1

        case "plan":
            endActiveExplorationGroup()
            let text = item["text"] as? String ?? ""
            let entry = entriesByItemId[id] ?? append(.assistant, title: "Plan", text: "", itemId: id)
            entry.text = text
            transcriptRevision += 1

        case "reasoning":
            endActiveExplorationGroup()
            if let summary = item["summary"] as? [String], !summary.isEmpty {
                let entry = entriesByItemId[id] ?? append(.status, title: "Reasoning", text: "", itemId: id)
                entry.text = summary.joined(separator: "\n")
                transcriptRevision += 1
            }

        case "mcpToolCall":
            endActiveExplorationGroup()
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            let status = item["status"].map { String(describing: $0) } ?? ""
            let entry = entriesByItemId[id] ?? append(.tool, title: server, text: tool, itemId: id)
            entry.text = tool
            entry.detail = status
            transcriptRevision += 1

        case "fileChange", "file_change", "patch", "diff":
            endActiveExplorationGroup()
            let entry = entriesByItemId[id] ?? append(.diff, title: fileChangeTitle(from: item), text: "", itemId: id)
            entry.title = fileChangeTitle(from: item)
            entry.text = fileChangeSummary(from: item)
            entry.detail = diffText(from: item)
            transcriptRevision += 1

        default:
            if let display = genericDisplayText(from: item) {
                endActiveExplorationGroup()
                let entry = entriesByItemId[id] ?? append(.tool, title: type, text: "", itemId: id)
                entry.title = type
                entry.text = genericDisplaySummary(from: item)
                entry.detail = display
                transcriptRevision += 1
            }
        }
    }

    private func appendFileChangeRequest(_ params: [String: Any], requestId: Int) {
        let entry = append(.diff, title: fileChangeTitle(from: params), text: fileChangeSummary(from: params), itemId: "file-change-request-\(requestId)")
        entry.detail = diffText(from: params)
        entry.isExpanded = true
    }

    private func belongsToActiveThread(_ params: [String: Any]) -> Bool {
        guard let threadId = params["threadId"] as? String else { return true }
        return activeThreadId == nil || activeThreadId == threadId
    }

    private func upsertExplorationItem(id: String, label: String) {
        explorationItemIds.insert(id)
        if !explorationItemOrder.contains(id) {
            explorationItemOrder.append(id)
        }
        explorationLabelsByItemId[id] = label

        let entry = activeExplorationEntry ?? append(.exploration, title: "Explored", text: "")
        activeExplorationEntry = entry
        entry.title = "Explored"
        entry.text = explorationItemOrder.compactMap { explorationLabelsByItemId[$0] }.joined(separator: "\n")
        entry.detail = ""
    }

    private func resetExplorationState() {
        activeExplorationEntry = nil
        explorationItemIds.removeAll()
        explorationLabelsByItemId.removeAll()
        explorationItemOrder.removeAll()
    }

    private func endActiveExplorationGroup() {
        activeExplorationEntry = nil
        explorationLabelsByItemId.removeAll()
        explorationItemOrder.removeAll()
    }

    private static func explorationLabel(for command: String) -> String? {
        let commands = unwrappedShellCommand(command).components(separatedBy: "&&")
        let labels = commands.compactMap { explorationLabelForSingleCommand($0) }
        guard !labels.isEmpty, labels.count == commands.count else { return nil }
        return labels.joined(separator: "\n")
    }

    private static func explorationLabelForSingleCommand(_ command: String) -> String? {
        var tokens = shellTokens(command)
        guard !tokens.isEmpty else { return nil }

        if let first = tokens.first, ["cd", "env"].contains(first) {
            tokens.removeFirst()
            while let first = tokens.first, first.contains("=") {
                tokens.removeFirst()
            }
        }

        guard let tool = tokens.first else { return nil }
        let args = Array(tokens.dropFirst())

        switch tool {
        case "rg", "grep":
            if args.contains("--files") {
                return "List files\(targetSuffix(from: readableTargets(in: args)))"
            }
            return searchLabel(from: args)

        case "sed", "cat", "nl", "head", "tail", "less":
            let targets = readableTargets(in: args)
            guard !targets.isEmpty else { return nil }
            return "Read \(targets.joined(separator: ", "))"

        case "ls":
            return "List\(targetSuffix(from: readableTargets(in: args)))"

        case "find":
            let targets = readableTargets(in: args)
            return "Find\(targetSuffix(from: targets.isEmpty ? ["."] : targets))"

        case "pwd":
            return "Check current directory"

        default:
            return nil
        }
    }

    private static func searchLabel(from args: [String]) -> String? {
        var pattern: String?
        var targets: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-") {
                if ["-e", "--regexp", "-g", "--glob", "--type", "-t"].contains(arg), index + 1 < args.count {
                    if arg == "-e" || arg == "--regexp" {
                        pattern = args[index + 1]
                    }
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if pattern == nil {
                pattern = arg
            } else {
                targets.append(arg)
            }
            index += 1
        }

        guard let pattern else { return nil }
        let targetText = targets.isEmpty ? "" : " in \(targets.joined(separator: ", "))"
        return "Search \(pattern)\(targetText)"
    }

    private static func displayCommand(for command: String) -> String {
        let unwrapped = unwrappedShellCommand(command)
        let tokens = shellTokens(unwrapped)
        guard !tokens.isEmpty else { return unwrapped.trimmingCharacters(in: .whitespacesAndNewlines) }
        return tokens.map(displayToken).joined(separator: " ")
    }

    private static func displayToken(_ token: String) -> String {
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
            return token
        }
        return "\"\(token.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func unwrappedShellCommand(_ command: String) -> String {
        let tokens = shellTokens(command)
        guard let shell = tokens.first?.split(separator: "/").last else {
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard ["sh", "bash", "zsh"].contains(String(shell)) else {
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (index, token) in tokens.enumerated() where ["-c", "-lc", "-ilc"].contains(token) {
            if index + 1 < tokens.count {
                return tokens[(index + 1)...].joined(separator: " ")
            }
        }
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func targetSuffix(from targets: [String]) -> String {
        targets.isEmpty ? "" : " \(targets.joined(separator: ", "))"
    }

    private static func readableTargets(in args: [String]) -> [String] {
        var targets: [String] = []
        var index = 0
        let flagsWithValues: Set<String> = [
            "-e", "--regexp", "-g", "--glob", "--type", "-t", "-m", "--max-count",
            "-A", "-B", "-C", "--after-context", "--before-context", "--context",
            "--include", "--exclude", "-n", "--lines"
        ]

        while index < args.count {
            let arg = args[index]
            if flagsWithValues.contains(arg), index + 1 < args.count {
                index += 2
                continue
            }
            if arg.hasPrefix("-") || arg.range(of: #"^\d+,\d+p$"#, options: .regularExpression) != nil {
                index += 1
                continue
            }
            if arg != "|" && arg != ">" && arg != "2>" && arg != "/dev/null" {
                targets.append(arg)
            }
            index += 1
        }

        return Array(targets.prefix(4))
    }

    private static func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func durationString(from start: Date, to end: Date) -> String {
        let seconds = max(1, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        return "\(minutes)m \(remainingSeconds)s"
    }

    private func fileChangeTitle(from value: [String: Any]) -> String {
        let path = stringValue(for: ["path", "file", "filePath", "target", "targetPath"], in: value)
        guard let path, !path.isEmpty else { return "Changes" }
        return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }

    private func fileChangeSummary(from value: [String: Any]) -> String {
        if let path = stringValue(for: ["path", "file", "filePath", "target", "targetPath"], in: value) {
            return path
        }
        if let action = stringValue(for: ["action", "operation", "status"], in: value) {
            return action
        }
        return "File changes"
    }

    private func diffText(from value: [String: Any]) -> String {
        if let diff = stringValue(for: ["diff", "patch", "unifiedDiff", "changes", "content", "text"], in: value), !diff.isEmpty {
            return diff
        }
        if let files = value["files"] as? [[String: Any]] {
            return files.map { file in
                let title = fileChangeSummary(from: file)
                let diff = diffText(from: file)
                return diff.isEmpty ? title : "\(title)\n\(diff)"
            }.joined(separator: "\n\n")
        }
        return String(describing: value)
    }

    private func genericDisplaySummary(from item: [String: Any]) -> String {
        stringValue(for: ["title", "name", "tool", "status"], in: item) ?? "Item"
    }

    private func genericDisplayText(from item: [String: Any]) -> String? {
        stringValue(for: ["detail", "text", "content", "message", "summary"], in: item)
    }

    private func stringValue(for keys: [String], in value: [String: Any]) -> String? {
        for key in keys {
            if let string = value[key] as? String, !string.isEmpty {
                return string
            }
            if let strings = value[key] as? [String], !strings.isEmpty {
                return strings.joined(separator: "\n")
            }
        }
        return nil
    }

    private func updateThreadStatus(_ threadId: String, status: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].status = status
        saveCachedThreads()
    }

    private func finishLoadingAgent(_ threadId: String) {
        loadingAgentIds.remove(threadId)
        guard loadingAgentIds.isEmpty else { return }
        mergeLoadedAgents()
        loadingAgentsById.removeAll()
        loadingAgentOrder.removeAll()
        isLoadingThreads = false
    }

    private func mergeLoadedAgents() {
        let previousOrder = threads.map(\.id)
        var next: [CodexThreadSummary] = []
        var used = Set<String>()

        for threadId in previousOrder {
            if let thread = loadingAgentsById[threadId], !hiddenThreadIds.contains(threadId) {
                next.append(thread)
                used.insert(threadId)
            }
        }

        for threadId in loadingAgentOrder where !used.contains(threadId) {
            if let thread = loadingAgentsById[threadId], !hiddenThreadIds.contains(threadId) {
                next.append(thread)
                used.insert(threadId)
            }
        }

        threads = next
        saveCachedThreads()
    }

    private static func loadCachedThreads(from defaults: UserDefaults) -> [CodexThreadSummary] {
        guard let data = defaults.data(forKey: cachedThreadsKey),
              let cached = try? JSONDecoder().decode([CodexThreadSummary].self, from: data) else {
            return []
        }
        return cached
    }

    private static func loadHiddenThreadIds(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenThreadIdsKey) ?? [])
    }

    private func saveCachedThreads() {
        if let data = try? JSONEncoder().encode(threads) {
            UserDefaults.standard.set(data, forKey: Self.cachedThreadsKey)
        }
    }

    private func saveHiddenThreadIds() {
        UserDefaults.standard.set(Array(hiddenThreadIds), forKey: Self.hiddenThreadIdsKey)
    }

    private static func imageAttachment(from input: [String: Any]) -> CodexImageAttachment? {
        let detail = input["detail"] as? String ?? "low"
        switch input["type"] as? String {
        case "image":
            guard let url = input["url"] as? String, !url.isEmpty else { return nil }
            return CodexImageAttachment(url: url, detail: detail)
        case "localImage":
            guard let path = input["path"] as? String, !path.isEmpty else { return nil }
            return CodexImageAttachment(url: "file://\(path)", detail: detail, localPath: path)
        default:
            return nil
        }
    }

    private static func inputItem(for image: CodexImageAttachment) -> [String: Any]? {
        if let localPath = image.localPath {
            return [
                "type": "localImage",
                "path": localPath,
                "detail": image.detail
            ]
        }

        guard !image.url.hasPrefix("data:") else { return nil }
        return [
            "type": "image",
            "url": image.url,
            "detail": image.detail
        ]
    }

    private func finishImageUpload(_ upload: PendingImageUpload) {
        guard var pendingTurn = pendingImageTurns[upload.uploadTurnId] else { return }
        pendingTurn.remainingImageIds.remove(upload.imageId)
        pendingTurn.localPathsByImageId[upload.imageId] = upload.path
        pendingImageTurns[upload.uploadTurnId] = pendingTurn

        guard pendingTurn.remainingImageIds.isEmpty else { return }
        pendingImageTurns.removeValue(forKey: upload.uploadTurnId)
        let images = pendingTurn.images.map { image in
            guard let path = pendingTurn.localPathsByImageId[image.id] else { return image }
            return CodexImageAttachment(
                id: image.id,
                url: image.url,
                detail: image.detail,
                dataBase64: image.dataBase64,
                localPath: path
            )
        }
        startTurn(threadId: pendingTurn.threadId, text: pendingTurn.text, images: images)
    }

    private func failPendingImageTurn(_ uploadTurnId: String, message: String) {
        pendingImageTurns.removeValue(forKey: uploadTurnId)
        pendingImageUploads = pendingImageUploads.filter { _, upload in
            upload.uploadTurnId != uploadTurnId
        }
        lastError = "Image upload failed: \(message)"
        append(.error, title: "Image upload failed", text: message)
    }

    @discardableResult
    private func append(
        _ kind: CodexEntryKind,
        title: String,
        text: String,
        itemId: String? = nil,
        images: [CodexImageAttachment] = []
    ) -> CodexEntry {
        let entry = CodexEntry(kind: kind, title: title, text: text, images: images)
        entries.append(entry)
        if let itemId {
            entriesByItemId[itemId] = entry
        }
        transcriptRevision += 1
        return entry
    }

    @discardableResult
    private func sendRequest(method: String, params: [String: Any], kind: String) -> Int {
        let id = nextRequestId
        nextRequestId += 1
        requestKinds[id] = kind
        send(["id": id, "method": method, "params": params])
        return id
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
                    self?.scheduleReconnect()
                }
            }
        }
    }
}
