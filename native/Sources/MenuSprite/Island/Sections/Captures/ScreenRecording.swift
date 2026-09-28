import AppKit
import AVFoundation
import IslandKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Forwards ScreenCaptureKit's callbacks, which arrive on its own queues, to the main actor.
private final class RecorderRelay: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    enum Event: Sendable { case finished, failed(String) }
    private let handler: @Sendable (Event) -> Void

    init(handler: @escaping @Sendable (Event) -> Void) { self.handler = handler }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { handler(.failed(error.localizedDescription)) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        handler(.failed(error.localizedDescription))
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { handler(.finished) }
}

/// The screen recorder: a countdown, then one ScreenCaptureKit stream writing a .mov straight to the
/// save folder (HEVC where available), with the Mac's sound and the microphone as chosen. Nothing of
/// it exists between recordings; while it runs, idle sleep is held off and free space is checked once
/// a second off the main thread. A small pill under the menu bar shows the time and the Stop button.
@MainActor
final class CaptureRecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case countdown(Int)
        case recording(since: Date)
        case finishing
        /// A last word in the pill before it goes: saved, refused or failed.
        case message(String, symbol: String, tint: Color)
    }

    @Published private(set) var state: State = .idle
    /// Called with each saved recording, for the history.
    var saved: (URL) -> Void = { _ in }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var relay: RecorderRelay?
    private var url: URL?
    private var activity: NSObjectProtocol?
    private var pill: RecordingPillPanel?
    private var work: Task<Void, Never>?
    private var diskWatch: Task<Void, Never>?
    private var stoppedForDisk = false

    /// Counting down, recording or saving: the Screen recording tile shows red.
    var isActive: Bool {
        switch state {
        case .countdown, .recording, .finishing: true
        case .idle, .message: false
        }
    }

    /// Starts a recording of what the person chose, after the countdown.
    func begin(_ choice: CaptureChoice, options: CaptureOptions, includeIsland: Bool) {
        guard !isActive else { return }
        // A last message from the previous recording gives way.
        work?.cancel()
        closePill()
        let folder = options.resolvedSaveFolder
        let countdown = options.countdown
        let systemAudio = options.recordsSystemAudio
        let microphone = options.microphoneAllowed
        showPill(on: choice.display)
        work = Task { [weak self] in
            let free = await Task.detached { CaptureFiles.freeSpace(at: folder) }.value
            guard let self, !Task.isCancelled else { return }
            if let free, !CaptureRecordingRules.canStart(freeBytes: free) {
                self.finish(.message("Not enough free space", symbol: "exclamationmark.triangle.fill", tint: .orange))
                return
            }
            for remaining in stride(from: countdown, to: 0, by: -1) {
                self.state = .countdown(remaining)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await self.start(choice, folder: folder, systemAudio: systemAudio, microphone: microphone, includeIsland: includeIsland)
        }
    }

    /// The tile, the shortcut or the pill: a countdown is cancelled, a recording stops and is saved.
    func stopOrCancel() {
        switch state {
        case .countdown:
            work?.cancel()
            finish(nil)
        case .recording:
            stop()
        case .idle, .finishing, .message:
            break
        }
    }

    /// The island stopped: end whatever is running, keeping what was recorded.
    func teardown() {
        switch state {
        case .recording: stop()
        case .finishing: break
        case .countdown, .idle, .message: finish(nil)
        }
    }

    private func start(_ choice: CaptureChoice, folder: URL, systemAudio: Bool, microphone: Bool, includeIsland: Bool) async {
        guard let url = CaptureFiles.recordingURL(date: Date(), in: folder) else {
            finish(.message("Could not name the recording", symbol: "exclamationmark.triangle.fill", tint: .orange))
            return
        }
        do {
            // A fresh snapshot, taken with the pill on screen so it can be left out of the video.
            let snapshot = try await CaptureSnapshot.take()
            let (filter, configuration) = try setup(choice, snapshot: snapshot, includeIsland: includeIsland)
            configuration.capturesAudio = systemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = microphone
            let relay = RecorderRelay { [weak self] event in Task { @MainActor in self?.handle(event) } }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = url
            recording.outputFileType = .mov
            recording.videoCodecType = recording.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
            let output = SCRecordingOutput(configuration: recording, delegate: relay)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            guard !Task.isCancelled else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            self.output = output
            self.relay = relay
            self.url = url
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Screen recording")
            state = .recording(since: Date())
            watchDisk(folder)
        } catch {
            finish(.message("Recording could not start", symbol: "exclamationmark.triangle.fill", tint: .orange))
        }
    }

    /// The stream's filter and size for an area, a window or a whole display.
    private func setup(_ choice: CaptureChoice, snapshot: CaptureSnapshot, includeIsland: Bool) throws -> (SCContentFilter, SCStreamConfiguration) {
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(CaptureRecordingRules.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        configuration.showsCursor = true
        let display = choice.display
        func even(_ value: CGFloat) -> Int { max(2, Int((value / 2).rounded(.down)) * 2) }
        switch choice.target {
        case .window(let info):
            guard let window = snapshot.window(info.id) else { throw CocoaError(.fileNoSuchFile) }
            configuration.width = even(window.frame.width * display.scale)
            configuration.height = even(window.frame.height * display.scale)
            configuration.scalesToFit = true
            return (SCContentFilter(desktopIndependentWindow: window), configuration)
        case .area, .display:
            guard let scDisplay = snapshot.display(display.displayID) else { throw CocoaError(.fileNoSuchFile) }
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            var area = bounds
            if case .area(let rect) = choice.target {
                area = CaptureRecordingArea.snap(rect, scale: display.scale, bounds: bounds)
                configuration.sourceRect = area
            }
            configuration.width = even(area.width * display.scale)
            configuration.height = even(area.height * display.scale)
            let excluded = CaptureOwnWindows.excluded(includeIsland: includeIsland)
            return (snapshot.filter(display: scDisplay, excluding: excluded), configuration)
        }
    }

    private func stop() {
        guard let stream, case .recording = state else { return }
        state = .finishing
        diskWatch?.cancel()
        Task {
            try? await stream.stopCapture()
            // The file is finished by the recording output's callback; give it a moment before
            // treating a quiet stop as done.
            try? await Task.sleep(for: .seconds(5))
            if case .finishing = self.state { self.handle(.finished) }
        }
    }

    private func handle(_ event: RecorderRelay.Event) {
        guard stream != nil else { return }
        switch event {
        case .finished:
            guard let url else { return }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists { saved(url) }
            let folder = url.deletingLastPathComponent().lastPathComponent
            finish(exists ? .message(stoppedForDisk ? "Stopped: the disk is almost full" : "Saved to \(folder)",
                                     symbol: stoppedForDisk ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                     tint: stoppedForDisk ? .orange : .green)
                          : .message("Recording failed", symbol: "exclamationmark.triangle.fill", tint: .orange))
        case .failed:
            if case .recording = state {
                // The stream ended on its own (display gone, access revoked): keep what was written.
                stop()
            } else if case .finishing = state {
                handle(.finished)
            }
        }
    }

    private func watchDisk(_ folder: URL) {
        diskWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let free = await Task.detached { CaptureFiles.freeSpace(at: folder) }.value
                guard let self, !Task.isCancelled else { return }
                if let free, CaptureRecordingRules.mustStop(freeBytes: free) {
                    self.stoppedForDisk = true
                    self.stop()
                    return
                }
            }
        }
    }

    /// Releases the stream and the sleep hold; a last message stays in the pill for a moment.
    private func finish(_ message: State?) {
        work?.cancel()
        work = nil
        diskWatch?.cancel()
        diskWatch = nil
        stream = nil
        output = nil
        relay = nil
        url = nil
        stoppedForDisk = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard let message else {
            state = .idle
            closePill()
            return
        }
        state = message
        work = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !Task.isCancelled else { return }
            self.state = .idle
            self.closePill()
        }
    }

    private func showPill(on display: FrozenDisplay) {
        let screen = NSScreen.screens.first { $0.captureDisplayID == display.displayID } ?? NSScreen.main
        guard let screen else { return }
        let panel = RecordingPillPanel(recording: self, screen: screen)
        panel.orderFrontRegardless()
        pill = panel
    }

    private func closePill() {
        pill?.retire()
        pill = nil
    }
}

/// The recording pill's window: 10 pt under the menu bar, centred, above ordinary windows. It floats
/// rather than living in the menu bar, so a crowded bar can never hide the Stop button.
@MainActor
final class RecordingPillPanel: CaptureUtilityPanel {
    static let size = CGSize(width: 360, height: 32)

    init(recording: CaptureRecordingController, screen: NSScreen) {
        let frame = CGRect(x: (screen.frame.midX - Self.size.width / 2).rounded(), y: screen.visibleFrame.maxY - 10 - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        super.init(frame: frame, level: .statusBar)
        contentView = CaptureHostingView(rootView: RecordingPill(recording: recording))
        setFrame(frame, display: false)
    }
}

/// The live pill, following the recorder.
struct RecordingPill: View {
    @ObservedObject var recording: CaptureRecordingController
    var body: some View {
        RecordingPillView(state: recording.state) { recording.stopOrCancel() }
    }
}

/// The pill's look for one recorder state: countdown with Cancel, the pulsing dot, elapsed time and
/// Stop, then a last word (saved, refused or failed).
struct RecordingPillView: View {
    let state: CaptureRecordingController.State
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(minWidth: 150, minHeight: 32, maxHeight: 32)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: RecordingPillPanel.size.width, height: RecordingPillPanel.size.height)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .countdown(let remaining):
            Image(systemName: "record.circle").foregroundStyle(.red)
            Text("Recording in \(remaining)")
            Spacer(minLength: 4)
            pillButton("xmark", "Cancel")
        case .recording(let since):
            RecordingDot()
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(CaptureRecordingRules.elapsed(context.date.timeIntervalSince(since)))
            }
            Spacer(minLength: 4)
            pillButton("stop.fill", "Stop recording")
        case .finishing:
            ProgressView().controlSize(.mini)
            Text("Saving…")
        case .message(let text, let symbol, let tint):
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    private func pillButton(_ symbol: String, _ label: String) -> some View {
        Button(action: stop) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 11))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The pulsing red dot: full to 28% and back over 0.85 s.
private struct RecordingDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(Color.red).frame(width: 8, height: 8)
            .opacity(dim ? 0.28 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { dim = true } }
            .accessibilityHidden(true)
    }
}
