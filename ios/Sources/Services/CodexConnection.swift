import Foundation
import Observation
import OSLog

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

struct QueuedCodexMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let imageCount: Int
}

private struct QueuedCodexTurn {
    let id: String
    let threadId: String
    let text: String
    let images: [CodexImageAttachment]
}

private struct PendingOptimisticUserEntry {
    let text: String
    let imageCount: Int
    let entry: CodexEntry
}

private struct FileListAttempt {
    let path: String
    let methodIndex: Int
}

private struct FileReadAttempt {
    let path: String
    let methodIndex: Int
}

private struct TranscriptBackfillAttempt {
    let threadId: String
    let turnId: String?
    let path: String
    let mode: TranscriptLoadMode
}

private enum TranscriptLoadMode: Equatable {
    case full
    case activeTurn
}

@Observable
final class CodexConnection {
    static let defaultServerURL = "ws://100.108.73.69:8877"
    static let defaultCwd = "/Users/dawson/projects/hosting-platform"
    static let buildLabel = "2026-06-25-live-refresh"
    private static let cachedThreadsKey = "codex_cached_threads"
    private static let hiddenThreadIdsKey = "codex_hidden_thread_ids"
    private static let logger = Logger(subsystem: "com.dawson.bettercodex", category: "CodexConnection")

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
    var queuedMessages: [QueuedCodexMessage] = []
    var fileBrowserEntriesByPath: [String: [RemoteFileNode]] = [:]
    var fileBrowserLoadingPaths: Set<String> = []
    var fileBrowserDocumentsByPath: [String: RemoteFileDocument] = [:]
    var fileBrowserLoadingFiles: Set<String> = []
    var fileBrowserError: String?
    var diagnosticsStatus = "Build \(CodexConnection.buildLabel)"

    var isConnected: Bool { connectionState == .connected }
    var workingStartedAt: Date? { activeTurnStartedAt }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var nextRequestId = 1
    private var requestKinds: [Int: String] = [:]
    private var activeThreadId: String?
    private var activeTurnId: String?
    private var activeThreadTranscriptPath: String?
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
    private var queuedTurns: [QueuedCodexTurn] = []
    private var pendingOptimisticUserEntries: [PendingOptimisticUserEntry] = []
    private var pendingFileListAttempts: [Int: FileListAttempt] = [:]
    private var pendingFileReadAttempts: [Int: FileReadAttempt] = [:]
    private var pendingTranscriptBackfills: [Int: TranscriptBackfillAttempt] = [:]
    private var pendingTurnPagesByThreadId: [String: [[String: Any]]] = [:]
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var shouldAutoReconnect = false
    private var subscribedThreadId: String?

    init() {
        let defaults = UserDefaults.standard
        let savedServerURL = defaults.string(forKey: "codex_server_url")
        serverURL = savedServerURL == "ws://100.108.73.69:8876"
            ? Self.defaultServerURL
            : savedServerURL ?? Self.defaultServerURL
        if savedServerURL == "ws://100.108.73.69:8876" {
            defaults.set(Self.defaultServerURL, forKey: "codex_server_url")
        }
        bearerToken = defaults.string(forKey: "codex_bearer_token") ?? ""
        cwd = defaults.string(forKey: "codex_cwd") ?? Self.defaultCwd
        hiddenThreadIds = Self.loadHiddenThreadIds(from: defaults)
        threads = Self.loadCachedThreads(from: defaults)
            .filter { !hiddenThreadIds.contains($0.id) }
        diagnosticsStatus = "Launched \(Self.buildLabel) with \(threads.count) cached threads"
        Self.logger.info("Better Codex launch build=\(Self.buildLabel, privacy: .public) cachedThreads=\(self.threads.count, privacy: .public)")
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

        Self.logger.info("Connecting to \(self.serverURL, privacy: .public) build=\(Self.buildLabel, privacy: .public)")
        diagnosticsStatus = "Connecting to \(serverURL)"
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
        pendingOptimisticUserEntries.removeAll()
        pendingFileListAttempts.removeAll()
        pendingFileReadAttempts.removeAll()
        pendingTranscriptBackfills.removeAll()
        fileBrowserLoadingPaths.removeAll()
        fileBrowserLoadingFiles.removeAll()
        clearQueuedTurns()
        loadingAgentIds.removeAll()
        loadingAgentsById.removeAll()
        loadingAgentOrder.removeAll()
        freshThreadIds.removeAll()
        if !keepState {
            selectedThread = nil
            activeThreadId = nil
            activeThreadTranscriptPath = nil
            entries.removeAll()
            entriesByItemId.removeAll()
            pendingOptimisticUserEntries.removeAll()
            resetExplorationState()
            transcriptRevision += 1
        }
    }

    func reconnectIfNeeded() {
        if connectionState == .disconnected, !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Self.logger.info("Reconnect requested from disconnected state")
            connect()
        }
    }

    func refreshAfterForeground() {
        Self.logger.info("Foreground refresh state=\(String(describing: self.connectionState), privacy: .public) selected=\(self.selectedThread?.id ?? "none", privacy: .public)")
        diagnosticsStatus = "Foreground refresh: \(Self.shortTimeString())"
        guard isConnected else {
            reconnectIfNeeded()
            return
        }
        refreshThreads()
        if let selectedThread {
            refreshThread(selectedThread.id)
        }
    }

    func refreshThreads() {
        guard isConnected else { return }
        Self.logger.info("Refreshing thread list")
        diagnosticsStatus = "Refreshing threads: \(Self.shortTimeString())"
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

    func startNewThread(cwd requestedCwd: String? = nil) {
        guard isConnected else { return }
        let trimmedCwd = requestedCwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadCwd = trimmedCwd.isEmpty ? cwd : trimmedCwd
        cwd = threadCwd
        saveSettings()
        let params: [String: Any] = [
            "cwd": threadCwd,
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
            pendingOptimisticUserEntries.removeAll()
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

        unsubscribeFromActiveThreadIfNeeded(except: thread.id)
        selectedThread = thread
        activeThreadId = thread.id
        activeThreadTranscriptPath = nil
        entries.removeAll()
        entriesByItemId.removeAll()
        pendingOptimisticUserEntries.removeAll()
        resetExplorationState()
        transcriptRevision += 1
        isLoadingThread = true
        pendingInput = nil
        clearQueuedTurns()
        sendRequest(
            method: "bridge/thread/resume",
            params: [
                "threadId": thread.id,
                "cwd": thread.cwd.isEmpty ? cwd : thread.cwd,
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

        if isWorking {
            enqueueTurn(threadId: threadId, text: trimmed, images: images)
            return
        }

        let entry = append(.user, title: "You", text: trimmed, images: images)
        pendingOptimisticUserEntries.append(PendingOptimisticUserEntry(
            text: trimmed,
            imageCount: images.count,
            entry: entry
        ))
        sendTurn(threadId: threadId, text: trimmed, images: images)
    }

    func loadDirectory(path: String? = nil, force: Bool = false) {
        let directoryPath = normalizedFilePath(path ?? selectedThread?.cwd ?? cwd)
        guard isConnected else {
            Self.logger.info("Queueing directory load until reconnect path=\(directoryPath, privacy: .public)")
            diagnosticsStatus = "Waiting to load files until reconnect"
            fileBrowserError = nil
            fileBrowserLoadingPaths.insert(directoryPath)
            reconnectIfNeeded()
            return
        }
        guard force || fileBrowserEntriesByPath[directoryPath] == nil else { return }
        Self.logger.info("Loading directory path=\(directoryPath, privacy: .public) force=\(force, privacy: .public)")
        diagnosticsStatus = "Loading folder: \(URL(fileURLWithPath: directoryPath).lastPathComponent)"
        fileBrowserError = nil
        fileBrowserLoadingPaths.insert(directoryPath)
        sendFileListAttempt(path: directoryPath, methodIndex: 0)
    }

    func loadFile(path: String, force: Bool = false) {
        let filePath = normalizedFilePath(path)
        guard isConnected else {
            Self.logger.info("Queueing file load until reconnect path=\(filePath, privacy: .public)")
            diagnosticsStatus = "Waiting to load file until reconnect"
            fileBrowserError = nil
            fileBrowserLoadingFiles.insert(filePath)
            reconnectIfNeeded()
            return
        }
        guard force || fileBrowserDocumentsByPath[filePath] == nil else { return }
        Self.logger.info("Loading file path=\(filePath, privacy: .public) force=\(force, privacy: .public)")
        diagnosticsStatus = "Loading file: \(URL(fileURLWithPath: filePath).lastPathComponent)"
        fileBrowserError = nil
        fileBrowserLoadingFiles.insert(filePath)
        sendFileReadAttempt(path: filePath, methodIndex: 0)
    }

    func clearFileBrowserError() {
        fileBrowserError = nil
    }

    private func sendTurn(threadId: String, text: String, images: [CodexImageAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

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

    private func enqueueTurn(threadId: String, text: String, images: [CodexImageAttachment]) {
        let id = UUID().uuidString
        queuedTurns.append(QueuedCodexTurn(id: id, threadId: threadId, text: text, images: images))
        queuedMessages.append(QueuedCodexMessage(id: id, text: text, imageCount: images.count))
        append(.user, title: "Queued", text: text, images: images)
    }

    private func clearQueuedTurns() {
        queuedTurns.removeAll()
        queuedMessages.removeAll()
    }

    private func startNextQueuedTurnIfNeeded() {
        guard !isWorking, !queuedTurns.isEmpty else { return }
        let next = queuedTurns.removeFirst()
        queuedMessages.removeAll { $0.id == next.id }
        append(.status, title: "Queued message sent", text: "")
        sendTurn(threadId: next.threadId, text: next.text, images: next.images)
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
            "cwd": activeWorkingDirectory,
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

    private func refreshThread(_ threadId: String) {
        guard isConnected else { return }
        isLoadingThread = true
        Self.logger.info("Refreshing turns thread=\(threadId, privacy: .public)")
        diagnosticsStatus = "Refreshing transcript: \(Self.shortTimeString())"
        sendRequest(
            method: "thread/turns/list",
            params: ["threadId": threadId],
            kind: "thread/turns/list:\(threadId)"
        )
    }

    private func unsubscribeFromActiveThreadIfNeeded(except threadId: String? = nil) {
        guard isConnected,
              let subscribedThreadId,
              subscribedThreadId != threadId else { return }
        sendRequest(
            method: "thread/unsubscribe",
            params: ["threadId": subscribedThreadId],
            kind: "thread/unsubscribe:\(subscribedThreadId)"
        )
        self.subscribedThreadId = nil
    }

    private func requestFullTranscriptLoad(from thread: [String: Any]? = nil, threadId: String? = nil) -> Bool {
        if let path = thread?["path"] as? String, !path.isEmpty {
            activeThreadTranscriptPath = path
        }
        if let threadId {
            activeThreadId = threadId
        }

        guard isConnected,
              let activeThreadId,
              let path = activeThreadTranscriptPath,
              !pendingTranscriptBackfills.values.contains(where: { $0.threadId == activeThreadId && $0.path == path && $0.mode == .full }) else {
            return false
        }

        let id = sendRequest(
            method: "fs/readFile",
            params: ["path": path],
            kind: "transcript/full:\(activeThreadId)"
        )
        pendingTranscriptBackfills[id] = TranscriptBackfillAttempt(
            threadId: activeThreadId,
            turnId: nil,
            path: path,
            mode: .full
        )
        diagnosticsStatus = "Loading full transcript"
        return true
    }

    private func requestTranscriptBackfillIfPossible(from thread: [String: Any]? = nil, threadId: String? = nil) {
        if let path = thread?["path"] as? String, !path.isEmpty {
            activeThreadTranscriptPath = path
        }
        if let threadId {
            activeThreadId = threadId
        }

        let selectedIsActive = selectedThread?.status == "active"
            || selectedThread?.status == "running"
            || selectedThread?.status == "in_progress"
        guard isConnected,
              selectedIsActive,
              let activeThreadId,
              let activeTurnId,
              let path = activeThreadTranscriptPath,
              !pendingTranscriptBackfills.values.contains(where: { $0.turnId == activeTurnId && $0.path == path && $0.mode == .activeTurn }) else {
            return
        }

        let id = sendRequest(
            method: "fs/readFile",
            params: ["path": path],
            kind: "transcript/backfill:\(activeThreadId):\(activeTurnId)"
        )
        pendingTranscriptBackfills[id] = TranscriptBackfillAttempt(
            threadId: activeThreadId,
            turnId: activeTurnId,
            path: path,
            mode: .activeTurn
        )
        diagnosticsStatus = "Backfilling active turn"
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
        pendingFileListAttempts.removeAll()
        pendingFileReadAttempts.removeAll()
        pendingTurnPagesByThreadId.removeAll()
        fileBrowserLoadingPaths.removeAll()
        fileBrowserLoadingFiles.removeAll()
        clearQueuedTurns()

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
            if let attempt = pendingTranscriptBackfills.removeValue(forKey: id) {
                diagnosticsStatus = "Transcript backfill failed: \(errorMessage)"
                if attempt.mode == .full, activeThreadId == attempt.threadId {
                    refreshThread(attempt.threadId)
                }
                return
            }
            if handleFileRequestError(id: id, message: errorMessage) {
                return
            }
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
            if kind?.hasPrefix("thread/turns/list:") == true,
               let threadId = threadId(from: kind) {
                pendingTurnPagesByThreadId.removeValue(forKey: threadId)
                isLoadingThread = false
            }
            if kind?.hasPrefix("thread/delete:") == true || kind?.hasPrefix("thread/name/set:") == true {
                refreshThreads()
            }
            return
        }

        if let upload = pendingImageUploads.removeValue(forKey: id) {
            finishImageUpload(upload)
            return
        }

        if handleTranscriptBackfillSuccess(id: id, result: message["result"] as Any) {
            return
        }

        if handleFileRequestSuccess(id: id, result: message["result"] as Any) {
            return
        }

        guard let result = message["result"] as? [String: Any] else { return }

        switch kind {
        case "initialize":
            reconnectAttempt = 0
            lastError = nil
            startPingLoop()
            connectionState = .connected
            Self.logger.info("Connected")
            diagnosticsStatus = "Connected: \(Self.shortTimeString())"
            refreshThreads()

        case "thread/loaded/list":
            let ids = result["data"] as? [String] ?? []
            Self.logger.info("Loaded thread ids count=\(ids.count, privacy: .public)")
            diagnosticsStatus = "Loaded \(ids.count) threads"
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
                      let thread = result["thread"] as? [String: Any],
                      let threadId = threadId(from: kind) {
                if !requestFullTranscriptLoad(from: thread, threadId: threadId),
                   entries.isEmpty,
                   !loadHistory(from: thread, showEmptyState: false) {
                    sendRequest(
                        method: "thread/turns/list",
                        params: ["threadId": threadId],
                        kind: "thread/turns/list:\(threadId)"
                    )
                }
                isLoadingThread = false
            } else if kind?.hasPrefix("thread/turns/list:") == true {
                guard let threadId = threadId(from: kind) else { return }
                let turns = result["data"] as? [[String: Any]]
                    ?? result["turns"] as? [[String: Any]]
                    ?? []
                Self.logger.info("Loaded turns count=\(turns.count, privacy: .public) kind=\(kind ?? "unknown", privacy: .public)")
                var accumulatedTurns = pendingTurnPagesByThreadId[threadId] ?? []
                accumulatedTurns.append(contentsOf: turns)
                if let nextCursor = result["nextCursor"] as? String, !nextCursor.isEmpty {
                    pendingTurnPagesByThreadId[threadId] = accumulatedTurns
                    diagnosticsStatus = "Loaded \(accumulatedTurns.count) turns..."
                    sendRequest(
                        method: "thread/turns/list",
                        params: ["threadId": threadId, "cursor": nextCursor],
                        kind: "thread/turns/list:\(threadId)"
                    )
                    return
                }

                pendingTurnPagesByThreadId.removeValue(forKey: threadId)
                diagnosticsStatus = "Loaded \(accumulatedTurns.count) turns: \(Self.shortTimeString())"
                let selectedIsActive = selectedThread?.status == "active"
                    || selectedThread?.status == "running"
                    || selectedThread?.status == "in_progress"
                loadHistoryFromTurns(
                    accumulatedTurns,
                    reset: true,
                    showEmptyState: !selectedIsActive
                )
                if selectedIsActive, activeTurnId == nil {
                    activeTurnId = newestTurn(in: accumulatedTurns)?["id"] as? String
                }
                requestTranscriptBackfillIfPossible()
                isLoadingThread = false
            } else if kind?.hasPrefix("thread/resume:") == true,
                      let thread = result["thread"] as? [String: Any],
                      let summary = CodexThreadSummary(json: thread) {
                selectedThread = summary
                activeThreadId = summary.id
                subscribedThreadId = summary.id
                if loadBridgeTranscriptIfPresent(result) {
                    isLoadingThread = false
                } else if !requestFullTranscriptLoad(from: thread, threadId: summary.id) {
                    refreshThread(summary.id)
                }
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
            guard belongsToActiveThread(params) else { return }
            isWorking = true
            activeTurnStartedAt = Date()
            if let threadId = params["threadId"] as? String {
                updateThreadStatus(threadId, status: "active")
            }
            if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
                activeTurnId = id
            }
            append(.status, title: "Turn started", text: "")

        case "turn/completed":
            guard belongsToActiveThread(params) else { return }
            isWorking = false
            activeTurnId = nil
            endActiveExplorationGroup()
            if let activeTurnStartedAt {
                append(.status, title: "Worked for \(Self.durationString(from: activeTurnStartedAt, to: Date()))", text: "")
            }
            activeTurnStartedAt = nil
            refreshThreads()
            startNextQueuedTurnIfNeeded()

        case "turn/diff/updated":
            guard belongsToActiveThread(params),
                  let turnId = params["turnId"] as? String,
                  let diff = params["diff"] as? String,
                  !diff.isEmpty else { return }
            let itemId = "diff-\(turnId)"
            let entry = entriesByItemId[itemId] ?? append(.diff, title: "Changes", text: "Live diff updated", itemId: itemId)
            entry.detail = diff
            transcriptRevision += 1

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
            if explorationItemIds.contains(itemId), let explorationEntry = activeExplorationEntry {
                explorationEntry.detail += delta
            } else if let commandEntry = entriesByItemId[itemId], commandEntry.kind == .command {
                commandEntry.detail += delta
            } else {
                let entry = entriesByItemId["output-\(itemId)"] ?? append(.output, title: "Output", text: "", itemId: "output-\(itemId)")
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

    @discardableResult
    private func loadBridgeTranscriptIfPresent(_ result: [String: Any]) -> Bool {
        guard let transcript = result["bridgeTranscript"] as? [String: Any],
              let rawEntries = transcript["entries"] as? [[String: Any]] else {
            return false
        }

        entries.removeAll()
        entriesByItemId.removeAll()
        pendingOptimisticUserEntries.removeAll()
        resetExplorationState()
        transcriptRevision += 1

        let totalEntries = Self.intValue(transcript["totalEntries"])
        let omittedEntries = Self.intValue(transcript["omittedEntries"]) ?? 0
        if let totalEntries, totalEntries > rawEntries.count {
            append(
                .status,
                title: "Loaded transcript",
                text: "Showing \(rawEntries.count.formatted()) of \(totalEntries.formatted()) items. \(omittedEntries.formatted()) older items are compacted."
            )
        } else if !rawEntries.isEmpty {
            append(
                .status,
                title: "Loaded transcript",
                text: "Showing \(rawEntries.count.formatted()) items."
            )
        }

        for rawEntry in rawEntries {
            guard let id = rawEntry["id"] as? String,
                  let rawKind = rawEntry["kind"] as? String,
                  let kind = CodexEntryKind(rawValue: rawKind) else {
                continue
            }
            let entry = append(
                kind,
                title: rawEntry["title"] as? String ?? "",
                text: rawEntry["text"] as? String ?? "",
                itemId: id
            )
            entry.detail = rawEntry["detail"] as? String ?? ""
        }

        diagnosticsStatus = "Loaded \(entries.count) bridge transcript items"
        if entries.isEmpty {
            append(.status, title: "No transcript", text: "This session has no loaded items yet.")
        }
        return true
    }

    @discardableResult
    private func loadHistory(from thread: [String: Any], showEmptyState: Bool = true) -> Bool {
        entries.removeAll()
        entriesByItemId.removeAll()
        pendingOptimisticUserEntries.removeAll()
        resetExplorationState()
        transcriptRevision += 1
        let turns = thread["turns"] as? [[String: Any]] ?? []
        return loadHistoryFromTurns(turns, reset: false, showEmptyState: showEmptyState)
    }

    @discardableResult
    private func loadHistoryFromTurns(
        _ turns: [[String: Any]],
        reset: Bool = true,
        showEmptyState: Bool = true
    ) -> Bool {
        if reset {
            entries.removeAll()
            entriesByItemId.removeAll()
            pendingOptimisticUserEntries.removeAll()
            resetExplorationState()
            transcriptRevision += 1
        }
        for turn in chronologicalTurns(turns) {
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                upsertItem(item, completed: true)
            }
            endActiveExplorationGroup()
        }
        if entries.isEmpty, showEmptyState {
            append(.status, title: "No transcript", text: "This session has no loaded items yet.")
        }
        return !entries.isEmpty
    }

    private func chronologicalTurns(_ turns: [[String: Any]]) -> [[String: Any]] {
        turns.enumerated().sorted { lhs, rhs in
            let lhsStartedAt = Self.timestampValue(lhs.element["startedAt"])
            let rhsStartedAt = Self.timestampValue(rhs.element["startedAt"])
            switch (lhsStartedAt, rhsStartedAt) {
            case let (lhsStartedAt?, rhsStartedAt?):
                if lhsStartedAt == rhsStartedAt { return lhs.offset < rhs.offset }
                return lhsStartedAt < rhsStartedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func newestTurn(in turns: [[String: Any]]) -> [String: Any]? {
        turns.max { lhs, rhs in
            (Self.timestampValue(lhs["startedAt"]) ?? 0) < (Self.timestampValue(rhs["startedAt"]) ?? 0)
        }
    }

    private func selectFreshThread(_ thread: CodexThreadSummary) {
        selectedThread = thread
        activeThreadId = thread.id
        entries.removeAll()
        entriesByItemId.removeAll()
        pendingOptimisticUserEntries.removeAll()
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

        if kind?.hasPrefix("thread/resume:") == true || kind?.hasPrefix("thread/read:") == true {
            removeUnavailableThread(threadId)
            lastError = nil
            return true
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

    private func removeUnavailableThread(_ threadId: String) {
        hiddenThreadIds.insert(threadId)
        threads.removeAll { $0.id == threadId }
        freshThreadIds.remove(threadId)
        saveHiddenThreadIds()
        saveCachedThreads()
        if activeThreadId == threadId || selectedThread?.id == threadId {
            selectedThread = nil
            activeThreadId = nil
            activeThreadTranscriptPath = nil
            entries.removeAll()
            entriesByItemId.removeAll()
            pendingOptimisticUserEntries.removeAll()
            resetExplorationState()
            transcriptRevision += 1
            isLoadingThread = false
            pendingInput = nil
        }
        diagnosticsStatus = "Removed unavailable thread"
    }

    private func threadId(from kind: String?) -> String? {
        guard let kind else { return nil }
        for prefix in ["thread/read:list:", "thread/read:", "thread/resume:", "thread/turns/list:"] {
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
            let entry = entriesByItemId[id]
                ?? consumeOptimisticUserEntry(text: text, imageCount: images.count, serverItemId: id)
                ?? append(.user, title: "You", text: "", itemId: id)
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
                if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                    activeExplorationEntry?.detail = output
                }
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

    private func consumeOptimisticUserEntry(text: String, imageCount: Int, serverItemId: String) -> CodexEntry? {
        guard let index = pendingOptimisticUserEntries.firstIndex(where: {
            $0.text == text && $0.imageCount == imageCount
        }) else {
            return nil
        }
        let pending = pendingOptimisticUserEntries.remove(at: index)
        entriesByItemId[serverItemId] = pending.entry
        return pending.entry
    }

    private func appendFileChangeRequest(_ params: [String: Any], requestId: Int) {
        let entry = append(.diff, title: fileChangeTitle(from: params), text: fileChangeSummary(from: params), itemId: "file-change-request-\(requestId)")
        entry.detail = diffText(from: params)
        entry.isExpanded = true
    }

    private func belongsToActiveThread(_ params: [String: Any]) -> Bool {
        let threadId = params["threadId"] as? String
            ?? (params["thread"] as? [String: Any])?["id"] as? String
            ?? (params["turn"] as? [String: Any])?["threadId"] as? String
            ?? (params["item"] as? [String: Any])?["threadId"] as? String
        guard let threadId else { return true }
        return activeThreadId == nil || activeThreadId == threadId
    }

    private var activeWorkingDirectory: String {
        if let selectedCwd = selectedThread?.cwd, !selectedCwd.isEmpty {
            return selectedCwd
        }
        if let activeThreadId,
           let threadCwd = threads.first(where: { $0.id == activeThreadId })?.cwd,
           !threadCwd.isEmpty {
            return threadCwd
        }
        return cwd
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

    private static func shortTimeString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func fileChangeTitle(from value: [String: Any]) -> String {
        let path = stringValue(for: ["path", "file", "filePath", "target", "targetPath"], in: value)
        guard let path, !path.isEmpty else { return "Changes" }
        return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }

    private func fileChangeSummary(from value: [String: Any]) -> String {
        if let files = fileChangePaths(from: value), !files.isEmpty {
            if files.count == 1 { return files[0] }
            return "\(files.count) files"
        }
        if let path = stringValue(for: ["path", "file", "filePath", "target", "targetPath"], in: value) {
            return path
        }
        if let action = stringValue(for: ["action", "operation", "status"], in: value) {
            return action
        }
        return "File changes"
    }

    private func diffText(from value: [String: Any]) -> String {
        if let diff = stringValue(for: ["diff", "patch", "unifiedDiff"], in: value), !diff.isEmpty {
            return diff
        }
        if let sections = diffSections(from: value), !sections.isEmpty {
            return sections.joined(separator: "\n\n")
        }
        if let text = stringValue(for: ["content", "text", "message"], in: value), !text.isEmpty {
            return text
        }
        return fileChangeSummary(from: value)
    }

    private func diffSections(from value: [String: Any]) -> [String]? {
        for key in ["files", "changes", "edits", "operations"] {
            if let files = value[key] as? [[String: Any]] {
                return files.compactMap(diffSection)
            }
            if let dict = value[key] as? [String: Any] {
                return dict.map { path, payload in
                    if let file = payload as? [String: Any] {
                        let body = diffText(from: file)
                        return body.contains("diff --git") || body.contains("@@")
                            ? body
                            : "\(path)\n\(body)"
                    }
                    if let text = payload as? String, !text.isEmpty {
                        return "\(path)\n\(text)"
                    }
                    return path
                }
            }
        }
        return nil
    }

    private func diffSection(from value: [String: Any]) -> String? {
        let title = fileChangeSummary(from: value)
        if let diff = stringValue(for: ["diff", "patch", "unifiedDiff"], in: value), !diff.isEmpty {
            return diff.contains("diff --git") || diff.contains("@@") ? diff : "\(title)\n\(diff)"
        }
        let before = stringValue(for: ["before", "old", "oldText", "previous"], in: value)
        let after = stringValue(for: ["after", "new", "newText", "current"], in: value)
        if before != nil || after != nil {
            var lines = [title]
            if let before { lines.append("--- before\n\(before)") }
            if let after { lines.append("+++ after\n\(after)") }
            return lines.joined(separator: "\n")
        }
        if let summary = stringValue(for: ["summary", "description", "operation", "action"], in: value) {
            return "\(title)\n\(summary)"
        }
        return nil
    }

    private func fileChangePaths(from value: [String: Any]) -> [String]? {
        for key in ["files", "changes", "edits", "operations"] {
            if let files = value[key] as? [[String: Any]] {
                return files.compactMap { file in
                    stringValue(for: ["path", "file", "filePath", "target", "targetPath"], in: file)
                }
            }
            if let dict = value[key] as? [String: Any] {
                return Array(dict.keys).sorted()
            }
        }
        return nil
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

    private func sendFileListAttempt(path: String, methodIndex: Int) {
        let methods = ["fs/readDirectory", "fs/listDirectory", "fs/readdir", "fs/list"]
        guard methodIndex < methods.count else {
            fileBrowserLoadingPaths.remove(path)
            fileBrowserError = "File listing is not available from this app-server."
            diagnosticsStatus = "File listing unavailable"
            return
        }
        let id = sendRequest(
            method: methods[methodIndex],
            params: ["path": path],
            kind: "file/list:\(path)"
        )
        pendingFileListAttempts[id] = FileListAttempt(path: path, methodIndex: methodIndex)
    }

    private func sendFileReadAttempt(path: String, methodIndex: Int) {
        let methods = ["fs/readFile", "fs/readTextFile", "fs/read"]
        guard methodIndex < methods.count else {
            fileBrowserLoadingFiles.remove(path)
            fileBrowserError = "File reading is not available from this app-server."
            diagnosticsStatus = "File reading unavailable"
            return
        }
        let id = sendRequest(
            method: methods[methodIndex],
            params: ["path": path],
            kind: "file/read:\(path)"
        )
        pendingFileReadAttempts[id] = FileReadAttempt(path: path, methodIndex: methodIndex)
    }

    private func handleFileRequestError(id: Int, message: String) -> Bool {
        if let attempt = pendingFileListAttempts.removeValue(forKey: id) {
            sendFileListAttempt(path: attempt.path, methodIndex: attempt.methodIndex + 1)
            if attempt.methodIndex >= 3 {
                fileBrowserLoadingPaths.remove(attempt.path)
                fileBrowserError = message
                diagnosticsStatus = "Folder load failed: \(message)"
            }
            return true
        }
        if let attempt = pendingFileReadAttempts.removeValue(forKey: id) {
            sendFileReadAttempt(path: attempt.path, methodIndex: attempt.methodIndex + 1)
            if attempt.methodIndex >= 2 {
                fileBrowserLoadingFiles.remove(attempt.path)
                fileBrowserError = message
                diagnosticsStatus = "File load failed: \(message)"
            }
            return true
        }
        return false
    }

    private func handleFileRequestSuccess(id: Int, result: Any) -> Bool {
        if let attempt = pendingFileListAttempts.removeValue(forKey: id) {
            let entries = remoteFileNodes(from: result, parentPath: attempt.path)
            fileBrowserEntriesByPath[attempt.path] = entries
            fileBrowserLoadingPaths.remove(attempt.path)
            diagnosticsStatus = "Loaded \(entries.count) files: \(URL(fileURLWithPath: attempt.path).lastPathComponent)"
            return true
        }
        if let attempt = pendingFileReadAttempts.removeValue(forKey: id) {
            let document = remoteFileDocument(from: result, path: attempt.path)
            fileBrowserDocumentsByPath[attempt.path] = document
            fileBrowserLoadingFiles.remove(attempt.path)
            diagnosticsStatus = "Loaded file: \(URL(fileURLWithPath: attempt.path).lastPathComponent)"
            return true
        }
        return false
    }

    private func handleTranscriptBackfillSuccess(id: Int, result: Any) -> Bool {
        guard let attempt = pendingTranscriptBackfills.removeValue(forKey: id) else { return false }
        guard activeThreadId == attempt.threadId else { return true }

        let jsonl = decodedRemoteText(from: result)
        let applied: Int
        switch attempt.mode {
        case .full:
            applied = loadFullTranscript(from: jsonl)
            diagnosticsStatus = applied > 0
                ? "Loaded \(applied) transcript items"
                : "No transcript items"
            if applied == 0 {
                refreshThread(attempt.threadId)
            }
        case .activeTurn:
            guard let turnId = attempt.turnId else { return true }
            applied = backfillTranscript(from: jsonl, turnId: turnId)
            diagnosticsStatus = applied > 0
                ? "Backfilled \(applied) active items"
                : "No active backfill items"
        }
        isLoadingThread = false
        return true
    }

    @discardableResult
    private func loadFullTranscript(from jsonl: String) -> Int {
        entries.removeAll()
        entriesByItemId.removeAll()
        pendingOptimisticUserEntries.removeAll()
        resetExplorationState()
        transcriptRevision += 1

        var applied = 0
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any] else {
                continue
            }

            if type == "response_item", backfillResponseItem(payload) {
                applied += 1
            } else if type == "event_msg", backfillEventMessage(payload, turnId: nil) {
                applied += 1
            }
        }
        endActiveExplorationGroup()
        if entries.isEmpty {
            append(.status, title: "No transcript", text: "This session has no loaded items yet.")
        }
        return applied
    }

    @discardableResult
    private func backfillTranscript(from jsonl: String, turnId: String) -> Int {
        var applied = 0
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        let recentLines = lines.suffix(2_000)
        for line in recentLines {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any] else {
                continue
            }

            if type == "response_item",
               let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
               metadata["turn_id"] as? String == turnId,
               backfillResponseItem(payload) {
                applied += 1
            } else if type == "event_msg",
                      backfillEventMessage(payload, turnId: turnId) {
                applied += 1
            }
        }
        return applied
    }

    @discardableResult
    private func backfillResponseItem(_ item: [String: Any]) -> Bool {
        guard let type = item["type"] as? String else { return false }

        switch type {
        case "message":
            let role = item["role"] as? String ?? "assistant"
            guard role == "user" || role == "assistant" else { return false }
            let text = Self.responseContentText(item["content"] as? [[String: Any]] ?? [])
            if role == "user", Self.isInjectedContextMessage(text) { return false }
            guard !text.isEmpty, let id = item["id"] as? String else { return false }
            endActiveExplorationGroup()
            let entry = entriesByItemId[id] ?? append(role == "user" ? .user : .assistant, title: role == "user" ? "You" : "Codex", text: "", itemId: id)
            entry.text = text
            transcriptRevision += 1
            return true

        case "function_call":
            guard let callId = item["call_id"] as? String else { return false }
            let name = item["name"] as? String ?? "tool"
            let arguments = item["arguments"] as? String ?? ""
            endActiveExplorationGroup()
            let entry = entriesByItemId[callId] ?? append(.command, title: "running", text: name, itemId: callId)
            entry.title = "running"
            entry.text = Self.displayBackfillCommand(name: name, arguments: arguments)
            transcriptRevision += 1
            return true

        case "function_call_output":
            guard let callId = item["call_id"] as? String else { return false }
            let output = item["output"] as? String ?? ""
            if let commandEntry = entriesByItemId[callId] {
                commandEntry.title = "completed"
                commandEntry.detail = output
            } else {
                let entry = entriesByItemId["output-\(callId)"] ?? append(.output, title: "Output", text: "", itemId: "output-\(callId)")
                entry.text = output
            }
            transcriptRevision += 1
            return true

        case "custom_tool_call":
            guard let callId = item["call_id"] as? String else { return false }
            let name = item["name"] as? String ?? "tool"
            let input = item["input"] as? String ?? ""
            endActiveExplorationGroup()
            if name == "apply_patch", !input.isEmpty {
                let entry = entriesByItemId[callId] ?? append(.diff, title: "Patch", text: "Applied patch", itemId: callId)
                entry.detail = input
            } else {
                let entry = entriesByItemId[callId] ?? append(.tool, title: name, text: "", itemId: callId)
                entry.text = input
            }
            transcriptRevision += 1
            return true

        case "custom_tool_call_output":
            guard let callId = item["call_id"] as? String else { return false }
            let output = item["output"] as? String ?? ""
            if let entry = entriesByItemId[callId] {
                entry.detail = output.isEmpty ? entry.detail : output
            }
            transcriptRevision += 1
            return true

        case "reasoning":
            let summaries = item["summary"] as? [[String: Any]] ?? []
            let text = summaries.compactMap { summary -> String? in
                summary["text"] as? String
            }.joined(separator: "\n")
            guard !text.isEmpty, let id = item["id"] as? String else { return false }
            endActiveExplorationGroup()
            let entry = entriesByItemId[id] ?? append(.status, title: "Reasoning", text: "", itemId: id)
            entry.text = text
            transcriptRevision += 1
            return true

        default:
            return false
        }
    }

    @discardableResult
    private func backfillEventMessage(_ payload: [String: Any], turnId: String?) -> Bool {
        let payloadTurnId = payload["turn_id"] as? String
            ?? (payload["item"] as? [String: Any])?["turnId"] as? String
        guard turnId == nil || payloadTurnId == turnId else {
            return false
        }

        switch payload["type"] as? String {
        case "patch_apply_end":
            guard let callId = payload["call_id"] as? String else { return false }
            let changes = payload["changes"] as? [String: Any] ?? [:]
            let diff = changes.values.compactMap { value -> String? in
                (value as? [String: Any])?["unified_diff"] as? String
            }.joined(separator: "\n")
            let output = payload["stdout"] as? String ?? ""
            let entry = entriesByItemId[callId] ?? append(.diff, title: "Patch", text: output, itemId: callId)
            entry.text = output
            if !diff.isEmpty { entry.detail = diff }
            transcriptRevision += 1
            return true

        default:
            return false
        }
    }

    private static func responseContentText(_ content: [[String: Any]]) -> String {
        content.compactMap { part -> String? in
            switch part["type"] as? String {
            case "output_text", "input_text", "text":
                return part["text"] as? String
            default:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    private static func displayBackfillCommand(name: String, arguments: String) -> String {
        let normalizedName = name.components(separatedBy: ".").last ?? name
        guard normalizedName == "exec_command",
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["cmd"] as? String else {
            return arguments.isEmpty ? name : "\(name) \(arguments)"
        }
        return displayCommand(for: command)
    }

    private static func isInjectedContextMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions")
            || trimmed.hasPrefix("<INSTRUCTIONS>")
            || trimmed.hasPrefix("<environment_context>")
    }

    private func remoteFileNodes(from result: Any, parentPath: String) -> [RemoteFileNode] {
        let resultDict = result as? [String: Any]
        let rawEntries =
            result as? [[String: Any]]
            ?? resultDict?["entries"] as? [[String: Any]]
            ?? resultDict?["files"] as? [[String: Any]]
            ?? resultDict?["children"] as? [[String: Any]]
            ?? resultDict?["items"] as? [[String: Any]]
            ?? resultDict?["data"] as? [[String: Any]]
            ?? []

        return rawEntries.compactMap { entry in
            let name = stringValue(for: ["name", "fileName", "basename"], in: entry)
                ?? URL(fileURLWithPath: stringValue(for: ["path", "filePath"], in: entry) ?? "").lastPathComponent
            guard !name.isEmpty else { return nil }
            let path = normalizedFilePath(
                stringValue(for: ["path", "filePath", "absolutePath"], in: entry)
                    ?? parentPath.appendingPathComponent(name)
            )
            let rawType = (stringValue(for: ["type", "kind"], in: entry) ?? "").lowercased()
            let isDirectory =
                (entry["isDirectory"] as? Bool)
                ?? (entry["directory"] as? Bool)
                ?? rawType.contains("dir")
            let size = Self.intValue(entry["size"]) ?? Self.intValue(entry["byteLength"])
            return RemoteFileNode(name: name, path: path, isDirectory: isDirectory, size: size)
        }
        .filter { !$0.name.hasPrefix(".git") && $0.name != "node_modules" }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func remoteFileDocument(from result: Any, path: String) -> RemoteFileDocument {
        let maxCharacters = 240_000
        let rawText = remoteText(from: result, maxCharacters: maxCharacters, keepTail: false)
        let isTruncated = decodedRemoteText(from: result).count > maxCharacters
        return RemoteFileDocument(path: path, text: rawText, isTruncated: isTruncated)
    }

    private func remoteText(from result: Any, maxCharacters: Int, keepTail: Bool) -> String {
        let rawText = decodedRemoteText(from: result)
        guard rawText.count > maxCharacters else { return rawText }
        return keepTail ? String(rawText.suffix(maxCharacters)) : String(rawText.prefix(maxCharacters))
    }

    private func decodedRemoteText(from result: Any) -> String {
        let resultDict = result as? [String: Any]
        if let text = result as? String {
            return text
        } else if let dataBase64 = resultDict?["dataBase64"] as? String,
           let data = Data(base64Encoded: dataBase64),
           let decoded = String(data: data, encoding: .utf8) {
            return decoded
        } else if let dataBase64 = resultDict?["base64"] as? String,
                  let data = Data(base64Encoded: dataBase64),
                  let decoded = String(data: data, encoding: .utf8) {
            return decoded
        } else {
            return resultDict?["text"] as? String
                ?? resultDict?["content"] as? String
                ?? resultDict?["data"] as? String
                ?? resultDict?["contents"] as? String
                ?? ""
        }
    }

    private func normalizedFilePath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func timestampValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
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
