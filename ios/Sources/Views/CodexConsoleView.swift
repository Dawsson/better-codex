import PhotosUI
import SwiftUI
import UIKit

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
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedImages: [CodexImageAttachment] = []
    @State private var isProcessingImages = false
    @State private var imageError: String?
    @State private var isNearBottom = true
    @State private var showFileBrowser = false
    @State private var codeReferences: [CodeReferenceSnippet] = []

    var body: some View {
        VStack(spacing: 0) {
            transcript
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFileBrowser = true
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(!codex.isConnected)
                .accessibilityLabel("Browse files")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomInputBar
        }
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserSheet(
                rootPath: thread.cwd.isEmpty ? codex.cwd : thread.cwd,
                references: $codeReferences
            )
            .environment(codex)
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
                        CodexEntryRow(entry: entry, revision: codex.transcriptRevision)
                            .id("\(entry.id)-\(codex.transcriptRevision)")
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
        VStack(alignment: .leading, spacing: 8) {
            if !selectedImages.isEmpty {
                SelectedImageStrip(images: selectedImages) { image in
                    selectedImages.removeAll { $0.id == image.id }
                    if selectedImages.isEmpty {
                        selectedPhotoItems = []
                    }
                }
            }

            if let imageError {
                Text(imageError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            if !codex.queuedMessages.isEmpty {
                QueuedMessagesStrip(messages: codex.queuedMessages)
            }

            if !codeReferences.isEmpty {
                CodeReferenceStrip(references: $codeReferences) {
                    showFileBrowser = true
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 4,
                    matching: .images
                ) {
                    Group {
                        if isProcessingImages {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .disabled(!codex.isConnected || isProcessingImages)
                .accessibilityLabel("Attach image")

                TextField("Message Codex", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
                    .disabled(!codex.isConnected)

                Button {
                    let text = promptWithReferences(prompt)
                    let images = selectedImages
                    prompt = ""
                    selectedImages = []
                    selectedPhotoItems = []
                    codeReferences.removeAll()
                    codex.sendPrompt(text, images: images)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(sendColor, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(codex.isWorking ? "Queue message" : "Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea(edges: .bottom)
                InputAccessorySurface()
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            Task {
                await loadSelectedImages(from: items)
            }
        }
    }

    private var canSend: Bool {
        codex.isConnected
            && !isProcessingImages
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty || !codeReferences.isEmpty)
    }

    private var sendColor: Color {
        guard canSend else { return Color.secondary.opacity(0.35) }
        return codex.isWorking ? .orange : .blue
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

    private func promptWithReferences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !codeReferences.isEmpty else { return trimmed }
        let references = codeReferences.map { reference in
            """
            File reference: \(reference.location)
            ```\(languageForPath(reference.path))
            \(reference.text)
            ```
            """
        }.joined(separator: "\n\n")
        if trimmed.isEmpty {
            return references
        }
        return "\(trimmed)\n\nReferenced code:\n\n\(references)"
    }

    @MainActor
    private func loadSelectedImages(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else {
            selectedImages = []
            imageError = nil
            return
        }

        isProcessingImages = true
        imageError = nil
        var attachments: [CodexImageAttachment] = []

        for item in items.prefix(4) {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let attachment = ComposerImageProcessor.attachment(from: data) {
                    attachments.append(attachment)
                }
            } catch {
                imageError = "Couldn't attach one image."
            }
        }

        selectedImages = attachments
        if attachments.isEmpty {
            imageError = "Couldn't attach that image."
        }
        isProcessingImages = false
    }
}

struct InputAccessorySurface: View {
    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 20,
            style: .continuous
        )
        .fill(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }
}

struct QueuedMessagesStrip: View {
    let messages: [QueuedCodexMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.caption.weight(.semibold))
                Text(messages.count == 1 ? "1 message queued" : "\(messages.count) messages queued")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)

            ForEach(messages.prefix(2)) { message in
                Text(label(for: message))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func label(for message: QueuedCodexMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, message.imageCount > 0 {
            return "\(text)  +\(message.imageCount) image\(message.imageCount == 1 ? "" : "s")"
        }
        if !text.isEmpty {
            return text
        }
        return "\(message.imageCount) image\(message.imageCount == 1 ? "" : "s")"
    }
}

struct CodeReferenceStrip: View {
    @Binding var references: [CodeReferenceSnippet]
    let browseAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("\(references.count) code reference\(references.count == 1 ? "" : "s")", systemImage: "curlybraces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Button("Add") {
                    browseAction()
                }
                .font(.caption.weight(.semibold))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(references) { reference in
                        HStack(spacing: 6) {
                            Text(reference.location)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Button {
                                references.removeAll { $0.id == reference.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            Color.blue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

struct FileBrowserSheet: View {
    @Environment(CodexConnection.self) private var codex
    let rootPath: String
    @Binding var references: [CodeReferenceSnippet]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemoteDirectoryView(
                path: rootPath,
                rootPath: rootPath,
                references: $references
            )
            .environment(codex)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(references.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(references.isEmpty ? Color.secondary : Color.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(references.count) code references")
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct RemoteDirectoryView: View {
    @Environment(CodexConnection.self) private var codex
    let path: String
    let rootPath: String
    @Binding var references: [CodeReferenceSnippet]
    @State private var searchText = ""
    @State private var expandedPaths: Set<String> = []

    private var rootEntries: [RemoteFileNode] {
        codex.fileBrowserEntriesByPath[path] ?? []
    }

    private var visibleRows: [RemoteFileTreeRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [RemoteFileTreeRow] = []
        appendRows(from: path, depth: 0, query: query, rows: &rows)
        return rows
    }

    private var isLoadingRoot: Bool {
        codex.fileBrowserLoadingPaths.contains(path)
    }

    private func appendRows(
        from directoryPath: String,
        depth: Int,
        query: String,
        rows: inout [RemoteFileTreeRow]
    ) {
        let entries = codex.fileBrowserEntriesByPath[directoryPath] ?? []
        for entry in entries {
            let matches = query.isEmpty
                || entry.name.localizedCaseInsensitiveContains(query)
                || entry.path.localizedCaseInsensitiveContains(query)
            let isExpanded = expandedPaths.contains(entry.path)
            if matches {
                rows.append(RemoteFileTreeRow(entry: entry, depth: depth, isExpanded: isExpanded))
            }
            if entry.isDirectory, isExpanded || !query.isEmpty {
                appendRows(from: entry.path, depth: depth + 1, query: query, rows: &rows)
            }
        }
    }

    var body: some View {
        List {
            if isLoadingRoot, rootEntries.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading files")
                        .foregroundStyle(.secondary)
                }
            } else if visibleRows.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No files" : "No matches",
                    systemImage: "folder",
                    description: Text(relativePath(path).isEmpty ? path : relativePath(path))
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(visibleRows) { row in
                    if row.entry.isDirectory {
                        Button {
                            toggleDirectory(row.entry.path)
                        }
                        label: {
                            RemoteFileRow(
                                entry: row.entry,
                                rootPath: rootPath,
                                depth: row.depth,
                                isExpanded: row.isExpanded,
                                isLoading: codex.fileBrowserLoadingPaths.contains(row.entry.path)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            RemoteCodeViewer(
                                path: row.entry.path,
                                rootPath: rootPath,
                                references: $references
                            )
                            .environment(codex)
                        } label: {
                            RemoteFileRow(entry: row.entry, rootPath: rootPath, depth: row.depth)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find file")
        .navigationTitle(relativePath(path).isEmpty ? URL(fileURLWithPath: path).lastPathComponent : relativePath(path))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            codex.loadDirectory(path: path, force: true)
        }
        .overlay(alignment: .bottom) {
            if let error = codex.fileBrowserError {
                ErrorToast(message: error) {
                    codex.clearFileBrowserError()
                }
                .padding()
            }
        }
        .onAppear {
            codex.loadDirectory(path: path)
        }
    }

    private func toggleDirectory(_ directoryPath: String) {
        if expandedPaths.contains(directoryPath) {
            expandedPaths.remove(directoryPath)
        } else {
            expandedPaths.insert(directoryPath)
            codex.loadDirectory(path: directoryPath)
        }
    }

    private func relativePath(_ value: String) -> String {
        value.relativePath(from: rootPath)
    }
}

private struct RemoteFileTreeRow: Identifiable {
    var id: String { entry.path }
    let entry: RemoteFileNode
    let depth: Int
    let isExpanded: Bool
}

struct RemoteFileRow: View {
    let entry: RemoteFileNode
    let rootPath: String
    var depth = 0
    var isExpanded = false
    var isLoading = false

    var body: some View {
        HStack(spacing: 11) {
            Color.clear
                .frame(width: CGFloat(depth) * 16)

            if entry.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Color.clear
                    .frame(width: 12)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22)
            } else {
                Image(systemName: entry.iconName)
                    .font(.body)
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(entry.path.relativePath(from: rootPath))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let size = entry.size, !entry.isDirectory {
                Text(byteCount(size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func byteCount(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

struct RemoteCodeViewer: View {
    @Environment(CodexConnection.self) private var codex
    let path: String
    let rootPath: String
    @Binding var references: [CodeReferenceSnippet]
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var showAdded = false

    private var document: RemoteFileDocument? {
        codex.fileBrowserDocumentsByPath[path]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let document {
                SelectableCodeTextView(
                    text: document.text,
                    language: languageForPath(path),
                    selectedRange: $selectedRange
                )
                .overlay(alignment: .bottomLeading) {
                    if document.isTruncated {
                        Label("File preview truncated", systemImage: "scissors")
                            .font(.caption.weight(.medium))
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                    }
                }
            } else if codex.fileBrowserLoadingFiles.contains(path) {
                ProgressView("Opening file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No preview",
                    systemImage: "doc.text",
                    description: Text(path.relativePath(from: rootPath))
                )
            }
        }
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    addCurrentSelection()
                } label: {
                    Label("Add Selection", systemImage: "plus.square.on.square")
                }
                .disabled(!canAddSelection)

                Spacer()

                Button {
                    addWholeFileReference()
                } label: {
                    Label("File", systemImage: "doc.badge.plus")
                }
            }
        }
        .overlay(alignment: .top) {
            if showAdded {
                Label("Reference added", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            codex.loadFile(path: path)
        }
    }

    private var canAddSelection: Bool {
        selectedRange.length > 0 && document != nil
    }

    private func addCurrentSelection() {
        guard let document,
              let snippet = CodeSelectionMapper.snippet(
                in: document.text,
                path: path.relativePath(from: rootPath),
                range: selectedRange
              ) else { return }
        references.append(snippet)
        flashAdded()
    }

    private func addWholeFileReference() {
        guard let document else { return }
        let lines = max(1, document.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let text = String(document.text.prefix(20_000))
        references.append(
            CodeReferenceSnippet(
                path: path.relativePath(from: rootPath),
                startLine: 1,
                endLine: lines,
                text: text
            )
        )
        flashAdded()
    }

    private func flashAdded() {
        HapticManager.shared.sent()
        withAnimation(.snappy(duration: 0.16)) {
            showAdded = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.snappy(duration: 0.16)) {
                showAdded = false
            }
        }
    }
}

struct SelectableCodeTextView: UIViewRepresentable {
    let text: String
    let language: String
    @Binding var selectedRange: NSRange

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 40, right: 12)
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.keyboardDismissMode = .interactive
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            textView.attributedText = CodeAttributedStringBuilder.attributed(text, language: language)
            textView.selectedRange = selectedRange
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedRange: $selectedRange)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var selectedRange: NSRange
        var lastText = ""

        init(selectedRange: Binding<NSRange>) {
            self._selectedRange = selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selectedRange = textView.selectedRange
        }
    }
}

enum CodeSelectionMapper {
    static func snippet(in text: String, path: String, range: NSRange) -> CodeReferenceSnippet? {
        guard range.length > 0,
              let swiftRange = Range(range, in: text) else { return nil }
        let selectedText = String(text[swiftRange]).trimmingCharacters(in: .newlines)
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let startLine = lineNumber(at: range.location, in: text)
        let endLine = lineNumber(at: range.location + max(0, range.length - 1), in: text)
        return CodeReferenceSnippet(
            path: path,
            startLine: startLine,
            endLine: max(startLine, endLine),
            text: selectedText
        )
    }

    private static func lineNumber(at utf16Offset: Int, in text: String) -> Int {
        let clamped = max(0, min(utf16Offset, text.utf16.count))
        let index = String.Index(utf16Offset: clamped, in: text)
        return text[..<index].reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
    }
}

enum CodeAttributedStringBuilder {
    static func attributed(_ code: String, language: String) -> NSAttributedString {
        let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: baseFont,
                .foregroundColor: UIColor.label
            ]
        )

        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        color(pattern: #"(?m)^\s*(//|#).*$"#, in: code, range: fullRange, color: .secondaryLabel, result: result)
        color(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, in: code, range: fullRange, color: .systemGreen, result: result)
        color(pattern: #"\b\d+(?:\.\d+)?\b"#, in: code, range: fullRange, color: .systemOrange, result: result)
        color(pattern: keywordPattern(for: language), in: code, range: fullRange, color: .systemBlue, result: result)
        return result
    }

    private static func color(
        pattern: String,
        in code: String,
        range: NSRange,
        color: UIColor,
        result: NSMutableAttributedString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: code, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func keywordPattern(for language: String) -> String {
        switch language {
        case "swift":
            return #"\b(actor|any|as|async|await|case|catch|class|enum|extension|final|for|func|guard|if|import|in|let|private|protocol|public|return|self|static|struct|switch|throw|try|var|while)\b"#
        case "js", "jsx", "ts", "tsx":
            return #"\b(async|await|break|case|catch|class|const|export|extends|function|if|import|let|new|return|switch|throw|try|type|var|while)\b"#
        default:
            return #"\b(class|const|def|enum|for|func|function|if|import|let|return|struct|var|while)\b"#
        }
    }
}

struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

func languageForPath(_ path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift":
        return "swift"
    case "js", "mjs", "cjs":
        return "js"
    case "jsx":
        return "jsx"
    case "ts":
        return "ts"
    case "tsx":
        return "tsx"
    case "json":
        return "json"
    case "md", "markdown":
        return "markdown"
    case "sh", "bash", "zsh":
        return "sh"
    case "yml", "yaml":
        return "yaml"
    case "html", "htm":
        return "html"
    case "css":
        return "css"
    case "py":
        return "python"
    case "rs":
        return "rust"
    case "go":
        return "go"
    default:
        return ""
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
        .background {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea(edges: .bottom)
                InputAccessorySurface()
            }
        }
    }

    private var canSend: Bool {
        !codex.inputAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CodexEntryRow: View {
    let entry: CodexEntry
    let revision: Int

    var body: some View {
        let _ = revision

        Group {
            switch entry.kind {
            case .user:
                UserMessageView(entry: entry)

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

            case .diff:
                DiffChangeView(entry: entry)

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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
        }
    }
}

struct DiffChangeView: View {
    @Bindable var entry: CodexEntry

    private var diffText: String {
        entry.detail.isEmpty ? entry.text : entry.detail
    }

    private var files: [ParsedDiffFile] {
        ParsedDiffFile.parse(diffText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    entry.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(entry.title.isEmpty ? "Changes" : entry.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !entry.text.isEmpty, entry.text != entry.detail {
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if entry.isExpanded {
                diffContent
                    .padding(.top, 8)
                    .clipped()
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var diffContent: some View {
        if files.isEmpty {
            CodeBlockView(text: diffText, language: "diff")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(files) { file in
                    ParsedDiffFileView(file: file)
                }
            }
            .clipped()
        }
    }
}

struct ParsedDiffFile: Identifiable {
    let id = UUID()
    var path: String
    var lines: [ParsedDiffLine]

    var addedCount: Int {
        lines.filter { $0.kind == .addition }.count
    }

    var removedCount: Int {
        lines.filter { $0.kind == .removal }.count
    }

    static func parse(_ text: String) -> [ParsedDiffFile] {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard rawLines.contains(where: { $0.hasPrefix("diff --git ") || $0.hasPrefix("@@ ") || $0.hasPrefix("--- ") || $0.hasPrefix("+++ ") }) else {
            return []
        }

        var files: [ParsedDiffFile] = []
        var currentPath = "Changes"
        var currentLines: [ParsedDiffLine] = []
        var sawFileHeader = false

        func flush() {
            guard !currentLines.isEmpty else { return }
            files.append(ParsedDiffFile(path: currentPath, lines: currentLines))
            currentLines = []
        }

        for line in rawLines {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = pathFromGitHeader(line) ?? "Changes"
                sawFileHeader = true
                continue
            }

            if line.hasPrefix("+++ ") {
                if let path = pathFromMarker(line), path != "/dev/null" {
                    currentPath = path
                    sawFileHeader = true
                }
                continue
            }

            if line.hasPrefix("--- ") {
                if !sawFileHeader, let path = pathFromMarker(line), path != "/dev/null" {
                    currentPath = path
                }
                continue
            }

            if line.hasPrefix("@@") {
                currentLines.append(ParsedDiffLine(text: line, kind: .hunk))
            } else if line.hasPrefix("+") {
                currentLines.append(ParsedDiffLine(text: line, kind: .addition))
            } else if line.hasPrefix("-") {
                currentLines.append(ParsedDiffLine(text: line, kind: .removal))
            } else if line.hasPrefix("index ") || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ") {
                currentLines.append(ParsedDiffLine(text: line, kind: .metadata))
            } else if !line.isEmpty {
                currentLines.append(ParsedDiffLine(text: line, kind: .context))
            }
        }

        flush()
        return files
    }

    private static func pathFromGitHeader(_ line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        return cleanPath(parts[3])
    }

    private static func pathFromMarker(_ line: String) -> String? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return cleanPath(parts[1])
    }

    private static func cleanPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "a/", with: "", options: [.anchored])
            .replacingOccurrences(of: "b/", with: "", options: [.anchored])
    }
}

struct ParsedDiffLine: Identifiable {
    let id = UUID()
    var text: String
    var kind: ParsedDiffLineKind
}

enum ParsedDiffLineKind {
    case addition
    case removal
    case hunk
    case metadata
    case context

    var foreground: Color {
        switch self {
        case .addition:
            return .green
        case .removal:
            return .red
        case .hunk:
            return .blue
        case .metadata:
            return .secondary
        case .context:
            return .primary
        }
    }

    var background: Color {
        switch self {
        case .addition:
            return Color.green.opacity(0.10)
        case .removal:
            return Color.red.opacity(0.10)
        case .hunk:
            return Color.blue.opacity(0.10)
        case .metadata:
            return Color.secondary.opacity(0.08)
        case .context:
            return Color.clear
        }
    }
}

struct ParsedDiffFileView: View {
    let file: ParsedDiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(file.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if file.addedCount > 0 {
                    Text("+\(file.addedCount)")
                        .foregroundStyle(.green)
                }
                if file.removedCount > 0 {
                    Text("-\(file.removedCount)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        Text(line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.kind.foreground)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind.background)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
            .background(Color(.tertiarySystemBackground).opacity(0.72))
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
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

enum ComposerImageProcessor {
    private static let dimensions: [CGFloat] = [1024, 768, 512]
    private static let maxEncodedBytes = 550_000
    private static let qualities: [CGFloat] = [0.72, 0.62, 0.54, 0.46]

    static func attachment(from data: Data) -> CodexImageAttachment? {
        guard let image = UIImage(data: data),
              let jpeg = compressedJPEGData(from: image) else {
            return nil
        }

        let encoded = jpeg.base64EncodedString()
        return CodexImageAttachment(
            url: "data:image/jpeg;base64,\(encoded)",
            detail: "low",
            dataBase64: encoded
        )
    }

    private static func compressedJPEGData(from image: UIImage) -> Data? {
        var fallback: Data?
        for dimension in dimensions {
            let resized = resizedImage(from: image, maxDimension: dimension)
            for quality in qualities {
                guard let data = resized.jpegData(compressionQuality: quality) else { continue }
                fallback = data
                if data.count <= maxEncodedBytes {
                    return data
                }
            }
        }
        return fallback
    }

    private static func resizedImage(from image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return normalizedImage(from: image) }

        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func normalizedImage(from image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private extension CodexImageAttachment {
    var uiImage: UIImage? {
        guard url.hasPrefix("data:image/"),
              let comma = url.firstIndex(of: ",") else {
            return nil
        }
        let encoded = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return UIImage(data: data)
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
                case .code(let code, let language):
                    CodeBlockView(text: code, language: language)
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
        var codeLanguage: String?
        var isInCodeBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if isInCodeBlock {
                    result.append(.code(codeLines.joined(separator: "\n"), codeLanguage))
                    codeLines.removeAll()
                    codeLanguage = nil
                } else {
                    codeLanguage = Self.codeLanguage(from: line)
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
            result.append(.code(codeLines.joined(separator: "\n"), codeLanguage))
        }
        return result
    }

    private static func codeLanguage(from fence: String) -> String? {
        let language = fence
            .dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)
        return language?.isEmpty == false ? language : nil
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(String)
    case bullet(String)
    case code(String, String?)
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

struct UserMessageView: View {
    @Bindable var entry: CodexEntry

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 44)

            VStack(alignment: .trailing, spacing: 7) {
                if !entry.images.isEmpty {
                    ImageAttachmentGrid(images: entry.images, alignment: .trailing)
                }

                if !entry.text.isEmpty {
                    MarkdownText(entry.text, foregroundStyle: .white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }
}

struct SelectedImageStrip: View {
    let images: [CodexImageAttachment]
    let remove: (CodexImageAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        ImageAttachmentThumbnail(image: image)
                            .frame(width: 72, height: 72)

                        Button {
                            remove(image)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.55))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove image")
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
        }
    }
}

struct ImageAttachmentGrid: View {
    let images: [CodexImageAttachment]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(104), spacing: 6), count: min(images.count, 2)),
            alignment: alignment,
            spacing: 6
        ) {
            ForEach(images) { image in
                ImageAttachmentThumbnail(image: image)
                    .frame(width: 104, height: 104)
            }
        }
    }
}

struct ImageAttachmentThumbnail: View {
    let image: CodexImageAttachment

    var body: some View {
        Group {
            if let uiImage = image.uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if image.url.hasPrefix("http://") || image.url.hasPrefix("https://") {
                AsyncImage(url: URL(string: image.url)) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .clipped()
        .accessibilityLabel("Attached image")
    }

    private var placeholder: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: "photo")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct CodeBlockView: View {
    let text: String
    var language: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            CodeHighlightText(text: text, language: language)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CodeHighlightText: View {
    let text: String
    let language: String?

    var body: some View {
        CodeHighlighter.highlight(text, language: language)
    }
}

enum CodeHighlighter {
    static func highlight(_ code: String, language: String?) -> Text {
        tokens(for: code, language: normalizedLanguage(language)).reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(token.role.color)
        }
    }

    private static func tokens(for code: String, language: String?) -> [CodeToken] {
        if language == "diff" || codeLooksLikeDiff(code) {
            return diffTokens(for: code)
        }
        if language == "json" {
            return scan(code, language: language)
        }
        return scan(code, language: language)
    }

    private static func scan(_ code: String, language: String?) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            let next = code.index(after: index)

            if character == "/" && next < code.endIndex && code[next] == "/" {
                let end = code[next...].firstIndex(of: "\n") ?? code.endIndex
                tokens.append(CodeToken(String(code[index..<end]), .comment))
                index = end
            } else if character == "#" && (language == "sh" || language == "bash" || language == "shell" || language == "zsh") {
                let end = code[next...].firstIndex(of: "\n") ?? code.endIndex
                tokens.append(CodeToken(String(code[index..<end]), .comment))
                index = end
            } else if character == "\"" || character == "'" {
                let end = stringEnd(in: code, from: index, quote: character)
                tokens.append(CodeToken(String(code[index..<end]), .string))
                index = end
            } else if character.isNumber {
                let end = numberEnd(in: code, from: index)
                tokens.append(CodeToken(String(code[index..<end]), .number))
                index = end
            } else if character == "." || character == "/" || character == "~" {
                let end = pathEnd(in: code, from: index)
                let value = String(code[index..<end])
                tokens.append(CodeToken(value, value.contains("/") ? .path : .plain))
                index = end
            } else if character == "-" {
                let end = wordEnd(in: code, from: index)
                let value = String(code[index..<end])
                tokens.append(CodeToken(value, value.hasPrefix("-") && value.count > 1 ? .flag : .operatorToken))
                index = end
            } else if isOperator(character) {
                tokens.append(CodeToken(String(character), .operatorToken))
                index = next
            } else if character.isLetter || character == "_" {
                let end = wordEnd(in: code, from: index)
                let value = String(code[index..<end])
                tokens.append(CodeToken(value, role(forWord: value, language: language)))
                index = end
            } else {
                tokens.append(CodeToken(String(character), .plain))
                index = next
            }
        }
        return tokens
    }

    private static func diffTokens(for code: String) -> [CodeToken] {
        code.components(separatedBy: .newlines).enumerated().flatMap { index, line in
            let role: CodeTokenRole
            if line.hasPrefix("+") {
                role = .addition
            } else if line.hasPrefix("-") {
                role = .deletion
            } else if line.hasPrefix("@@") {
                role = .keyword
            } else {
                role = .plain
            }
            let suffix = index == code.components(separatedBy: .newlines).indices.last ? "" : "\n"
            return [CodeToken(line + suffix, role)]
        }
    }

    private static func role(forWord word: String, language: String?) -> CodeTokenRole {
        if ["true", "false", "nil", "null", "undefined"].contains(word) {
            return .literal
        }
        if ["func", "let", "var", "struct", "class", "enum", "protocol", "extension", "import", "return", "if", "else", "for", "while", "switch", "case", "guard", "async", "await", "throws", "try", "private", "public", "static", "self", "in"].contains(word) {
            return .keyword
        }
        if ["function", "const", "let", "var", "import", "export", "from", "return", "if", "else", "for", "while", "switch", "case", "async", "await", "class", "type", "interface", "extends"].contains(word) {
            return .keyword
        }
        if ["git", "bun", "dev", "xcodebuild", "swift", "rg", "sed", "curl", "committer"].contains(word) {
            return .command
        }
        if language == "json" {
            return .plain
        }
        return .plain
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        switch language?.lowercased() {
        case "shell", "bash", "zsh", "sh", "console":
            "sh"
        case "js", "javascript":
            "javascript"
        case "ts", "typescript":
            "typescript"
        case "swift", "json", "diff":
            language?.lowercased()
        default:
            language?.lowercased()
        }
    }

    private static func codeLooksLikeDiff(_ code: String) -> Bool {
        code.components(separatedBy: .newlines).contains { line in
            line.hasPrefix("@@") || line.hasPrefix("diff --git")
        }
    }

    private static func stringEnd(in code: String, from start: String.Index, quote: Character) -> String.Index {
        var index = code.index(after: start)
        var escaped = false
        while index < code.endIndex {
            let character = code[index]
            index = code.index(after: index)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return index
            }
        }
        return code.endIndex
    }

    private static func numberEnd(in code: String, from start: String.Index) -> String.Index {
        var index = start
        while index < code.endIndex {
            let character = code[index]
            guard character.isNumber || character == "." || character == "_" else { break }
            index = code.index(after: index)
        }
        return index
    }

    private static func wordEnd(in code: String, from start: String.Index) -> String.Index {
        var index = start
        while index < code.endIndex {
            let character = code[index]
            guard character.isLetter || character.isNumber || character == "_" || character == "-" else { break }
            index = code.index(after: index)
        }
        return index
    }

    private static func pathEnd(in code: String, from start: String.Index) -> String.Index {
        var index = start
        while index < code.endIndex {
            let character = code[index]
            guard !character.isWhitespace && !["\"", "'", "`", ")", "]", "}"].contains(character) else { break }
            index = code.index(after: index)
        }
        return index
    }

    private static func isOperator(_ character: Character) -> Bool {
        ["=", "+", "*", "%", "!", "<", ">", "|", "&", ":", ",", ";", "(", ")", "{", "}", "[", "]"].contains(character)
    }
}

struct CodeToken {
    let text: String
    let role: CodeTokenRole

    init(_ text: String, _ role: CodeTokenRole) {
        self.text = text
        self.role = role
    }
}

enum CodeTokenRole {
    case plain
    case keyword
    case string
    case number
    case literal
    case comment
    case command
    case flag
    case path
    case operatorToken
    case addition
    case deletion

    var color: Color {
        switch self {
        case .plain:
            Color.primary.opacity(0.90)
        case .keyword:
            Color(red: 0.64, green: 0.56, blue: 0.86)
        case .string:
            Color(red: 0.48, green: 0.68, blue: 0.42)
        case .number, .literal:
            Color(red: 0.80, green: 0.50, blue: 0.48)
        case .comment:
            Color.secondary.opacity(0.78)
        case .command:
            Color(red: 0.45, green: 0.64, blue: 0.86)
        case .flag:
            Color(red: 0.82, green: 0.60, blue: 0.38)
        case .path:
            Color(red: 0.45, green: 0.68, blue: 0.74)
        case .operatorToken:
            Color.secondary.opacity(0.72)
        case .addition:
            Color(red: 0.34, green: 0.70, blue: 0.45)
        case .deletion:
            Color(red: 0.86, green: 0.40, blue: 0.40)
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
