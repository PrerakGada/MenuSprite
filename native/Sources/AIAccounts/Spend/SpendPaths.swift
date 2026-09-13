import Foundation

/// Where the CLIs' own session logs live, and where scan state is kept. Injectable so tests and
/// validation runs never read a real home directory or write a real cache.
///
/// Two files, deliberately: the app keeps the small one in memory for the life of the process, and
/// only ever opens the large one inside a scan.
public struct SpendPaths: Sendable, Equatable {
    public var claudeProjects: URL
    public var codexSessions: URL
    /// Kilobytes: per-day, per-model totals for the retained window. This is what the app holds.
    public var summaryFile: URL
    /// Megabytes: per-file records and the request-ownership index, read only while scanning.
    public var scanStateFile: URL

    public init(claudeProjects: URL, codexSessions: URL, summaryFile: URL, scanStateFile: URL) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
        self.summaryFile = summaryFile
        self.scanStateFile = scanStateFile
    }

    public static var standard: SpendPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite", isDirectory: true)
        return SpendPaths(claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
                          codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                          summaryFile: support.appendingPathComponent("ai-spend-summary.plist"),
                          scanStateFile: support.appendingPathComponent("ai-spend-scan-state.bin"))
    }

    /// Everything under one throwaway directory.
    public static func sandbox(root: URL) -> SpendPaths {
        SpendPaths(claudeProjects: root.appendingPathComponent("claude/projects", isDirectory: true),
                   codexSessions: root.appendingPathComponent("codex/sessions", isDirectory: true),
                   summaryFile: root.appendingPathComponent("ai-spend-summary.plist"),
                   scanStateFile: root.appendingPathComponent("ai-spend-scan-state.bin"))
    }

    func root(for provider: AIProvider) -> URL {
        provider == .claude ? claudeProjects : codexSessions
    }
}
