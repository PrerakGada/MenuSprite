import AIAccounts
import AppKit
import ProductFeedback
import SwiftUI

// "Report a Problem…" and "Send Feedback…" (hub → Tools). One small window, built when one of them is
// pressed and released when it closes, so nothing of it exists at rest. Nothing is sent until Send is
// pressed; the message goes to the shared product-feedback endpoint with only the facts the form lists.

/// The hub's Tools card that opens the feedback window.
struct HubFeedbackCard: View {
    let close: () -> Void

    var body: some View {
        HubCard(title: "Help & feedback") {
            Text("Something not working, or an idea? It goes straight to Prerak, who makes MenuSprite.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { close(); FeedbackWindowController.shared.show(.problem) } label: {
                    Label("Report a Problem…", systemImage: "exclamationmark.bubble")
                }
                .accessibilityIdentifier("hub-report-problem")
                Button { close(); FeedbackWindowController.shared.show(.idea) } label: {
                    Label("Send Feedback…", systemImage: "bubble.left")
                }
                .accessibilityIdentifier("hub-send-feedback")
            }
            .controlSize(.small)
        }
    }
}

/// Owns the feedback window while it is open. It is an ordinary titled window, not a panel: typing
/// needs a key window, which the hub's non-activating panel cannot be.
@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindowController()
    static let product = "menusprite"
    static let appName = "MenuSprite"

    /// The real sender exists only in an ordinary launch (no arguments, or the `--background` relaunch).
    /// Validation, measurement, render and diagnostic launches get a sender that fails at once, so they
    /// can never post anything.
    static let sendsForReal = CommandLine.arguments.dropFirst().allSatisfy { !$0.hasPrefix("--") || $0 == "--background" }

    private var window: NSWindow?
    private var model: FeedbackFormModel?

    var isOpen: Bool { window != nil }

    /// Opens the window with `kind` chosen, or brings the open one forward. An open window keeps what was
    /// typed; its kind only follows the new request while the message is still empty.
    func show(_ kind: FeedbackKind) {
        if let window, let model {
            if model.message.isEmpty { model.kind = kind }
            present(window)
            return
        }
        let model = FeedbackFormModel(kind: kind, client: Self.makeClient())
        let window = FeedbackWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = kind.windowTitle
        window.delegate = self
        let host = NSHostingController(rootView: FeedbackForm(model: model, close: { [weak window] in window?.close() }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        model.onKindChange = { [weak window] kind in window?.title = kind.windowTitle }
        window.center()
        self.window = window
        self.model = model
        present(window)
    }

    private func present(_ window: NSWindow) {
        // Same as the main window: a Dock icon while open, so it behaves in ⌘-Tab and Stage Manager.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func makeClient() -> FeedbackClient {
        FeedbackClient(product: product, context: .current(appName: appName),
                       transport: sendsForReal ? URLSessionTransport() : OfflineFeedbackTransport())
    }

    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        model?.cancel()
        window.delegate = nil
        window.contentViewController = nil
        self.window = nil
        model = nil
        let mainWindowOpen = (NSApp.delegate as? AppDelegate)?.appWindow?.isVisible == true
        if !mainWindowOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Handles ⌘W itself: the app's Close command only knows MenuSprite's main window and pop-ups.
private final class FeedbackWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The form's state. Name and email live here only while the window is open; nothing is saved.
@MainActor
final class FeedbackFormModel: ObservableObject {
    enum Phase: Equatable { case editing, sending, sent }

    @Published var kind: FeedbackKind { didSet { if kind != oldValue { onKindChange?(kind) } } }
    @Published var message = ""
    @Published var name = ""
    @Published var email = ""
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var error: String?
    let context: FeedbackContext
    var onKindChange: ((FeedbackKind) -> Void)?
    private let client: FeedbackClient
    private var task: Task<Void, Never>?

    init(kind: FeedbackKind, client: FeedbackClient) {
        self.kind = kind
        self.client = client
        context = client.context
    }

    var draft: FeedbackDraft { FeedbackDraft(kind: kind, message: message, name: name, email: email) }
    var canSend: Bool { phase == .editing && draft.canSend }

    func send() {
        guard canSend else { return }
        if let problem = draft.problem { error = problem; return }
        error = nil
        phase = .sending
        let client = self.client, draft = self.draft
        task = Task { [weak self] in
            let outcome = await client.send(draft)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            if case .sent = outcome {
                self.phase = .sent
            } else {
                self.phase = .editing
                self.error = outcome.errorMessage
            }
        }
    }

    /// Closing the window abandons a send that has not answered yet.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// For `--feedback-render` only: shows a state without sending anything.
    func stage(_ phase: Phase, error: String? = nil) {
        self.phase = phase
        self.error = error
    }
}

struct FeedbackForm: View {
    @ObservedObject var model: FeedbackFormModel
    let close: () -> Void
    @FocusState private var messageFocused: Bool

    var body: some View {
        Group {
            if model.phase == .sent { sent } else { form }
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Kind", selection: $model.kind) {
                ForEach(FeedbackKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(model.phase == .sending)
            .accessibilityIdentifier("feedback-kind")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("feedback-message")
                if model.message.isEmpty {
                    Text(model.kind.placeholder(appName: FeedbackWindowController.appName))
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            .disabled(model.phase == .sending)

            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Your name").gridColumnAlignment(.trailing)
                        TextField("Your name", text: $model.name, prompt: Text("Optional"))
                            .labelsHidden().autocorrectionDisabled().accessibilityIdentifier("feedback-name")
                    }
                    GridRow {
                        Text("Email")
                        TextField("Email", text: $model.email, prompt: Text("Optional"))
                            .labelsHidden().autocorrectionDisabled().accessibilityIdentifier("feedback-email")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .disabled(model.phase == .sending)
                Text("Optional. Add your email if you'd like a reply.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("Sent with your message: \(model.context.summary)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback-error")
            }

            Divider()

            HStack(alignment: .center, spacing: 10) {
                Text("Goes straight to Prerak, who makes \(FeedbackWindowController.appName). Nothing is sent until you press Send.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.phase == .sending {
                    ProgressView().controlSize(.small).accessibilityLabel("Sending")
                }
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                // ⌘↩, not plain Return: Return has to start a new line in the message.
                Button("Send", action: model.send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSend)
                    .help("Send (⌘↩)")
                    .accessibilityIdentifier("feedback-send")
            }
        }
        .padding(20)
        .onAppear { DispatchQueue.main.async { messageFocused = true } }
    }

    private var sent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Thanks, it's sent.").font(.system(size: 17, weight: .semibold))
            Text("If you added your email, I may reply.").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Close", action: close)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34).padding(.horizontal, 20)
    }
}

/// Draws the feedback window's states and the hub card to PNG files without showing a window or
/// sending anything (the form's client is the offline one).
///
///     MenuSprite --feedback-render <dir>
@MainActor
enum FeedbackRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--feedback-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = FeedbackClient(product: FeedbackWindowController.product, context: .current(appName: FeedbackWindowController.appName),
                                    transport: OfflineFeedbackTransport())

        func model(_ kind: FeedbackKind, _ message: String = "", name: String = "", email: String = "",
                   phase: FeedbackFormModel.Phase = .editing, error: String? = nil) -> FeedbackFormModel {
            let model = FeedbackFormModel(kind: kind, client: client)
            model.message = message; model.name = name; model.email = email
            model.stage(phase, error: error)
            return model
        }
        let states: [(String, FeedbackFormModel)] = [
            ("problem-empty", model(.problem)),
            ("idea-empty", model(.idea)),
            ("feedback-empty", model(.feedback)),
            ("problem-filled", model(.problem, "The Wi-Fi board stays blank after waking from sleep.\nI expected the network name and bars.",
                                     name: "Asha", email: "asha@example.com")),
            ("sending", model(.idea, "A clock sprite with the date underneath.", phase: .sending)),
            ("error-offline", model(.problem, "The fan board is blank.", error: FeedbackOutcome.couldNotSend)),
            ("error-rate-limit", model(.problem, "The fan board is blank.",
                                       error: "That's a lot of messages in a short time. Please try again in a few minutes.")),
            ("sent", model(.idea, "Thanks!", phase: .sent)),
        ]
        var written: [String] = []
        for (name, state) in states {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                if write(FeedbackForm(model: state, close: {}), appearance: appearance, to: directory.appendingPathComponent("\(name)-\(suffix).png")) {
                    written.append("\(name)-\(suffix)")
                }
            }
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let card = HubFeedbackCard(close: {}).frame(width: 452).padding(14).background(Color(nsColor: .windowBackgroundColor))
            if write(card, appearance: appearance, to: directory.appendingPathComponent("hub-card-\(suffix).png")) {
                written.append("hub-card-\(suffix)")
            }
        }
        print("Feedback render: \(written.count) images in \(directory.path) · sends with: \(client.context.summary) · live sender in this launch: \(FeedbackWindowController.sendsForReal)")
        exit(written.count == states.count * 2 + 2 ? 0 : 1)
    }

    private static func write(_ view: some View, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}
