import ActivityKit

struct BetterCodexWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var blockedCount: Int
        var workingCount: Int
        var idleCount: Int
    }
}
