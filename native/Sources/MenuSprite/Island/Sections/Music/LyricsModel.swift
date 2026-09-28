import AppKit
import Combine
import IslandKit
import UniformTypeIdentifiers

/// Lyrics for the recording on screen. It holds one recording's lyrics and timing at a time: a
/// different or empty recording clears them (even while the panel is hidden), hiding the panel only
/// cancels work. Nothing is looked up unless the panel is open and "Find lyrics online" is on.
@MainActor
final class LyricsModel: ObservableObject {
    enum State: Equatable {
        case idle
        /// Online lookup is off: explain what it would send.
        case consent
        case loading
        case content(LyricsContent)
        case notFound
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var offset: Double = 0
    @Published private(set) var isPanelOpen = false

    private let options: MusicOptions
    private var playback: MusicPlayback?
    private var recording: String?
    private var cached: LyricsContent?
    private var lookup: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []

    init(options: MusicOptions) {
        self.options = options
        options.$showLyrics.dropFirst().removeDuplicates().sink { [weak self] shown in
            Task { @MainActor in if !shown { self?.clear(closing: true) } }
        }.store(in: &observations)
        options.$findLyricsOnline.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.load() }
        }.store(in: &observations)
    }

    /// Every reading of the followed player (nil when playback went away).
    func update(_ playback: MusicPlayback?) {
        if playback?.revision != recording { clear(closing: false) }
        recording = playback?.revision
        self.playback = playback
        if isPanelOpen, state == .idle { load() }
    }

    func setPanelOpen(_ open: Bool) {
        guard open != isPanelOpen else { return }
        isPanelOpen = open
        if open { load() } else { lookup?.cancel(); lookup = nil; if case .loading = state { state = .idle } }
    }

    func retry() {
        if case .content = state { return }
        state = .idle
        load()
    }

    func adjust(by delta: Double) { offset = LyricsTimeline.adjust(offset, by: delta) }
    func resetOffset() { offset = 0 }

    /// Everything goes: shutdown or the feature switched off.
    func clear(closing: Bool) {
        lookup?.cancel()
        lookup = nil
        cached = nil
        offset = 0
        state = .idle
        if closing { isPanelOpen = false }
    }

    private func load() {
        guard isPanelOpen, options.showLyrics, let playback else { return }
        if let cached { state = .content(cached); return }
        guard options.findLyricsOnline else { state = .consent; return }
        guard lookup == nil else { return }
        guard let query = LyricsQuery(title: playback.title, artist: playback.artist, album: playback.album, duration: playback.duration) else {
            state = .notFound
            return
        }
        state = .loading
        let key = playback.revision
        lookup = Task { [weak self] in
            let result = await LyricsLookup.fetch(query)
            guard !Task.isCancelled, let self, self.recording == key else { return }
            self.lookup = nil
            switch result {
            case .found(let content):
                self.cached = content
                self.state = .content(content)
            case .notFound: self.state = .notFound
            case .failed: self.state = .failed
            }
        }
    }

    /// Imports an .lrc or text file for the recording on screen, if it is still the same one and the
    /// panel is still open when the file arrives.
    func importLyrics(from url: URL, for revision: String) {
        guard revision == recording, isPanelOpen, options.showLyrics else { return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= LyricsParser.maxBytes,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            state = .failed
            return
        }
        let content: LyricsContent?
        if LyricsParser.hasTiming(text) {
            content = LyricsParser.parse(text, duration: playback?.duration).map { .synced($0) }
        } else {
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            content = plain.isEmpty ? nil : .plain(plain)
        }
        guard let content else { state = .notFound; return }
        lookup?.cancel()
        lookup = nil
        cached = content
        state = .content(content)
    }

    var currentRevision: String? { recording }
}

/// One request to lrclib.net: an ephemeral session (no cache, cookies or credentials), redirects
/// refused so the metadata can only reach the disclosed host, and at most 128 KiB read.
enum LyricsLookup {
    enum Result: Sendable {
        case found(LyricsContent)
        case notFound
        case failed
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "MenuSprite/\(version) (+https://github.com/PrerakGada/MenuSprite)"
    }()

    static func fetch(_ query: LyricsQuery) async -> Result {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: query.url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .notFound }
            guard http.statusCode == 200, response.expectedContentLength <= LyricsQuery.maxResponseBytes else { return .failed }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > LyricsQuery.maxResponseBytes { return .failed }
            }
            guard let decoded = try? JSONDecoder().decode(LyricsResponse.self, from: body) else { return .failed }
            return query.content(of: decoded).map { .found($0) } ?? .notFound
        } catch {
            return .failed
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
