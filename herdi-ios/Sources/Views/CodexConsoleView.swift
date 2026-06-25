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

    var body: some View {
        List {
            Section {
                connectionRow
            }

            Section("Open Agents") {
                if codex.isLoadingThreads && codex.threads.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading agents")
                            .foregroundStyle(.secondary)
                    }
                } else if codex.threads.isEmpty {
                    ContentUnavailableView(
                        codex.isConnected ? "No open agents" : "Connect to Codex",
                        systemImage: codex.isConnected ? "text.bubble" : "antenna.radiowaves.left.and.right",
                        description: Text(codex.isConnected ? "Start one from your phone or open a cx session on the Mac." : "Add the app-server token in Settings.")
                    )
                } else {
                    ForEach(codex.threads) { thread in
                        NavigationLink(value: thread) {
                            CodexThreadRow(thread: thread)
                        }
                    }
                }
            }
        }
        .navigationTitle("Better Codex")
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
    }

    private var connectionRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(connectionColor.opacity(0.16))
                Image(systemName: connectionIcon)
                    .font(.headline)
                    .foregroundStyle(connectionColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(connectionTitle)
                    .font(.headline)
                Text(codex.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(thread.statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                HStack(spacing: 8) {
                    Label(thread.projectName, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let gitSummary = thread.gitSummary {
                        Label(gitSummary, systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !thread.preview.isEmpty {
                    Text(thread.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(thread.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
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

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
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
                LazyVStack(alignment: .leading, spacing: 10) {
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: codex.entries.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Codex", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(!codex.isConnected)

            Button {
                let text = prompt
                prompt = ""
                codex.sendPrompt(text)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(!codex.isConnected || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = codex.entries.last else { return }
        withAnimation(.snappy(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct PendingInputBar: View {
    let pending: PendingCodexInput
    @Bindable var codex: CodexConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.prompt)
                .font(.footnote.weight(.medium))
            HStack {
                TextField("Response", text: $codex.inputAnswer)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    codex.answerPendingInput(codex.inputAnswer)
                }
                .disabled(codex.inputAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.ultraThickMaterial)
    }
}

struct CodexEntryRow: View {
    let entry: CodexEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch entry.kind {
        case .user: "person.crop.circle"
        case .assistant: "sparkles"
        case .command: "terminal"
        case .output: "text.alignleft"
        case .status: "circle.dotted"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .user: .blue
        case .assistant: .green
        case .command: .orange
        case .output: .secondary
        case .status: .secondary
        case .error: .red
        }
    }

    private var background: AnyShapeStyle {
        switch entry.kind {
        case .user:
            AnyShapeStyle(Color.blue.opacity(0.14))
        case .error:
            AnyShapeStyle(Color.red.opacity(0.14))
        case .command, .output:
            AnyShapeStyle(Color.secondary.opacity(0.12))
        default:
            AnyShapeStyle(Color.secondary.opacity(0.08))
        }
    }

    private var font: Font {
        switch entry.kind {
        case .command, .output:
            .system(.caption, design: .monospaced)
        default:
            .body
        }
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
