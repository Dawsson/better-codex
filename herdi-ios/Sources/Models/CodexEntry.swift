import Foundation
import Observation

struct CodexThreadSummary: Identifiable, Hashable {
    let id: String
    var title: String
    var cwd: String
    var status: String
    var updatedAt: Date
    var model: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        let preview = json["preview"] as? String
        let name = json["name"] as? String
        self.title = (name?.isEmpty == false ? name : preview) ?? "Untitled session"
        self.cwd = json["cwd"] as? String ?? ""
        self.status = CodexThreadSummary.status(json["status"])
        self.model = json["modelProvider"] as? String ?? ""
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

    private static func status(_ value: Any?) -> String {
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
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
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
