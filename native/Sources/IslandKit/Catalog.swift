import Foundation

/// A colour the island's editors and gallery use for a section's icon tile. Kept as named system
/// colours so light and dark appearances resolve them natively.
public enum IslandTint: String, Codable, Sendable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, gray, brown
}

/// One page of the open island. The raw values are the stored identifiers: keep them stable.
public enum IslandSectionID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case controls, mixer, music, clipboard, captures, files, system, tools, calendar, notifications, timer,
         camera, downloads, scratchpad, agents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .controls: "Controls"
        case .mixer: "Volume mixer"
        case .music: "Now Playing"
        case .clipboard: "Clipboard"
        case .captures: "Recent captures"
        case .files: "Files"
        case .system: "System"
        case .tools: "Tools"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .timer: "Timer"
        case .camera: "Camera mirror"
        case .downloads: "Downloads"
        case .scratchpad: "Scratchpad"
        case .agents: "AI Agents"
        }
    }

    /// The title used in the open island's header, where "Now Playing" reads as "Music".
    public var headerTitle: String { self == .music ? "Music" : title }

    public var symbol: String {
        switch self {
        case .controls: "slider.horizontal.3"
        case .mixer: "speaker.wave.2"
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .captures: "camera.viewfinder"
        case .files: "tray.full"
        case .system: "gauge.with.dots.needle.50percent"
        case .tools: "square.grid.2x2"
        case .calendar: "calendar"
        case .notifications: "bell"
        case .timer: "timer"
        case .camera: "person.crop.square"
        case .downloads: "arrow.down.circle"
        case .scratchpad: "note.text"
        case .agents: "sparkles"
        }
    }

    public var tint: IslandTint {
        switch self {
        case .controls: .blue
        case .mixer: .purple
        case .music: .pink
        case .clipboard: .brown
        case .captures: .indigo
        case .files: .blue
        case .system: .green
        case .tools: .gray
        case .calendar: .red
        case .notifications: .orange
        case .timer: .teal
        case .camera: .gray
        case .downloads: .blue
        case .scratchpad: .yellow
        case .agents: .orange
        }
    }

    /// ⌥⌘ + this letter opens the section while the island has the keyboard. Fixed per section so a
    /// reorder never moves a shortcut.
    public var shortcut: Character {
        switch self {
        case .controls: "c"
        case .mixer: "v"
        case .music: "m"
        case .clipboard: "b"
        case .captures: "s"
        case .files: "f"
        case .system: "i"
        case .tools: "t"
        case .calendar: "a"
        case .notifications: "n"
        case .timer: "r"
        case .camera: "w"
        case .downloads: "d"
        case .scratchpad: "p"
        case .agents: "g"
        }
    }

    public var summary: String {
        switch self {
        case .controls: "Playback, volume, brightness and your shortcuts."
        case .mixer: "Volume for each app, and where the sound goes."
        case .music: "The song that is playing, with its controls."
        case .clipboard: "What you copied recently, ready to paste again."
        case .captures: "Your latest screenshots and recordings."
        case .files: "A shelf for files you drop on the island."
        case .system: "CPU, memory, disk, network and power at a glance."
        case .tools: "Quick tools and utilities."
        case .calendar: "Today's events and the month ahead."
        case .notifications: "Recent notifications from your apps."
        case .timer: "A countdown, Pomodoro or stopwatch."
        case .camera: "A quick look at yourself before a call."
        case .downloads: "Downloads in progress and just finished."
        case .scratchpad: "Quick notes that stay put."
        case .agents: "Claude Code and Codex: what is working, limits and costs."
        }
    }

    /// Pages that are tall by nature (lists, detail pages) and get a taller budget in the presets.
    public var isVertical: Bool { false }

    /// Search matches the title, the identifier, and "Music" for Now Playing.
    public var searchTerms: [String] {
        var terms = [title, rawValue]
        if self == .music { terms.append("Music") }
        return terms
    }
}

/// The three cards at the top of the Controls page.
public enum IslandCardID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case nowPlaying, volume, brightness
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .volume: "Volume"
        case .brightness: "Brightness"
        }
    }
    public var symbol: String {
        switch self {
        case .nowPlaying: "music.note"
        case .volume: "speaker.wave.2.fill"
        case .brightness: "sun.max"
        }
    }
}

/// A shortcut tile on the Controls page (and a possible floating button).
public enum IslandControlID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case mixer, keepAwake, timer, calendar, microphone, screenshot, recording, speedTest, panel, commandBar, scratchpad
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mixer: "Volume mixer"
        case .keepAwake: "Keep awake"
        case .timer: "Timer"
        case .calendar: "Calendar"
        case .microphone: "Mute microphone"
        case .screenshot: "Screenshot"
        case .recording: "Screen recording"
        case .speedTest: "Speed test"
        case .panel: "Open app panel"
        case .commandBar: "Command Bar"
        case .scratchpad: "Scratchpad"
        }
    }

    public var symbol: String {
        switch self {
        case .mixer: "speaker.wave.2"
        case .keepAwake: "cup.and.saucer"
        case .timer: "timer"
        case .calendar: "calendar"
        case .microphone: "mic"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .speedTest: "gauge.with.dots.needle.67percent"
        case .panel: "macwindow"
        case .commandBar: "command"
        case .scratchpad: "note.text"
        }
    }

    /// Tiles hidden on a new setup: home starts with mixer, keep awake, timer and calendar.
    public static let hiddenByDefault: Set<IslandControlID> =
        [.microphone, .screenshot, .recording, .speedTest, .panel, .commandBar, .scratchpad]
}

/// What a floating button beside the open island does. Stored as a string: "explore", "settings",
/// "pin", a section identifier, or "control." followed by a control identifier.
public enum IslandFloatingAction: Hashable, Sendable, Codable, Identifiable {
    case explore, settings, pin
    case section(IslandSectionID)
    case control(IslandControlID)

    public var id: String { storageValue }

    public var storageValue: String {
        switch self {
        case .explore: "explore"
        case .settings: "settings"
        case .pin: "pin"
        case .section(let section): section.rawValue
        case .control(let control): "control." + control.rawValue
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "explore": self = .explore
        case "settings": self = .settings
        case "pin": self = .pin
        default:
            if storageValue.hasPrefix("control."), let control = IslandControlID(rawValue: String(storageValue.dropFirst(8))) {
                self = .control(control)
            } else if let section = IslandSectionID(rawValue: storageValue) {
                self = .section(section)
            } else { return nil }
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let action = IslandFloatingAction(storageValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown action \(value)"))
        }
        self = action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }

    public var title: String {
        switch self {
        case .explore: "Explore"
        case .settings: "Settings"
        case .pin: "Keep open"
        case .section(let section): section.title
        case .control(let control): control.title
        }
    }

    public var symbol: String {
        switch self {
        case .explore: "square.grid.2x2"
        case .settings: "gearshape"
        case .pin: "pin"
        case .section(let section): section == .music ? "music.note" : section.symbol
        case .control(let control): control.symbol
        }
    }

    /// The chooser's two groups: "Open a section" and "Quick actions".
    public static let sectionGroup: [IslandFloatingAction] =
        [.explore, .settings] + IslandSectionID.allCases.map { .section($0) }
    public static let quickGroup: [IslandFloatingAction] =
        [.pin, .section(.music), .section(.mixer), .control(.keepAwake), .section(.timer), .section(.calendar),
         .control(.microphone), .control(.screenshot), .control(.recording), .control(.speedTest),
         .control(.panel), .control(.commandBar), .control(.scratchpad)]
}

/// What the closed island shows when no live activity has it.
public enum IslandRestContent: String, CaseIterable, Codable, Sendable {
    case nothing, battery, music, aiLimits
    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .battery: "Battery"
        case .music: "Music"
        case .aiLimits: "AI limits"
        }
    }
}

/// A transient notice the island can show, and whether the person wants it.
public enum IslandIndicatorID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case volume, brightness, keyboardLight, battery, accessories, clipboard, captures, newTrack
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboardLight: "Keyboard light"
        case .battery: "Battery"
        case .accessories: "Accessory alerts"
        case .clipboard: "Clipboard"
        case .captures: "Captures"
        case .newTrack: "New track"
        }
    }
    public var symbol: String {
        switch self {
        case .volume: "speaker.wave.2"
        case .brightness: "sun.max"
        case .keyboardLight: "light.max"
        case .battery: "battery.75percent"
        case .accessories: "headphones"
        case .clipboard: "doc.on.clipboard"
        case .captures: "camera.viewfinder"
        case .newTrack: "music.note"
        }
    }
}
