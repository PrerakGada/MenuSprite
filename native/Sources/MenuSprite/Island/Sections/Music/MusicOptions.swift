import IslandKit
import SwiftUI

/// Now Playing's own options, kept in their own defaults keys. "Show music while playing" is an
/// island-wide setting (`IslandSettings.showPlayingMusic`) because the activity layer reads it too.
@MainActor
final class MusicOptions: ObservableObject {
    private enum Key {
        static let includeOthers = "MenuSprite.Island.Music.includeOtherPlayers"
        static let showLyrics = "MenuSprite.Island.Music.showLyrics"
        static let lyricsOnline = "MenuSprite.Island.Music.findLyricsOnline"
    }

    private let defaults: UserDefaults

    /// Follow videos and other non-music players automatically. Off: music apps first.
    @Published var includeOtherPlayers: Bool { didSet { defaults.set(includeOtherPlayers, forKey: Key.includeOthers) } }
    /// The Lyrics button on the Now Playing page.
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: Key.showLyrics) } }
    /// Separate consent: look lyrics up on lrclib.net while the lyrics panel is open.
    @Published var findLyricsOnline: Bool { didSet { defaults.set(findLyricsOnline, forKey: Key.lyricsOnline) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        includeOtherPlayers = defaults.object(forKey: Key.includeOthers) as? Bool ?? false
        showLyrics = defaults.object(forKey: Key.showLyrics) as? Bool ?? true
        findLyricsOnline = defaults.object(forKey: Key.lyricsOnline) as? Bool ?? false
    }
}

/// Settings › Content › Now Playing.
struct MusicOptionsView: View {
    @ObservedObject var options: MusicOptions
    @ObservedObject var settings: IslandSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show music while playing", isOn: Binding(get: { settings.value.showPlayingMusic },
                                                               set: { value in settings.update { $0.showPlayingMusic = value } }))
            Text("Playing music takes the closed island, with its cover and moving bars.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically include videos and other apps", isOn: $options.includeOtherPlayers)
            Text("Off: the island follows music apps first. You can still pick any player from the source menu.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show lyrics", isOn: $options.showLyrics)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Find lyrics online", isOn: $options.findLyricsOnline)
                Text("While the lyrics panel is open, the song's title, artist, album and length are sent to lrclib.net. Lyrics you import stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            .disabled(!options.showLyrics)
        }
    }
}
