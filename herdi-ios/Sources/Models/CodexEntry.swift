import Foundation
import Observation

struct CodexThreadSummary: Identifiable, Hashable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var status: String
    var updatedAt: Date
    var model: String
    var branch: String?
    var commitsToPush: Int?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        let preview = json["preview"] as? String
        let name = json["name"] as? String
        let nickname = json["agentNickname"] as? String
        self.cwd = json["cwd"] as? String ?? ""
        self.preview = preview ?? ""
        let folderName = URL(fileURLWithPath: self.cwd).lastPathComponent
        self.title = (name?.nilIfEmpty ?? nickname?.nilIfEmpty ?? folderName.nilIfEmpty) ?? "Untitled agent"
        self.status = CodexThreadSummary.status(json["status"])
        self.model = json["modelProvider"] as? String ?? ""
        if let gitInfo = json["gitInfo"] as? [String: Any] {
            self.branch = gitInfo["branch"] as? String
            self.commitsToPush = CodexThreadSummary.int(gitInfo["commitsToPush"])
                ?? CodexThreadSummary.int(gitInfo["ahead"])
                ?? CodexThreadSummary.int(gitInfo["aheadCount"])
        } else {
            self.branch = nil
            self.commitsToPush = nil
        }
        let recency = CodexThreadSummary.timestamp(json["recencyAt"])
            ?? CodexThreadSummary.timestamp(json["updatedAt"])
            ?? CodexThreadSummary.timestamp(json["createdAt"])
            ?? 0
        self.updatedAt = recency > 0 ? Date(timeIntervalSince1970: recency) : Date()
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return TimeInterval(value) }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func status(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? [String: Any],
           let type = value["type"] as? String {
            return type
        }
        return "unknown"
    }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let now = Date()
        return formatter.localizedString(for: min(updatedAt, now), relativeTo: now)
    }

    var statusLabel: String {
        switch status {
        case "active", "running", "in_progress":
            "Working"
        case "done", "completed":
            "Done"
        case "idle":
            "Idle"
        case "blocked", "waiting_for_input", "needs_input":
            "Needs input"
        case "error", "failed":
            "Error"
        default:
            status.isEmpty ? "Unknown" : status.capitalized
        }
    }

    var gitSummary: String? {
        guard let branch, !branch.isEmpty else { return nil }
        if let commitsToPush, commitsToPush > 0 {
            return "\(branch) · \(commitsToPush) to push"
        }
        return branch
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum CodexEntryKind: String {
    case user
    case assistant
    case command
    case output
    case status
    case error
}

@Observable
final class CodexEntry: Identifiable {
    let id: String
    var kind: CodexEntryKind
    var title: String
    var text: String

    init(id: String = UUID().uuidString, kind: CodexEntryKind, title: String, text: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
    }
}

struct PendingCodexInput: Identifiable {
    let id: Int
    let questionId: String
    let prompt: String
}
