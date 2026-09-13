import Foundation
import Darwin

public struct ProcessContext: Codable, Equatable, Sendable {
    public let workingDirectory: String?
    public let virtualMachineHost: String?
    public let hostBundlePath: String?
    public let evidencePath: String?
    public init(workingDirectory: String? = nil, virtualMachineHost: String? = nil, hostBundlePath: String? = nil, evidencePath: String? = nil) {
        self.workingDirectory = workingDirectory; self.virtualMachineHost = virtualMachineHost
        self.hostBundlePath = hostBundlePath; self.evidencePath = evidencePath
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
    public init(consumer: MemoryConsumer) {
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
    mutating func retain(_ pids: Set<Int32>) { virtualMachines = virtualMachines.filter { pids.contains($0.key) } }
    private func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    mutating func read(pid: Int32, started: UInt64, name: String, path: String, userID: UInt32) -> ProcessContext? {
        guard userID == getuid(), MemoryAttribution.appBundle(in: path) == nil else { return nil }
        let vm = ProcessPresentation.isVirtualMachine(path)
        guard vm || ProcessPresentation.runtime(name: name, path: path) != nil else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if vm, let cached = virtualMachines[pid], cached.started == started, now - cached.sampled < 30 { return cached.context }
        var vnode = proc_vnodepathinfo()
        let bytes = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let directory: String?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, bytes) == bytes {
            let value = string(&vnode.pvi_cdir.vip_path); directory = value.isEmpty ? nil : value
        } else { directory = nil }
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
