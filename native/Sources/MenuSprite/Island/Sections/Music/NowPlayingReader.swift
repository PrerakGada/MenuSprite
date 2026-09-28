import AppKit
import CryptoKit
import Foundation
import IslandKit

/// Runs MenuSprite's Now Playing adapter inside `/usr/bin/perl` and hands its replies to the main
/// actor. One long-lived child process while music is wanted, none otherwise; nothing polls.
///
/// Replies are framed and decoded off the main thread (covers are decoded there too) and delivered
/// only while the adapter that sent them is still the current one. Commands are written on a serial
/// queue; stopping invalidates any that have not started writing.
@MainActor
final class NowPlayingReader {
    enum Event {
        /// A fresh adapter is running and waits to be told what to follow.
        case launched
        case reply(MusicReply, cover: MusicCover?)
        /// The adapter ended unexpectedly and will be restarted shortly.
        case interrupted
        /// The adapter kept failing; the island shows the empty state.
        case gaveUp
        /// A command could not be written to a still-current adapter.
        case writeFailed(Int)
    }

    var onEvent: (Event) -> Void = { _ in }

    private(set) var isWanted = false
    private var process: Process?
    private var input: FileHandle?
    private var startedAt: Double = 0
    private var budget = MusicRestartBudget()
    private var restart: Task<Void, Never>?
    private let gate = ReaderGeneration()
    private let writer = DispatchQueue(label: "in.prerakgada.MenuSprite.now-playing.writer")

    /// The adapter library: in the app bundle's Frameworks, or beside the executable in a debug build.
    static let libraryURL: URL? = {
        let name = "libNowPlayingBridge.dylib"
        var candidates: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL { candidates.append(frameworks.appendingPathComponent(name)) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }()

    /// Perl's own DynaLoader installs the adapter's entry point as a subroutine and calls it.
    static let loader = """
    use strict; use DynaLoader;
    my ($library, $mode) = @ARGV;
    my %entries = (watch => 'menusprite_now_playing_watch');
    my $name = $entries{$mode} or die "unknown mode\\n";
    my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
    my $symbol = DynaLoader::dl_find_symbol($handle, $name) or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub('main::watch', $symbol);
    watch();
    """

    func start() {
        guard !isWanted else { return }
        isWanted = true
        budget.reset()
        launch()
    }

    func stop() {
        guard isWanted else { return }
        isWanted = false
        restart?.cancel()
        restart = nil
        terminate()
    }

    /// Queues one command. Returns false at once when it cannot be sent (invalid, or no adapter).
    @discardableResult
    func send(_ command: MusicCommand) -> Bool {
        guard let data = MusicWire.encode(command), let input, process != nil else { return false }
        let generation = gate.value
        let handle = UncheckedHandle(input)
        let requestID: Int? = {
            switch command {
            case .transport(let id, _, _, _), .seek(let id, _, _, _): id
            case .target: nil
            }
        }()
        let gate = self.gate
        writer.async { [weak self] in
            guard gate.value == generation else { return }
            do {
                try handle.handle.write(contentsOf: data)
            } catch {
                guard let requestID else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.gate.value == generation else { return }
                        self.onEvent(.writeFailed(requestID))
                    }
                }
            }
        }
        return true
    }

    // MARK: Process

    private func launch() {
        guard isWanted, process == nil else { return }
        guard let library = Self.libraryURL else {
            onEvent(.gaveUp)
            return
        }
        let generation = gate.advance()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, library.path, "watch"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A write racing the adapter's exit must fail, never raise SIGPIPE in the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let sink = ReplySink { [weak self] batch in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.gate.value == generation else { return }
                    for item in batch { self.onEvent(.reply(item.reply, cover: item.cover)) }
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            sink.consume(data)
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ended(generation: generation, status: status) }
            }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            ended(generation: generation, status: -1)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        startedAt = ProcessInfo.processInfo.systemUptime
        onEvent(.launched)
    }

    private func terminate() {
        gate.advance()
        guard let process else { return }
        self.process = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        input = nil
        let pid = process.processIdentifier
        let box = UncheckedProcess(process)
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if box.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func ended(generation: Int, status: Int32) {
        guard generation == gate.value else { return }
        process = nil
        try? input?.close()
        input = nil
        gate.advance()
        guard isWanted else { return }
        let ran = ProcessInfo.processInfo.systemUptime - startedAt
        guard let delay = budget.exited(afterRunning: ran) else {
            onEvent(.gaveUp)
            return
        }
        onEvent(.interrupted)
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }
}

/// The reader's lifetime counter, read by the writer queue and the output handler.
final class ReaderGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int { lock.withLock { current } }
    @discardableResult func advance() -> Int { lock.withLock { current += 1; return current } }
}

private struct UncheckedHandle: @unchecked Sendable { let handle: FileHandle; init(_ handle: FileHandle) { self.handle = handle } }
private struct UncheckedProcess: @unchecked Sendable { let process: Process; init(_ process: Process) { self.process = process } }

/// Frames the adapter's output into replies and decodes new covers, on the pipe's own queue.
private final class ReplySink: @unchecked Sendable {
    struct Item: Sendable {
        var reply: MusicReply
        var cover: MusicCover?
    }

    private let lock = NSLock()
    private var framer = MusicLineFramer(limit: MusicWire.maxReplyBytes)
    private let deliver: @Sendable ([Item]) -> Void

    init(deliver: @escaping @Sendable ([Item]) -> Void) { self.deliver = deliver }

    func consume(_ data: Data) {
        let lines = lock.withLock { framer.append(data) }
        var items: [Item] = []
        for line in lines {
            guard var reply = MusicWire.decode(line) else { continue }
            var cover: MusicCover?
            if case .playback(var playback) = reply, case .bytes(let bytes) = playback.artwork {
                cover = MusicCover(data: bytes)
                // The decoded cover travels separately; the reply keeps only the fact that bytes came.
                if cover == nil { playback.artwork = .missing }
                reply = .playback(playback)
            }
            items.append(Item(reply: reply, cover: cover))
        }
        if !items.isEmpty { deliver(items) }
    }
}

/// A decoded cover: a 160 pt (2×) thumbnail and the glow colour taken from it. Equal covers have
/// equal bytes (compared by digest), which is how a repeated cover on a new song is recognised.
final class MusicCover: Equatable, @unchecked Sendable {
    let image: CGImage
    let tint: NSColor?
    private let digest: Data

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
              ] as CFDictionary) else { return nil }
        self.image = image
        digest = Data(SHA256.hash(data: data))
        tint = Self.tint(of: image)
    }

    static func == (lhs: MusicCover, rhs: MusicCover) -> Bool { lhs === rhs || lhs.digest == rhs.digest }

    /// Draws the cover into one sRGB pixel and keeps a colourful average.
    private static func tint(of image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let tint = MusicTint.from(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255) else { return nil }
        return NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
    }
}
