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

                    if !thread.model.isEmpty {
                        Text(thread.model)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(thread.statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.14), in: Capsule())
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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
}

struct CodexThreadDetailView: View {
    @Environment(CodexConnection.self) private var codex
    let thread: CodexThreadSummary
    @State private var prompt = ""
    @State private var isNearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if codex.isWorking {
                    ProgressView()
                } else {
                    Button {
                        codex.openThread(thread)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload agent")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let pending = codex.pendingInput {
                PendingInputBar(pending: pending, codex: codex)
            }
        }
        .onAppear {
            codex.openThread(thread)
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 21))
                .disabled(!codex.isConnected)

            Button {
                let text = prompt
                prompt = ""
                codex.sendPrompt(text)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
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
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 21))

                Button {
                    codex.answerPendingInput(codex.inputAnswer)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send response")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
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

struct CommandRunView: View {
    @Bindable var entry: CodexEntry

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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private var commandLabel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !entry.title.isEmpty {
                    Text(entry.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(entry.isExpanded ? nil : 2)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
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
        let parts = text.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        return parts.indices.reduce(Text("")) { partial, index in
            let part = parts[index]
            guard !part.isEmpty else { return partial }
            if index.isMultiple(of: 2) {
                return partial + Text(part)
            }
            return partial + Text(part)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.cyan)
        }
    }
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
