import AppKit
import IslandKit
import SwiftUI

/// A percentage that becomes a text field when clicked. Only one field on the page edits at a time
/// (`editing` holds the owner's id). A bolt and orange text mark a boost above 100 %.
struct MixerPercentLabel: View {
    let id: String
    let gain: Double
    let maximum: Double
    @Binding var editing: String?
    var enabled = true
    let commit: (Double) -> Void

    var body: some View {
        let boosting = MixerLevel.isBoosting(gain)
        if editing == id {
            MixerPercentField(text: "\(MixerLevel.percent(gain))", maximum: maximum,
                              commit: { value in
                                  editing = nil
                                  commit(value)
                              },
                              cancel: { editing = nil })
                .frame(width: 44, height: 18)
        } else {
            Button { editing = id } label: {
                HStack(spacing: 1) {
                    if boosting { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)) }
                    Text("\(MixerLevel.percent(gain))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(boosting ? Color.orange : Color.white.opacity(0.85))
                .frame(minWidth: 36, minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help("Click to type a level")
            .accessibilityLabel("\(MixerLevel.percent(gain)) percent")
        }
    }
}

/// The native field behind the label: prefilled, focused and fully selected when it appears. Return
/// commits (an invalid entry beeps and keeps editing), Escape cancels, losing focus commits a valid
/// entry and cancels an invalid one.
struct MixerPercentField: NSViewRepresentable {
    let text: String
    let maximum: Double
    let commit: (Double) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MixerPercentTextField {
        let field = MixerPercentTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.1)
        field.textColor = .white
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.setAccessibilityLabel("Level in percent")
        return field
    }

    func updateNSView(_ field: MixerPercentTextField, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MixerPercentField
        private var finished = false

        init(_ parent: MixerPercentField) { self.parent = parent }

        private func value(_ text: String) -> Double? { MixerLevel.parsePercent(text, maximum: parent.maximum) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let value = value(control.stringValue) { finish { self.parent.commit(value) } } else { NSSound.beep() }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish { self.parent.cancel() }
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let value = value(field.stringValue) { finish { self.parent.commit(value) } } else { finish { self.parent.cancel() } }
        }

        private func finish(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }
}

/// Takes focus and selects its text as soon as it is in a window (a SwiftUI field inside the island's
/// panel can try to focus before it has one).
final class MixerPercentTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}
