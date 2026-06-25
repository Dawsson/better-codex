import SwiftUI

struct CodexConsoleView: View {
    @Environment(CodexConnection.self) private var codex
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            CodexThreadListView(showSettings: $showSettings)
                .environment(codex)
                .navigationDestination(for: CodexThreadSummary.self) { thread in
                    CodexThreadDetailView(thread: thread)
                        .environment(codex)
                }
        }
        .sheet(isPresented: $showSettings) {
            CodexSettingsView().environment(codex)
        }
        .onAppear {
            if codex.connectionState == .disconnected, !codex.bearerToken.isEmpty {
                codex.connect()
            }
        }
    }
}

struct CodexThreadListView: View {
    @Environment(CodexConnection.self) private var codex
    @Binding var showSettings: Bool
    @State private var renamingThread: CodexThreadSummary?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        List {
            if !codex.isConnected || codex.lastError != nil {
                connectionRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if codex.isLoadingThreads && codex.threads.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading agents")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if codex.threads.isEmpty {
                ContentUnavailableView(
                    codex.isConnected ? "No open agents" : "Connect to Codex",
                    systemImage: codex.isConnected ? "text.bubble" : "antenna.radiowaves.left.and.right",
                    description: Text(codex.isConnected ? "Start one from your phone or open a cx session on the Mac." : "Add the app-server token in Settings.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(codex.threads) { thread in
                    NavigationLink(value: thread) {
                        CodexThreadRow(thread: thread)
                    }
                    .listRowBackground(Color.clear)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            codex.deleteThread(thread)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            renamingThread = thread
                            renameText = thread.title
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    connectionIndicator
                }
                .accessibilityLabel(connectionTitle)

                Button {
                    codex.refreshThreads()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!codex.isConnected || codex.isLoadingThreads)
                .accessibilityLabel("Refresh agents")

                Button {
                    codex.startNewThread()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!codex.isConnected)
                .accessibilityLabel("New agent")
            }
        }
        .refreshable {
            codex.refreshThreads()
        }
        .alert("Rename Agent", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let renamingThread else { return }
                codex.renameThread(renamingThread, name: renameText)
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 10) {
            connectionDot

            VStack(alignment: .leading, spacing: 2) {
                Text(connectionTitle)
                    .font(.subheadline.weight(.semibold))
                if let lastError = codex.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(codex.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if codex.connectionState == .connecting {
                ProgressView()
            } else {
                Button(codex.isConnected ? "Reconnect" : "Connect") {
                    codex.connect()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionIndicator: some View {
        ZStack {
            Circle()
                .fill(connectionColor.opacity(0.16))
            connectionDot
        }
        .frame(width: 28, height: 28)
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 9, height: 9)
    }

    private var connectionTitle: String {
        switch codex.connectionState {
        case .connected:
            codex.isWorking ? "Codex is working" : "Connected"
        case .connecting:
            "Connecting"
        case .reconnecting:
            "Reconnecting"
        case .disconnected:
            "Disconnected"
        }
    }

    private var connectionIcon: String {
        switch codex.connectionState {
        case .connected:
            codex.isWorking ? "bolt.fill" : "checkmark.circle.fill"
        case .connecting, .reconnecting:
            "antenna.radiowaves.left.and.right"
        case .disconnected:
            "xmark.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch codex.connectionState {
        case .connected:
            codex.isWorking ? .orange : .green
        case .connecting, .reconnecting:
            .blue
        case .disconnected:
            .red
        }
    }
}

struct CodexThreadRow: View {
    let thread: CodexThreadSummary

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 5) {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    if let gitSummary = thread.gitSummary {
                        Label(gitSummary, systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if !thread.projectName.isEmpty {
                        Label(thread.projectName, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            statusBadge
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
            }

            Text(thread.statusLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.14), in: Capsule())
    }

    private var accessibilityLabel: String {
        [
            thread.title,
            thread.statusLabel,
            thread.gitSummary
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: ", ")
    }

    private var statusColor: Color {
        switch thread.status {
        case "blocked", "waiting_for_input", "needs_input":
            .red
        case "active", "running", "in_progress":
            .orange
        case "done", "completed":
            .green
        case "idle":
            .secondary
        case "error", "failed":
            .red
        default:
            .secondary
        }
    }

    private var isWorking: Bool {
        switch thread.status {
        case "active", "running", "in_progress":
            true
        default:
            false
        }
    }
}

struct CodexThreadDetailView: View {
    @Environment(CodexConnection.self) private var codex
    let thread: CodexThreadSummary
    @State private var prompt = ""
    @State private var isNearBottom = true
    @State private var showGitSheet = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGitSheet = true
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .disabled(!codex.isConnected)
                .accessibilityLabel("Git actions")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomInputBar
        }
        .sheet(isPresented: $showGitSheet) {
            GitActionsSheet(thread: thread, codex: codex)
        }
        .onAppear {
            codex.openThread(thread)
        }
    }

    @ViewBuilder
    private var bottomInputBar: some View {
        if let pending = codex.pendingInput {
            PendingInputBar(pending: pending, codex: codex)
        } else {
            composer
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if codex.isLoadingThread && codex.entries.isEmpty {
                        ProgressView("Loading transcript")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if codex.entries.isEmpty {
                        ContentUnavailableView(
                            "No transcript",
                            systemImage: "terminal",
                            description: Text("Send a message to start this agent.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }

                    ForEach(codex.entries) { entry in
                        CodexEntryRow(entry: entry)
                            .id(entry.id)
                    }

                    if codex.isWorking {
                        WorkingTranscriptIndicator(startedAt: codex.workingStartedAt)
                            .id("working-indicator")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                        .onAppear { isNearBottom = true }
                        .onDisappear { isNearBottom = false }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .background(Color(.systemBackground))
            .onChange(of: codex.transcriptRevision) { _, _ in
                guard isNearBottom else { return }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: codex.isWorking) { _, _ in
                guard isNearBottom else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Codex", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
                .disabled(!codex.isConnected)

            Button {
                let text = prompt
                prompt = ""
                codex.sendPrompt(text)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background { InputAccessorySurface() }
    }

    private var canSend: Bool {
        codex.isConnected && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
        if animated {
            withAnimation(.snappy(duration: 0.2), action)
        } else {
            action()
        }
    }
}

struct InputAccessorySurface: View {
    var body: some View {
        Color(.systemBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 1)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20,
                    style: .continuous
                )
            )
    }
}

struct GitActionsSheet: View {
    let thread: CodexThreadSummary
    let codex: CodexConnection
    @Environment(\.dismiss) private var dismiss
    @State private var commitMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    infoRow("Folder", thread.projectName)
                    infoRow("Path", thread.cwd)
                    if let branch = thread.branch, !branch.isEmpty {
                        infoRow("Branch", branch)
                    }
                    if let commitsToPush = thread.commitsToPush {
                        infoRow("To push", "\(commitsToPush)")
                    }
                }

                Section {
                    Button {
                        send(gitInspectPrompt)
                    } label: {
                        Label("Inspect Changes", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        send(commitMessagePrompt)
                    } label: {
                        Label("Generate Commit Message", systemImage: "text.badge.checkmark")
                    }
                } footer: {
                    Text("These actions ask the open Codex agent to run git in this workspace.")
                }

                Section("Commit") {
                    TextField("Commit message", text: $commitMessage, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)

                    Button {
                        send(commitPrompt)
                    } label: {
                        Label("Commit Changes", systemImage: "checkmark.seal")
                    }
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    Button {
                        send(pushPrompt)
                    } label: {
                        Label("Push Branch", systemImage: "arrow.up.circle")
                    }

                    Button {
                        send(commitAndPushPrompt)
                    } label: {
                        Label("Commit and Push", systemImage: "paperplane")
                    }
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 18)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func send(_ prompt: String) {
        codex.sendPrompt(prompt)
        dismiss()
    }

    private var gitInspectPrompt: String {
        """
        Inspect the git state for this workspace. Run focused git commands like `git status --short --branch`, summarize changed files, untracked files, branch/ahead state, and whether it is ready to commit or push. Do not commit or push yet.
        """
    }

    private var commitMessagePrompt: String {
        """
        Inspect the current git diff and propose one concise commit message. Do not commit yet. Return the message plainly first, then a short note about why it fits.
        """
    }

    private var commitPrompt: String {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Commit the current intended changes with this commit message:
        \(message)

        Use the repo's normal commit workflow. Review `git status --short --branch` first, include only relevant changed files, and do not push.
        """
    }

    private var pushPrompt: String {
        """
        Check the current branch and push it to its upstream. If there is no upstream, explain the safest push command before running it.
        """
    }

    private var commitAndPushPrompt: String {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Review the current git state, commit the intended changes with this commit message, then push the branch:
        \(message)

        Use the repo's normal commit workflow and avoid unrelated files.
        """
    }
}

struct PendingInputBar: View {
    let pending: PendingCodexInput
    @Bindable var codex: CodexConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.prompt)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Response", text: $codex.inputAnswer)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))

                Button {
                    codex.answerPendingInput(codex.inputAnswer)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(canSend ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send response")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { InputAccessorySurface() }
    }

    private var canSend: Bool {
        !codex.inputAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CodexEntryRow: View {
    let entry: CodexEntry

    var body: some View {
        Group {
            switch entry.kind {
            case .user:
                HStack {
                    Spacer(minLength: 44)
                    MarkdownText(entry.text, foregroundStyle: .white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                }

            case .assistant:
                MarkdownText(entry.text)

            case .command:
                CommandRunView(entry: entry)

            case .exploration:
                ExplorationRunView(entry: entry)

            case .tool:
                ToolRunView(entry: entry)

            case .status:
                if entry.title.hasPrefix("Worked for") {
                    WorkedDivider(title: entry.title)
                } else if !entry.text.isEmpty {
                    DisclosureGroup {
                        MarkdownText(entry.text)
                            .padding(.top, 6)
                    } label: {
                        Text(entry.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

            case .output:
                if !entry.text.isEmpty {
                    CodeBlockView(text: entry.text)
                }

            case .error:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    MarkdownText(entry.text.isEmpty ? entry.title : entry.text, foregroundStyle: .red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExplorationRunView: View {
    let entry: CodexEntry

    private var items: [ExplorationDisplayItem] {
        entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { ExplorationDisplayItem(String($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ExplorationTimelineRow(
                        item: item,
                        isLast: index == items.indices.last
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ExplorationTimelineRow: View {
    let item: ExplorationDisplayItem
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Circle()
                    .fill(item.tint.opacity(0.22))
                    .overlay {
                        Circle()
                            .stroke(item.tint.opacity(0.45), lineWidth: 1)
                    }
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                }
            }
            .frame(width: 12)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.action)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .padding(.bottom, isLast ? 0 : 7)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExplorationDisplayItem {
    let action: String
    let detail: String

    init(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }) {
            self.action = String(trimmed[..<firstSpace])
            self.detail = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespaces)
        } else {
            self.action = trimmed
            self.detail = ""
        }
    }

    var tint: Color {
        switch action {
        case "Read":
            .cyan
        case "Search", "Find":
            .blue
        case "List":
            .purple
        default:
            .secondary
        }
    }
}

struct CommandRunView: View {
    @Bindable var entry: CodexEntry
    private let previewLimit = 4

    var body: some View {
        Group {
            if entry.detail.isEmpty {
                commandLabel
            } else {
                DisclosureGroup(isExpanded: $entry.isExpanded) {
                    CodeBlockView(text: entry.detail)
                        .padding(.top, 8)
                } label: {
                    commandLabel
                }
            }
        }
        .padding(.vertical, 3)
        .tint(Color.secondary.opacity(0.58))
    }

    private var commandLabel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Ran")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ShellCommandText(command: entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(entry.isExpanded ? nil : 2)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }

            if !entry.detail.isEmpty, !entry.isExpanded {
                CommandOutputPreview(text: entry.detail, limit: previewLimit)
            }
        }
        .contentShape(Rectangle())
    }
}

struct WorkingTranscriptIndicator: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text(label(at: context.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Agent working")
    }

    private func label(at date: Date) -> String {
        guard let startedAt else { return "Working" }
        return "Working (\(Self.durationString(from: startedAt, to: date)))"
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
}

struct ShellCommandText: View {
    let command: String

    var body: some View {
        tokens.indices.reduce(Text("")) { partial, index in
            let token = tokens[index]
            let separator = index == tokens.startIndex ? Text("") : Text(" ")
            return partial + separator + Text(token.text).foregroundColor(token.role.color)
        }
    }

    private var tokens: [ShellCommandToken] {
        var expectsCommand = true
        return Self.tokenize(command).map { text in
            let role: ShellCommandTokenRole
            if Self.isShellOperator(text) {
                role = .operatorToken
                expectsCommand = true
            } else if expectsCommand, Self.isEnvironmentAssignment(text) {
                role = .environment
            } else if expectsCommand {
                role = .command
                expectsCommand = false
            } else if text.hasPrefix("-") {
                role = .flag
            } else if Self.isQuoted(text) {
                role = .string
            } else if Self.looksLikePath(text) {
                role = .path
            } else {
                role = .plain
            }
            return ShellCommandToken(text: text, role: role)
        }
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }

            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
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

    private static func isShellOperator(_ token: String) -> Bool {
        ["&&", "||", "|", ";", ">", ">>", "<", "2>", "2>>"].contains(token)
    }

    private static func isQuoted(_ token: String) -> Bool {
        (token.hasPrefix("\"") && token.hasSuffix("\""))
            || (token.hasPrefix("'") && token.hasSuffix("'"))
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let key = token[..<equals]
        return key.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    private static func looksLikePath(_ token: String) -> Bool {
        token == "."
            || token == ".."
            || token.hasPrefix("/")
            || token.hasPrefix("./")
            || token.hasPrefix("../")
            || token.hasPrefix("~/")
            || token.contains("/")
    }
}

struct ShellCommandToken {
    let text: String
    let role: ShellCommandTokenRole
}

enum ShellCommandTokenRole {
    case command
    case flag
    case string
    case path
    case environment
    case operatorToken
    case plain

    var color: Color {
        switch self {
        case .command:
            Color(red: 0.48, green: 0.66, blue: 0.86)
        case .flag:
            Color(red: 0.80, green: 0.50, blue: 0.48)
        case .string:
            Color(red: 0.55, green: 0.70, blue: 0.48)
        case .path:
            Color(red: 0.48, green: 0.68, blue: 0.74)
        case .environment:
            Color(red: 0.64, green: 0.56, blue: 0.78)
        case .operatorToken:
            Color.secondary.opacity(0.72)
        case .plain:
            Color.primary.opacity(0.86)
        }
    }
}

struct CommandOutputPreview: View {
    let text: String
    let limit: Int

    private var visibleLines: [String] {
        Array(lines.prefix(limit))
    }

    private var hiddenCount: Int {
        max(0, lines.count - visibleLines.count)
    }

    private var lines: [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    var body: some View {
        if !visibleLines.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("└")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.65))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if hiddenCount > 0 {
                        Text("… +\(hiddenCount) lines")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }
                }
            }
            .padding(.leading, 28)
            .textSelection(.enabled)
        }
    }
}

struct ToolRunView: View {
    @Bindable var entry: CodexEntry

    var body: some View {
        Group {
            if entry.detail.isEmpty {
                toolLabel
            } else {
                DisclosureGroup(isExpanded: $entry.isExpanded) {
                    MarkdownText(entry.detail)
                        .padding(.top, 8)
                } label: {
                    toolLabel
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var toolLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
            Text(entry.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct WorkedDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

struct MarkdownText: View {
    let text: String
    var foregroundStyle: Color = .primary

    init(_ text: String, foregroundStyle: Color = .primary) {
        self.text = text
        self.foregroundStyle = foregroundStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .code(let code):
                    CodeBlockView(text: code)
                case .heading(let line):
                    InlineMarkdownText(line)
                        .font(.headline)
                        .foregroundStyle(foregroundStyle)
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        InlineMarkdownText(line)
                            .foregroundStyle(foregroundStyle)
                    }
                case .paragraph(let line):
                    InlineMarkdownText(line)
                        .foregroundStyle(foregroundStyle)
                }
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }

    private var blocks: [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if isInCodeBlock {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                }
                isInCodeBlock.toggle()
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
            } else if line.isEmpty {
                continue
            } else if line.hasPrefix("### ") {
                result.append(.heading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                result.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                result.append(.heading(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                result.append(.paragraph(rawLine))
            }
        }

        if !codeLines.isEmpty {
            result.append(.code(codeLines.joined(separator: "\n")))
        }
        return result
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(String)
    case bullet(String)
    case code(String)
}

struct InlineMarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        composed
    }

    private var composed: Text {
        inlineSegments.reduce(Text("")) { partial, segment in
            switch segment {
            case .plain(let value):
                partial + Text(value)
            case .bold(let value):
                partial + Text(value).bold()
            case .code(let value):
                partial + Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
        }
    }

    private var inlineSegments: [InlineMarkdownSegment] {
        var segments: [InlineMarkdownSegment] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            let nextCode = remaining.firstIndex(of: "`")
            let nextBold = remaining.range(of: "**")?.lowerBound

            if let nextCode, nextBold.map({ nextCode < $0 }) ?? true {
                appendPlain(String(remaining[..<nextCode]), to: &segments)
                let afterMarker = remaining.index(after: nextCode)
                if let close = remaining[afterMarker...].firstIndex(of: "`") {
                    segments.append(.code(String(remaining[afterMarker..<close])))
                    remaining = remaining[remaining.index(after: close)...]
                } else {
                    segments.append(.plain(String(remaining[nextCode...])))
                    break
                }
            } else if let nextBold {
                appendPlain(String(remaining[..<nextBold]), to: &segments)
                let afterMarker = remaining.index(nextBold, offsetBy: 2)
                if let closeRange = remaining[afterMarker...].range(of: "**") {
                    let value = String(remaining[afterMarker..<closeRange.lowerBound])
                    if value.isEmpty {
                        segments.append(.plain("****"))
                    } else {
                        segments.append(.bold(value))
                    }
                    remaining = remaining[closeRange.upperBound...]
                } else {
                    segments.append(.plain(String(remaining[nextBold...])))
                    break
                }
            } else {
                appendPlain(String(remaining), to: &segments)
                break
            }
        }

        return segments
    }

    private func appendPlain(_ value: String, to segments: inout [InlineMarkdownSegment]) {
        guard !value.isEmpty else { return }
        segments.append(.plain(value))
    }
}

enum InlineMarkdownSegment {
    case plain(String)
    case bold(String)
    case code(String)
}

struct CodeBlockView: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CodexSettingsView: View {
    @Environment(CodexConnection.self) private var codex
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var codex = codex

        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Server", text: $codex.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token", text: $codex.bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Working directory", text: $codex.cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let lastError = codex.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(codex.isConnected ? "Reconnect" : "Connect") {
                        codex.connect()
                    }
                    Button("Disconnect", role: .destructive) {
                        codex.disconnect()
                    }
                    .disabled(!codex.isConnected)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        codex.saveSettings()
                        dismiss()
                    }
                }
            }
        }
    }
}
