import Foundation

/// The `menusprite` command: how agents (and people) build and change sprites through the running app,
/// from a shell or as an MCP server. Spec: docs/agent-authoring.md. The entry point stays this thin so
/// every verb runs, and is tested, through `CLI` with its streams and the app connection injected.
@main
enum MenuSpriteCommand {
    static func main() {
        exit(CLI(environment: ProcessInfo.processInfo.environment).run(Array(CommandLine.arguments.dropFirst())))
    }
}

/// The command's exit statuses: agents branch on them, so they stay this small.
enum ExitStatus {
    static let ok: Int32 = 0
    /// A spec, argument or command problem the caller can fix.
    static let failure: Int32 = 1
    /// MenuSprite is not installed, would not start, or did not answer.
    static let unavailable: Int32 = 2
}

/// A problem found before or around a request, worded for the person or agent who typed the command.
struct CommandError: Error, Equatable, CustomStringConvertible {
    var message: String
    var status: Int32 = ExitStatus.failure
    init(_ message: String, status: Int32 = ExitStatus.failure) { self.message = message; self.status = status }
    var description: String { message }
}

/// The version of the MenuSprite this binary ships inside, read from the enclosing bundle's Info.plist
/// (`Contents/Helpers/menusprite` → `Contents/Info.plist`), so it never disagrees with the app. A build run
/// from `.build` has no bundle and says "dev".
enum CLIVersion {
    static var executable: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    static let current: String = {
        guard let executable else { return "dev" }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "Helpers",
              let data = FileManager.default.contents(atPath: contents.appendingPathComponent("Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }()
}
