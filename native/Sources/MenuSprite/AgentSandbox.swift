import AgentProtocol
import AIAccounts
import AppKit
import Foundation
import SystemMonitoring

/// The agent server with nothing else: for testing the `menusprite` command and its MCP server end to end
/// without touching the real app.
///
///     MenuSprite --agent-sandbox <dir> [--socket <path>]
///
/// Sprites live in `<dir>/monitoring.json` and their folders in `<dir>/Sprites`; the socket is
/// `<dir>/agent.sock` unless `--socket` names a shorter path (a socket path holds at most 103 bytes), and
/// the command finds it through `MENUSPRITE_SOCKET`. No status items, hub, island, keep-awake, power helper,
/// AI usage requests or account work; the left strip's sides are kept in memory; nothing is written to
/// preferences. SIGTERM or SIGINT removes the socket and exits.
@MainActor
enum AgentSandbox {
    private static var server: AgentServer?
    private static var service: AgentService?
    private static var store: MonitoringStore?
    private static var signalSources: [DispatchSourceSignal] = []

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--agent-sandbox"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        let socket = arguments.firstIndex(of: "--socket").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? directory.appendingPathComponent("agent.sock").path
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            fail("Could not create \(directory.path): \(error.localizedDescription)")
        }
        // Every lookup of a sprite's folder (boards' images and actions included) stays inside the sandbox.
        SpriteFolders.rootOverride = directory.appendingPathComponent("Sprites", isDirectory: true)
        let store = MonitoringStore(configurationURL: directory.appendingPathComponent("monitoring.json"), usage: OfflineUsage())
        store.start()
        let service = AgentService(store: store, host: .sandbox(directory: directory))
        // Sprite scripts that call `menusprite refresh` must reach this sandbox, never the real app.
        let socketPath = socket.hasPrefix("/") ? socket : FileManager.default.currentDirectoryPath + "/" + socket
        CommandVariableRunner.extraEnvironment["MENUSPRITE_SOCKET"] = socketPath
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("MenuSpriteCLI")
        if FileManager.default.isExecutableFile(atPath: cli.path) { CommandVariableRunner.extraEnvironment["MENUSPRITE_CLI"] = cli.path }
        let server = AgentServer(path: socket, handler: service.handler())
        do { try server.start() } catch { fail("\(error)") }
        self.store = store; self.service = service; self.server = server
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AgentSandbox.server?.stop()
                    AgentSandbox.store?.stop()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        print("MenuSprite agent sandbox · pid \(getpid()) · \(socket)")
        fflush(stdout)
        NSApplication.shared.run()
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MenuSprite --agent-sandbox: \(message)\n".utf8))
        exit(1)
    }
}

/// AI usage for the sandbox: never asks a provider or reads a CLI's login, so a test run cannot raise a
/// keychain prompt or spend the real app's rate limit. AI readings show as unavailable.
private struct OfflineUsage: UsageFetching {
    func activeUsage(_ provider: AIProvider, force: Bool) async -> Result<UsageSnapshot, UsageError> { .failure(.notLoggedIn) }
    func savedUsage(_ provider: AIProvider, email: String, force: Bool) async -> Result<UsageSnapshot, UsageError> { .failure(.notLoggedIn) }
    func invalidate(_ provider: AIProvider) async {}
    func restartAutoPacing() async {}
    func nextRefreshDate() async -> Date? { nil }
}
