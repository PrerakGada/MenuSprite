import AppKit
import IslandKit
import SwiftUI

// The contract between the Dynamic Island shell and everything it hosts. The shell owns the window,
// geometry, opening and closing, navigation, the notice slot and the activity picker; sections,
// Controls tiles, cards and feature modules plug in through the types below and never touch the
// window. Everything here runs on the main actor.

/// Whether something can work right now, and if not, why and how to fix it.
struct IslandAvailability {
    var reason: String?
    var fixTitle: String?
    var fix: (@MainActor () -> Void)?

    static let available = IslandAvailability()
    static func unavailable(_ reason: String, fixTitle: String? = nil, fix: (@MainActor () -> Void)? = nil) -> IslandAvailability {
        IslandAvailability(reason: reason, fixTitle: fixTitle, fix: fix)
    }
    /// A part of the island MenuSprite has not built yet. Hidden from the island, listed honestly in settings.
    static let notBuilt = IslandAvailability.unavailable("Not built in MenuSprite yet.")

    var isAvailable: Bool { reason == nil }
}

/// What a page is told when it is asked for its height or its view.
struct IslandPageContext {
    /// Width available to the page's content.
    var width: CGFloat
    /// The most height the page may take.
    var budget: CGFloat
    /// True in the settings preview: never start hardware (camera, audio capture), never take the keyboard.
    var isPreview: Bool
    var environment: IslandEnvironment
}

/// Anything the island starts and stops with its master switch: sections, and modules that have no
/// page of their own (volume keys, battery notices, accessory alerts).
@MainActor
protocol IslandFeature: AnyObject {
    /// The island turned on (or the app launched with it on). Start only the observers this feature
    /// needs for live activities or notices; nothing that only a visible page needs.
    func islandDidStart()
    /// The island turned off, the session locked, or the Mac went to sleep. Release everything.
    func islandDidStop()
}

extension IslandFeature {
    func islandDidStart() {}
    func islandDidStop() {}
}

/// One page of the open island.
@MainActor
protocol IslandSection: IslandFeature {
    var id: IslandSectionID { get }
    /// Cheap and synchronous. Unavailable sections disappear from the island and show their reason
    /// in the Content tab. Call `environment.invalidate()` when this changes.
    var availability: IslandAvailability { get }
    /// Tall pages (lists, detail pages) get at least 320 pt in the preset sizes.
    var isVertical: Bool { get }
    /// True while the page needs a full-width header row below the camera for its own actions
    /// (a capture being previewed), instead of the header split beside the camera.
    var wantsFullHeaderRow: Bool { get }
    /// The height the page needs, never more than `context.budget`. Called on every layout.
    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight
    /// The page itself. Built only while it is visible (or in the settings preview).
    func page(_ context: IslandPageContext) -> AnyView
    /// Optional controls on the right of the header, beside the "…" menu.
    func headerAccessory(_ context: IslandPageContext) -> AnyView?
    /// This section's options card in Settings › Content; nil shows "This section has no options."
    func options() -> AnyView?
    /// The page became visible, or stopped being visible. Start and stop page-only sampling here.
    func pageDidAppear()
    func pageDidDisappear()
}

extension IslandSection {
    var isVertical: Bool { false }
    var wantsFullHeaderRow: Bool { false }
    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight { .fill }
    func headerAccessory(_ context: IslandPageContext) -> AnyView? { nil }
    func options() -> AnyView? { nil }
    func pageDidAppear() {}
    func pageDidDisappear() {}
}

/// A shortcut tile on the Controls page, also usable as a floating button. The feature that owns the
/// tile creates one model, registers it, and keeps its published state current.
@MainActor
final class IslandControlModel: ObservableObject, Identifiable {
    let id: IslandControlID
    @Published var availability: IslandAvailability
    /// Drawn highlighted: keep awake on, microphone muted, recording.
    @Published var isOn = false
    @Published var title: String
    @Published var symbol: String
    var perform: @MainActor () -> Void

    init(_ id: IslandControlID, availability: IslandAvailability = .available, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.availability = availability
        self.title = id.title
        self.symbol = id.symbol
        self.perform = perform
    }
}

/// How the Controls page asks a card to draw itself.
enum IslandCardStyle: Equatable {
    /// A card of its own, this tall (68…96 pt). Level cards show their device menu only at ≥ 88 pt.
    case card(height: CGFloat)
    /// One row inside the shared 160-pt levels card beside Now Playing (levels only).
    case row
}

/// One of the Controls page's cards (Now Playing, Volume, Brightness), provided by the feature that owns it.
/// The shell draws the card surface; the provider draws the contents.
@MainActor
struct IslandCardProvider {
    var availability: () -> IslandAvailability
    var view: (IslandCardStyle, IslandPageContext) -> AnyView
}

/// A compact live activity's strip beside the camera. The owner publishes a new value only when
/// liveness or width changes; ticking text inside the views observes the owner's own model.
struct IslandCompactStrip {
    var kind: IslandActivityKind
    /// The fitted wing width, already clamped to this kind's range.
    var wing: CGFloat
    /// Below this much side room the wings are dropped (width 0).
    var minimumRoom: CGFloat
    /// Downloads and calendar may use one row below a physical camera when there is no side room.
    var allowsFooter = false
    var left: AnyView
    var right: AnyView
    /// What this activity shows in a running timer's left wing when combined with it.
    var companionMark: AnyView?
    /// The optional outline's colour around this strip (orange for the timer).
    var outline: Color?
    /// True while the underlying thing is running (a timer counting down, music playing).
    var isRunning = true
    /// For activities whose wing depends on the side room (a download grows to fit its file name when
    /// the menu bar leaves room): the wing for a given side room and strip height, already clamped.
    /// Nil means `wing` whenever the room is at least `minimumRoom`.
    var wingForRoom: ((_ room: CGFloat, _ height: CGFloat) -> CGFloat)?
}

/// A transient notice in the closed island's one notice slot.
struct IslandNotice: Identifiable {
    enum Style {
        /// Volume, brightness, keyboard light: symbol + percent on the left, a meter on the right.
        case level(symbol: String, value: Double)
        /// Symbol (or image) and title on the left, detail on the right.
        case text(symbol: String?, image: NSImage?, title: String, detail: String, cameraGap: CGFloat = 6,
                  maxWing: CGFloat = 240, tint: Color? = nil, meter: Double? = nil)
        /// Anything else: the owner draws both wings.
        case custom(wing: CGFloat, left: AnyView, right: AnyView)
    }

    let id = UUID()
    var kind: IslandNoticeKind
    var style: Style
    /// Accessibility text: "title, detail".
    var label: String
    /// The page a click opens; defaults to the kind's page.
    var destination: IslandSectionID?
    /// A mirrored notification's full message card, shown in place when the pointer rests on the
    /// banner (the shell sizes it: preview width, content height).
    var expanded: AnyView?
    var expandedHeight: CGFloat = 0
    /// What a click on the notice does instead of opening `destination` (a mirrored notification
    /// opens the message itself). Nil opens the destination.
    var action: (@MainActor () -> Void)?
}

/// Where the shell's actions go. Set by the controller; sections call these through the environment.
@MainActor
struct IslandActions {
    var open: (IslandDestination?) -> Void = { _ in }
    var close: () -> Void = {}
    var togglePin: () -> Void = {}
    /// Re-measure page heights and re-lay out the open island (a list grew, lyrics opened).
    var invalidate: () -> Void = {}
    /// Opens Settings › Dynamic Island, optionally with a section selected in the Content tab.
    var openSettings: (IslandSectionID?) -> Void = { _ in }
    /// The app's own panel (the hub), in the island or its window per settings.
    var openAppPanel: () -> Void = {}
    /// Hold the island open while a dialog, menu or picker of its own is up.
    var holdOpen: (Bool) -> Void = { _ in }
    /// Collapses the island and runs the action once its closing animation has settled, so a
    /// screenshot, command bar or window opened next never captures or sits under the island.
    var closeThen: (@escaping @MainActor () -> Void) -> Void = { $0() }
}

/// What the closed island shows at rest for one "At rest" choice. Returns nil when there is nothing
/// to show (no battery, no AI data yet); the island then rests as the bare camera.
@MainActor
struct IslandRestProvider {
    var wings: () -> (left: AnyView, right: AnyView)?
}

/// An audio device as the island shows it.
struct IslandAudioDevice: Identifiable, Hashable, Sendable {
    var id: UInt32
    var uid: String
    var name: String
    var symbol = "speaker.wave.2"
}

/// The system's output and input as one observable state, shared by the Controls volume card, the
/// Now Playing page's inline volume and the Volume mixer page. The audio module owns the CoreAudio
/// work behind it and fills in the actions; everyone else only reads and calls. It observes CoreAudio
/// only while someone holds interest (`retain`/`release`) or the volume indicator needs it.
@MainActor
final class IslandSystemAudio: ObservableObject {
    @Published var outputs: [IslandAudioDevice] = []
    @Published var output: IslandAudioDevice?
    /// 0…1, or nil when the current output has no settable volume.
    @Published var volume: Double?
    @Published var isMuted = false
    @Published var hasMute = false
    @Published var inputs: [IslandAudioDevice] = []
    @Published var input: IslandAudioDevice?
    @Published var inputVolume: Double?
    /// The last output-switch error, shown in orange in place of the device name.
    @Published var error: String?

    var setVolume: (Double) -> Void = { _ in }
    var setMuted: (Bool) -> Void = { _ in }
    var selectOutput: (IslandAudioDevice) -> Void = { _ in }
    var selectInput: (IslandAudioDevice) -> Void = { _ in }
    var setInputVolume: (Double) -> Void = { _ in }
    /// Called when interest goes from zero to some, or back to zero.
    var demandChanged: (Bool) -> Void = { _ in }

    private(set) var interest = 0
    func retain() { interest += 1; if interest == 1 { demandChanged(true) } }
    func release() { guard interest > 0 else { return }; interest -= 1; if interest == 0 { demandChanged(false) } }
}
