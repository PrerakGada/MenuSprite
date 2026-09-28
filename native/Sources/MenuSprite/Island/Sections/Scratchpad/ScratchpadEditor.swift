import AppKit
import SwiftUI

/// The scratchpad's editor: a plain-text AppKit text view, white on black, with every automatic
/// substitution off and undo on. One instance per pad (the caller keys it by the pad's id), so undo
/// never crosses tabs. It takes the caret only when its window holds the keyboard.
struct ScratchpadEditor: NSViewRepresentable {
    let text: String
    let focusSerial: Int
    let clearSerial: Int
    /// True while the Markdown preview covers it: it stays underneath but lets go of the keyboard.
    let hidden: Bool
    let onChange: (String) -> Void
    let onClear: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.lineFragmentPadding = 5
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Scratchpad")
        context.coordinator.textView = textView
        context.coordinator.lastClear = clearSerial
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if !coordinator.isEditing, textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if clearSerial != coordinator.lastClear {
            coordinator.lastClear = clearSerial
            coordinator.clear()
        }
        if hidden {
            if textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
        } else if focusSerial != coordinator.lastFocus {
            coordinator.lastFocus = focusSerial
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.focusAtEnd() } }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadEditor
        weak var textView: NSTextView?
        var lastFocus = Int.min
        var lastClear = 0
        var isEditing = false

        init(_ parent: ScratchpadEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            parent.onChange(textView.string)
            isEditing = false
        }

        /// Puts the caret at the end and scrolls to it, but only in a window that has the keyboard.
        func focusAtEnd() {
            guard let textView, let window = textView.window, window.isKeyWindow, !parent.hidden else { return }
            window.makeFirstResponder(textView)
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }

        /// Clears through the text view so a single ⌘Z brings everything back; a live input-method
        /// composition is committed first.
        func clear() {
            guard let textView else { return }
            if textView.hasMarkedText() { textView.unmarkText() }
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            guard range.length > 0, textView.shouldChangeText(in: range, replacementString: "") else { return }
            textView.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            textView.undoManager?.setActionName("Clear")
            parent.onClear()
        }
    }
}
