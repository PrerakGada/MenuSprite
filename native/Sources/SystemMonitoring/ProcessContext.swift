import Foundation
import Darwin

public struct ProcessContext: Codable, Equatable, Sendable {
    public let workingDirectory: String?
    public let virtualMachineHost: String?
    public let hostBundlePath: String?
    public let evidencePath: String?
    public let claudeSession: ClaudeCodeSession?
    /// What Arc's Task Manager listed for this renderer ("Tab: Gala ERP", …) and when.
    public let browserTasks: [String]?
    public let browserTasksSeen: Date?
    public init(workingDirectory: String? = nil, virtualMachineHost: String? = nil, hostBundlePath: String? = nil, evidencePath: String? = nil, claudeSession: ClaudeCodeSession? = nil,
                browserTasks: [String]? = nil, browserTasksSeen: Date? = nil) {
        self.workingDirectory = workingDirectory; self.virtualMachineHost = virtualMachineHost
        self.hostBundlePath = hostBundlePath; self.evidencePath = evidencePath; self.claudeSession = claudeSession
        self.browserTasks = browserTasks; self.browserTasksSeen = browserTasksSeen
    }
}

/// Presentation context never changes PID ownership, grouping, or accounting.
public struct ProcessPresentation: Sendable, Equatable {
    public let title: String
    public let subtitle: String?
    public let symbol: String
    public let iconBundlePath: String?
    public let explanation: String
    public static func runtime(name: String, path: String) -> String? {
        let executable = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let value = executable.isEmpty ? name.lowercased() : executable
        switch value {
        case "node", "nodejs": return "Node.js"
        case "dart", "dartvm", "dartaotruntime": return path.contains("/bin/cache/dart-sdk/") ? "Flutter / Dart" : "Dart"
        case "java": return "Java"
        case "bun": return "Bun"
        case "deno": return "Deno"
        case "ruby": return "Ruby"
        default: return value == "python" || value.hasPrefix("python3.") || value == "python3" ? "Python" : nil
        }
    }
    public static func isVirtualMachine(_ path: String) -> Bool {
        path.contains("/Virtualization.framework/") && path.hasSuffix("/com.apple.Virtualization.VirtualMachine")
    }
    public static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2 && parts[0] == "Users" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        return path
    }
    private static func folderContext(_ path: String) -> (title: String, worktree: String?)? {
        let parts = path.split(separator: "/").map(String.init)
        let roots: Set<String> = ["Developer", "Projects", "projects", "repos", "GitHub", "DeveloperProjects"]
        guard let index = parts.firstIndex(where: roots.contains), parts.indices.contains(index + 1) else { return nil }
        let project = parts[index + 1]
        var relative = Array(parts.dropFirst(index + 2))
        var tree: String?
        if relative.count >= 2 && ["worktrees", ".worktrees"].contains(relative[0]) {
            tree = relative[1]; relative.removeFirst(2)
        }
        let suffix = relative.isEmpty ? "" : " / " + relative.joined(separator: "/")
        return (project + suffix, tree)
    }
    /// "idle 3 h" from Claude Code's own last-activity stamp.
    public static func idle(since date: Date?, now: Date) -> String {
        guard let date else { return "idle" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "idle" }
        if seconds < 3600 { return "idle \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "idle \(Int(seconds / 3600)) h" }
        return "idle \(Int(seconds / 86_400)) d"
    }
    private static func sessionState(_ session: ClaudeCodeSession, now: Date) -> String {
        switch session.status {
        case "busy": "working"
        case "idle", nil: idle(since: session.lastActive, now: now)
        case let other?: other
        }
    }
    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    public init(consumer: MemoryConsumer, now: Date = Date()) {
        if BrowserTabs.isGroup(consumer) {
            let members = consumer.members ?? []
            let tabs = members.filter { BrowserTabs.role(of: $0.id) == .page }
                .reduce(0) { $0 + ($1.processes.first?.context?.browserTasks?.compactMap(BrowserTabs.pageTitle).count ?? 0) }
            let unnamed = members.first { BrowserTabs.role(of: $0.id) == .unnamed }?.processCount ?? 0
            title = consumer.name; symbol = "app"; iconBundlePath = consumer.bundlePath
            subtitle = tabs == 0 ? "Tabs not named yet · expand to name them"
                : "\(tabs) tab\(tabs == 1 ? "" : "s") named" + (unnamed == 0 ? "" : " · \(unnamed) page\(unnamed == 1 ? "" : "s") unnamed")
            explanation = "Arc and its helpers. Expand to see what each tab uses: tab names come from Arc's own Task Manager, memory is measured here per process."
            return
        }
        switch BrowserTabs.role(of: consumer.id) {
        case .page?:
            let process = consumer.processes.first
            let tabs = process?.context?.browserTasks?.compactMap(BrowserTabs.pageTitle) ?? []
            title = tabs.first ?? consumer.name; symbol = "globe"; iconBundlePath = nil
            subtitle = [tabs.count > 1 ? "+\(tabs.count - 1) more tab\(tabs.count == 2 ? "" : "s") in this process" : nil,
                        process.map { "PID \($0.pid)" }].compactMap { $0 }.joined(separator: " · ")
            explanation = (tabs.count > 1 ? "Arc tabs sharing one process (same site): " + tabs.joined(separator: "; ") + ". " : "Arc tab. ")
                + (process?.context?.browserTasksSeen.map { "Named from Arc's Task Manager at \(Self.clock($0)). " } ?? "")
                + "The reading is this page process's own memory. Frames it embeds from other sites run in their own processes. Close the tab in Arc to free it."
            return
        case .frames?:
            let hosts = consumer.processes.flatMap { $0.context?.browserTasks ?? [] }.map { label -> String in
                let text = label.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
                return URL(string: text)?.host ?? text
            }
            let unique = hosts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            title = "Embedded frames, extensions and workers"; symbol = "square.stack.3d.up"; iconBundlePath = nil
            subtitle = "\(consumer.processCount) process\(consumer.processCount == 1 ? "" : "es")" + (unique.isEmpty ? "" : " · " + unique.prefix(3).joined(separator: ", "))
            explanation = "Page processes Arc's Task Manager lists without a tab of their own: frames a page embeds from another site, extensions and service workers. " + unique.joined(separator: ", ")
            return
        case .unnamed?:
            title = "Pages not named yet"; symbol = "questionmark.square.dashed"; iconBundlePath = nil
            subtitle = "\(consumer.processCount) process\(consumer.processCount == 1 ? "" : "es") · the tag button names them"
            explanation = "Arc page processes MenuSprite has no name for: tabs opened since the last naming, or never named. The tag button opens Arc's Task Manager for a moment, reads which tab each process shows, and closes it."
            return
        case .browser?:
            title = "Arc browser and services"; symbol = "macwindow"; iconBundlePath = nil
            subtitle = "\(consumer.processCount) process\(consumer.processCount == 1 ? "" : "es") · browser, GPU, network"
            explanation = "Arc's main process with its GPU, network and utility helpers: the window, sidebar and everything not inside a page. Quitting this row quits Arc."
            return
        case nil: break
        }
        if consumer.id == ClaudeCode.groupID {
            let sessions = (consumer.members ?? []).compactMap { $0.processes.lazy.compactMap(\.context?.claudeSession).first }
            let working = sessions.filter(\.isWorking).count
            title = "Claude Code"; symbol = "asterisk"; iconBundlePath = nil
            subtitle = sessions.isEmpty ? "Background service · \(consumer.processCount) processes"
                : "\(sessions.count) session\(sessions.count == 1 ? "" : "s") · " + (working == 0 ? "none working" : "\(working) working")
            explanation = "Every Claude Code process on this Mac and what it started (MCP servers, tool shells), in any terminal or editor. Expand to see each session; quit them one at a time."
            return
        }
        if consumer.id == ClaudeCode.serviceID {
            title = "Claude Code background service"; symbol = "gearshape.2"; iconBundlePath = nil
            subtitle = "\(consumer.processCount) process\(consumer.processCount == 1 ? "" : "es") · no session"
            explanation = "Claude Code processes with no session of their own: its background daemon and the spare processes it keeps ready."
            return
        }
        if consumer.id.hasPrefix(ClaudeCode.sessionPrefix), let root = consumer.processes.first(where: { $0.context?.claudeSession != nil }),
           let session = root.context?.claudeSession {
            let folder = session.directory.flatMap { Self.folderContext($0)?.title ?? URL(fileURLWithPath: $0).lastPathComponent }
            title = session.title ?? folder ?? "Claude Code session"
            subtitle = [session.title == nil ? nil : folder, session.background ? "background" : nil, Self.sessionState(session, now: now), "PID \(root.pid)"]
                .compactMap { $0 }.joined(separator: " · ")
            symbol = "bubble.left"; iconBundlePath = nil
            explanation = "Claude Code session \(session.sessionID)" + (session.directory.map { " in \(Self.shortPath($0))" } ?? "")
                + ". Includes its MCP servers and tool processes. Quitting ends the session; `claude --resume \(session.sessionID)` reopens the conversation."
            return
        }
        if let bundle = consumer.bundlePath {
            title = consumer.name; subtitle = nil; symbol = "app"; iconBundlePath = bundle
            explanation = "Application and observed helpers. Ownership is based on its bundle or live parent chain."
            return
        }
        guard let p = consumer.processes.first else {
            title = consumer.name; subtitle = nil; symbol = "terminal"; iconBundlePath = nil; explanation = "Process metadata is unavailable."; return
        }
        let context = p.context, directory = context?.workingDirectory
        let pid = "PID \(p.pid)"
        if Self.isVirtualMachine(p.executablePath) {
            title = context?.virtualMachineHost.map { "\($0) virtual machine" } ?? "Virtual machine service"
            subtitle = "macOS Virtualization · \(pid)"; symbol = "desktopcomputer"; iconBundlePath = context?.hostBundlePath
            explanation = context?.evidencePath.map { "Associated through an open VM resource: \(Self.shortPath($0)). Kept separate from the host application's own processes." }
                ?? "macOS virtual-machine worker. The host app could not be established from accessible metadata."
            return
        }
        if let runtime = Self.runtime(name: p.name, path: p.executablePath) {
            symbol = "curlybraces"; iconBundlePath = nil
            if runtime == "Java", let directory, directory.contains("/.gradle/daemon/") {
                title = "Gradle daemon"
                subtitle = "Java · Gradle \(URL(fileURLWithPath: directory).lastPathComponent) · \(pid)"
                explanation = "Gradle daemon working directory: \(Self.shortPath(directory)). A daemon can serve multiple projects; no single project is assigned."
            } else if let directory, let folder = Self.folderContext(directory) {
                title = folder.title
                subtitle = [runtime, folder.worktree.map { "worktree \($0)" }, pid].compactMap { $0 }.joined(separator: " · ")
                explanation = "Working directory: \(Self.shortPath(directory)). This identifies the working folder, not a proven GUI-app owner. Separate jobs retain separate PIDs and totals."
            } else {
                title = runtime + " process"
                let folder = directory.flatMap { $0 == "/" ? nil : URL(fileURLWithPath: $0).lastPathComponent }
                subtitle = [folder ?? "Project not identified", pid].joined(separator: " · ")
                explanation = directory.map { "Working directory: \(Self.shortPath($0)). No project or GUI-app owner was established." }
                    ?? "macOS did not provide an accessible working directory. No project or owner is guessed."
            }
        } else {
            title = consumer.name; subtitle = pid; symbol = "terminal"; iconBundlePath = nil
            explanation = "Independent or shared process. A GUI-app owner was not established from its bundle or live parent chain."
        }
    }
}

/// Kernel metadata only. No command-line/environment inspection, file-content
/// reads, directory traversal, root helper, or shell process is used by the app.
struct ProcessContextReader {
    private struct CachedVM { let started: UInt64; let sampled: Double; let context: ProcessContext }
    private var virtualMachines: [Int32: CachedVM] = [:]
    private var claude = ClaudeSessionReader()
    mutating func retain(_ pids: Set<Int32>) { virtualMachines = virtualMachines.filter { pids.contains($0.key) }; claude.retain(pids) }
    private func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    private func workingDirectory(_ pid: Int32) -> String? {
        var vnode = proc_vnodepathinfo()
        let bytes = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, bytes) == bytes else { return nil }
        let value = string(&vnode.pvi_cdir.vip_path); return value.isEmpty ? nil : value
    }
    mutating func read(pid: Int32, started: UInt64, startSeconds: UInt64 = 0, name: String, path: String, userID: UInt32) -> ProcessContext? {
        guard userID == getuid() else { return nil }
        // Claude Code's own session registry names the conversation a process is
        // running. Only this user's sessions, and only Claude Code's own files.
        if ClaudeCode.isExecutable(path) {
            return ProcessContext(workingDirectory: workingDirectory(pid),
                                  claudeSession: claude.session(pid: pid, started: started, startSeconds: startSeconds))
        }
        guard MemoryAttribution.appBundle(in: path) == nil else { return nil }
        let vm = ProcessPresentation.isVirtualMachine(path)
        guard vm || ProcessPresentation.runtime(name: name, path: path) != nil else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if vm, let cached = virtualMachines[pid], cached.started == started, now - cached.sampled < 30 { return cached.context }
        let directory = workingDirectory(pid)
        var context = ProcessContext(workingDirectory: directory)
        if vm {
            // Bounded descriptor metadata, retaining only recognized VM-host
            // evidence. Open resource contents are never opened or read.
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
            let returned = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            if returned > 0 {
                for descriptor in descriptors.prefix(min(descriptors.count, Int(returned) / MemoryLayout<proc_fdinfo>.size)) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                    var info = vnode_fdinfowithpath()
                    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                    guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                    let file = string(&info.pvip.vip_path)
                    if let host = Self.dockerEvidence(file) {
                        context = ProcessContext(workingDirectory: directory, virtualMachineHost: "Docker", hostBundlePath: host.bundle, evidencePath: file)
                        if host.bundle != nil { break }
                    }
                }
            }
            virtualMachines[pid] = CachedVM(started: started, sampled: now, context: context)
        }
        return context
    }
    static func dockerEvidence(_ path: String) -> (bundle: String?, evidence: String)? {
        if let bundle = MemoryAttribution.appBundle(in: path), bundle.hasSuffix("/Docker.app"), path.contains("/Contents/Resources/linuxkit/") {
            return (bundle, path)
        }
        if path.contains("/Library/Containers/com.docker.docker/Data/vms/"), path.hasSuffix("/Docker.raw") { return (nil, path) }
        return nil
    }
}
