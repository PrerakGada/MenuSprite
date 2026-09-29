import Foundation

/// What an app is for, so the power flow can say where the watts go ("Development 6.1 W")
/// rather than one "System" figure. Grouping only: it never changes which processes an app owns.
public enum PowerCategory: String, CaseIterable, Sendable, Codable {
    case development, browsing, work, media, background, apps
    public var title: String {
        switch self {
        case .development: "Development"
        case .browsing: "Browsing"
        case .work: "Work & chat"
        case .media: "Media & design"
        case .background: "Background"
        case .apps: "Other apps"
        }
    }
    public var symbol: String {
        switch self {
        case .development: "chevron.left.forwardslash.chevron.right"
        case .browsing: "globe"
        case .work: "briefcase.fill"
        case .media: "play.rectangle.fill"
        case .background: "gearshape.2.fill"
        case .apps: "square.grid.2x2.fill"
        }
    }
}

/// The three Info.plist facts classification needs. Read once per bundle path.
public struct BundleFacts: Sendable, Equatable {
    public let identifier: String?
    /// `LSApplicationCategoryType`, e.g. `public.app-category.developer-tools`.
    public let declared: String?
    /// `LSUIElement` or `LSBackgroundOnly`: a menu-bar or background agent.
    public let agent: Bool
    public init(identifier: String?, declared: String?, agent: Bool) {
        self.identifier = identifier; self.declared = declared; self.agent = agent
    }
    public static func read(bundlePath: String) -> BundleFacts? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool {
            if let value = plist[key] as? Bool { return value }
            if let value = plist[key] as? NSNumber { return value.boolValue }
            if let value = plist[key] as? String { return value == "1" || value.lowercased() == "true" || value.lowercased() == "yes" }
            return false
        }
        return BundleFacts(identifier: plist["CFBundleIdentifier"] as? String,
                           declared: plist["LSApplicationCategoryType"] as? String,
                           agent: flag("LSUIElement") || flag("LSBackgroundOnly"))
    }
}

public enum PowerCategories {
    /// Apps whose declared category misleads (Arc, Safari and iTerm call themselves productivity;
    /// Claude and Superhuman call themselves developer tools) or who declare none.
    static let known: [String: PowerCategory] = [
        // Browsers
        "company.thebrowser.Browser": .browsing, "company.thebrowser.dia": .browsing, "com.apple.Safari": .browsing,
        "com.google.Chrome": .browsing, "com.google.Chrome.canary": .browsing, "org.mozilla.firefox": .browsing,
        "com.brave.Browser": .browsing, "com.microsoft.edgemac": .browsing, "com.vivaldi.Vivaldi": .browsing,
        "com.kagi.kagimacOS": .browsing, "app.zen-browser.zen": .browsing, "com.operasoftware.Opera": .browsing,
        // Terminals, editors and developer tools that declare something else or nothing
        "com.googlecode.iterm2": .development, "com.apple.Terminal": .development, "dev.warp.Warp-Stable": .development,
        "com.mitchellh.ghostty": .development, "net.kovidgoyal.kitty": .development, "io.alacritty": .development,
        "com.github.wez.wezterm": .development, "dev.zed.Zed": .development, "dev.zed.Zed-Preview": .development,
        "com.todesktop.230313mzl4w4u92": .development, "com.microsoft.VSCode": .development,
        "com.postmanlabs.mac": .development, "com.openai.codex": .development, "com.docker.docker": .development,
        "com.apple.dt.Xcode": .development, "com.apple.iphonesimulator": .development,
        // Mail, chat, planning and AI chat
        "com.anthropic.claudefordesktop": .work, "com.openai.chat": .work, "com.superhuman.electron": .work,
        "com.clickup.desktop-app": .work, "com.talreengaze.nook": .work, "com.engaze.nook": .work, "com.electron.wispr-flow": .work,
        "com.tinyspeck.slackmacgap": .work, "us.zoom.xos": .work, "com.microsoft.teams2": .work,
        "net.whatsapp.WhatsApp": .work, "com.moonshot.kimichat": .work, "com.apple.mail": .work,
        // Media players and capture
        "com.spotify.client": .media, "com.apple.Music": .media, "com.apple.TV": .media, "com.apple.Photos": .media,
        "com.obsproject.obs-studio": .media, "com.colliderli.iina": .media, "org.videolan.vlc": .media,
        // MenuSprite itself
        "in.prerakgada.MenuSprite": .background
    ]
    /// Google's Docs/Sheets/Slides web-app shortcuts share one prefix.
    static let knownPrefixes: [(String, PowerCategory)] = [("com.google.drivefs.shortcuts.", .work)]
    static func declared(_ type: String) -> PowerCategory? {
        let name = type.replacingOccurrences(of: "public.app-category.", with: "")
        switch name {
        case "developer-tools": return .development
        case "productivity", "business", "social-networking", "finance", "education", "reference", "news",
             "lifestyle", "medical", "healthcare-fitness", "travel", "weather", "books": return .work
        case "music", "video", "entertainment", "photography", "graphics-design", "games", "sports": return .media
        default: return name.hasSuffix("-games") ? .media : nil
        }
    }
    static let devRoots: Set<String> = ["Developer", "Projects", "projects", "repos", "GitHub", "DeveloperProjects"]
    static func isDevelopmentPath(_ path: String) -> Bool {
        let markers = ["/Xcode.app/", "/Xcode-beta.app/", "/CommandLineTools/", "/.nvm/", "/.bun/", "/.cargo/", "/.rustup/",
                       "/.pyenv/", "/.volta/", "/fvm/", "/flutter/", "/homebrew/", "/.local/share/mise/", "/go/bin/"]
        return markers.contains { path.contains($0) }
    }
    static func inDevelopmentFolder(_ directory: String?) -> Bool {
        guard let directory else { return false }
        let parts = directory.split(separator: "/").map(String.init)
        return parts.count >= 3 && parts[0] == "Users" && devRoots.contains(parts[2])
    }
    /// The app first (a curated list, then what its Info.plist declares), then, for processes
    /// with no app, what they run and where. Never guesses from a name.
    public static func classify(_ consumer: MemoryConsumer, facts: BundleFacts?) -> PowerCategory {
        if consumer.id == ClaudeCode.groupID || consumer.id == ClaudeCode.serviceID || consumer.id.hasPrefix(ClaudeCode.sessionPrefix) { return .development }
        if consumer.bundlePath != nil {
            if let id = facts?.identifier {
                if let known = known[id] { return known }
                if let prefix = knownPrefixes.first(where: { id.hasPrefix($0.0) }) { return prefix.1 }
            }
            if let type = facts?.declared, let category = declared(type) { return category }
            // A runtime's own app wrapper (Homebrew's Python.app) or a tool inside Xcode.
            if let path = consumer.bundlePath, path.contains("/Python.framework/") || isDevelopmentPath(path + "/") { return .development }
            if facts?.agent == true { return .background }
            if let path = consumer.bundlePath, path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") { return .background }
            return facts?.declared == "public.app-category.utilities" ? .background : .apps
        }
        for process in consumer.processes {
            if ProcessPresentation.isVirtualMachine(process.executablePath) { return .development }
            if ProcessPresentation.runtime(name: process.name, path: process.executablePath) != nil { return .development }
            if isDevelopmentPath(process.executablePath) { return .development }
            if inDevelopmentFolder(process.context?.workingDirectory) { return .development }
        }
        return .background
    }
}

/// Where the Mac's measured system power goes, for the right side of the power flow.
/// Every figure is a reading: app CPU energy summed per category, apps at `heavyWatts` or more
/// on their own, then what CPU energy cannot see (display, GPU, root-owned macOS processes), then
/// the adapter residual. Nothing is scaled to fit.
public struct PowerBreakdown: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One app over the heavy threshold, all its processes combined.
        case app(id: String, iconPath: String?, symbol: String, category: PowerCategory)
        case category(PowerCategory)
        /// System power CPU energy does not account for: display, GPU, memory, radios and the
        /// macOS processes MenuSprite may not read.
        case restOfMac
        /// adapter − system − battery: conversion losses and USB accessories.
        case outside
        /// No per-app readings yet: the whole system figure.
        case system
    }
    public struct Entry: Sendable, Equatable, Identifiable {
        public let kind: Kind
        public let title: String
        public let watts: Double
        public init(kind: Kind, title: String, watts: Double) { self.kind = kind; self.title = title; self.watts = watts }
        public var id: String {
            switch kind {
            case .app(let id, _, _, _): "app:" + id
            case .category(let category): "category:" + category.rawValue
            case .restOfMac: "rest"
            case .outside: "outside"
            case .system: "system"
            }
        }
    }
    public let entries: [Entry]
    /// Sum of the app CPU energy that went into the categories and heavy apps.
    public let attributed: Double
    public static let heavyWatts = 2.0
    /// Fewer pills than this and the right side stays readable at the dashboard's width.
    public static let maximumEntries = 8
    /// Display, GPU, memory, radios and the macOS processes MenuSprite may not read.
    public static let restTitle = "Display & system"
    public static let outsideTitle = "Other"
    public init(entries: [Entry], attributed: Double) { self.entries = entries; self.attributed = attributed }
    /// `rows` are the ranked top-level consumers with their CPU watts. With no rows the system
    /// figure stays whole, as before per-app readings arrive.
    public static func make(system: Double?, outside: Double?, rows: [ProcessConsumerRate],
                            category: (MemoryConsumer) -> PowerCategory, heavyWatts: Double = heavyWatts,
                            minimumWatts: Double = 0.05) -> PowerBreakdown {
        var entries: [Entry] = []
        var attributed = 0.0
        if rows.isEmpty {
            if let system { entries.append(Entry(kind: .system, title: "System", watts: system)) }
        } else {
            var totals: [PowerCategory: Double] = [:]
            var heavy: [Entry] = []
            for row in rows where row.value.isFinite && row.value > 0 {
                let kind = category(row.consumer)
                attributed += row.value
                if row.value >= heavyWatts && heavy.count < 3 {
                    let presentation = row.consumer.presentation
                    heavy.append(Entry(kind: .app(id: row.id, iconPath: presentation.iconBundlePath, symbol: presentation.symbol, category: kind),
                                       title: presentation.title, watts: row.value))
                } else { totals[kind, default: 0] += row.value }
            }
            var categories = totals.filter { $0.value >= minimumWatts }
                .map { Entry(kind: .category($0.key), title: $0.key.title, watts: $0.value) }
            let fixed = heavy.count + (system == nil ? 0 : 1) + (outside == nil ? 0 : 1)
            let room = max(1, maximumEntries - fixed)
            if categories.count > room {
                // Fold the smallest categories into "Other apps" so the column stays legible.
                categories.sort { $0.watts > $1.watts }
                let kept = categories.prefix(room - 1).filter { $0.kind != .category(.apps) }
                let folded = categories.filter { entry in !kept.contains(entry) }.reduce(0) { $0 + $1.watts }
                categories = Array(kept) + [Entry(kind: .category(.apps), title: PowerCategory.apps.title, watts: folded)]
            }
            entries = (heavy + categories).sorted { $0.watts == $1.watts ? $0.id < $1.id : $0.watts > $1.watts }
            if let system, system - attributed >= minimumWatts {
                entries.append(Entry(kind: .restOfMac, title: restTitle, watts: system - attributed))
            }
        }
        if let outside, outside >= minimumWatts { entries.append(Entry(kind: .outside, title: outsideTitle, watts: outside)) }
        return PowerBreakdown(entries: entries, attributed: attributed)
    }
}
