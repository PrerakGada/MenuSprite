import Foundation

/// Virtual key codes the capture surfaces care about (the ANSI positions, whatever the layout types there).
public enum CaptureKeyCode {
    public static let returnKey: UInt16 = 36
    public static let enter: UInt16 = 76
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let forwardDelete: UInt16 = 117
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126
    public static let s: UInt16 = 1
    public static let c: UInt16 = 8
    public static let w: UInt16 = 13
    public static let e: UInt16 = 14
    public static let r: UInt16 = 15
    /// The digit row's 1, 2, 3, 4.
    public static let digits: [UInt16] = [18, 19, 20, 21]
}

/// A key press as the capture surfaces see it: the physical key, what it types with no modifiers,
/// and the modifiers held. Caps Lock and Fn are not part of it.
public struct CaptureKeyPress: Equatable, Sendable {
    public var keyCode: UInt16
    public var characters: String
    public var command: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool

    public init(keyCode: UInt16, characters: String = "", command: Bool = false, control: Bool = false,
                option: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode; self.characters = characters
        self.command = command; self.control = control; self.option = option; self.shift = shift
    }

    public var hasModifiers: Bool { command || control || option || shift }
    /// Exactly ⌘: a second modifier turns a command shortcut into something else.
    public var isCommandOnly: Bool { command && !control && !option && !shift }
    /// No ⌘, ⌃ or ⌥; Shift is allowed.
    public var isPlain: Bool { !command && !control && !option }

    /// Whether this is `letter` (lowercase ASCII): the letter typed on a Latin layout, or the physical
    /// key when the layout types a non-Latin letter there. A Latin layout that types another Latin letter
    /// at that position (an AZERTY "z" on the W key) does not match.
    public func isLetter(_ letter: Character, physical: UInt16) -> Bool {
        let typed = characters.lowercased()
        if typed == String(letter) { return true }
        if let scalar = typed.unicodeScalars.first, typed.unicodeScalars.count == 1, Self.isLatinLetter(scalar) { return false }
        return keyCode == physical
    }

    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A: true
        case 0xC0...0x24F where scalar.properties.isAlphabetic: true
        case 0x1E00...0x1EFF: true
        default: false
        }
    }
}

/// What a key does while the chooser is on screen.
public enum CaptureChooserAction: Equatable, Sendable {
    /// Leave it to the focused control (Tab, Space, arrows, a text field's Return).
    case passThrough
    /// Return with a control focused presses that control rather than capturing.
    case activateFocused
    /// Return with nothing focused captures the whole display under the pointer.
    case captureDisplay
    case cancel
    case repeatRegion
    case selectTool(CaptureTool)
    /// Space during a drag moves the selection.
    case moveSelection
    case ignore
}

public enum CaptureChooserKeys {
    public struct Context: Equatable, Sendable {
        public var controlHasFocus = false
        public var textFieldHasFocus = false
        public var dragging = false
        public var tools: [CaptureTool] = CaptureTool.allCases
        public init(controlHasFocus: Bool = false, textFieldHasFocus: Bool = false, dragging: Bool = false,
                    tools: [CaptureTool] = CaptureTool.allCases) {
            self.controlHasFocus = controlHasFocus; self.textFieldHasFocus = textFieldHasFocus
            self.dragging = dragging; self.tools = tools
        }
    }

    public static func action(for key: CaptureKeyPress, context: Context) -> CaptureChooserAction {
        switch key.keyCode {
        case CaptureKeyCode.escape:
            return .cancel
        case CaptureKeyCode.space:
            return context.dragging ? .moveSelection : .passThrough
        case CaptureKeyCode.tab, CaptureKeyCode.up, CaptureKeyCode.down, CaptureKeyCode.left, CaptureKeyCode.right:
            return .passThrough
        case CaptureKeyCode.returnKey, CaptureKeyCode.enter:
            if context.textFieldHasFocus { return .passThrough }
            return context.controlHasFocus ? .activateFocused : .captureDisplay
        default:
            break
        }
        guard key.isPlain else { return .ignore }
        if key.isLetter("r", physical: CaptureKeyCode.r) { return .repeatRegion }
        for (index, code) in CaptureKeyCode.digits.enumerated() {
            let digit = String(index + 1)
            guard key.characters == digit || key.keyCode == code else { continue }
            guard let tool = CaptureTool(number: index + 1), context.tools.contains(tool) else { return .ignore }
            return .selectTool(tool)
        }
        return .ignore
    }
}

/// What a key does to the quick preview.
public enum CapturePreviewAction: Equatable, Sendable {
    /// Open the capture for editing (in MenuSprite: in the default image editor).
    case edit
    /// Close the preview and move a saved file to the Trash.
    case discard
    case copy
    case save
    /// Close only; never destructive.
    case close
}

public enum CapturePreviewKeys {
    /// When the island may give keys to a preview it hosts: every one of these must hold.
    public struct Context: Equatable, Sendable {
        public var pageVisible = true
        public var islandExpanded = true
        public var exploreOrPanelShowing = false
        public var chooserActive = false
        public var previewCurrent = true
        public var textFieldHasFocus = false
        public var sheetAttached = false
        public var recordingShortcut = false
        public init() {}

        public var accepts: Bool {
            pageVisible && islandExpanded && !exploreOrPanelShowing && !chooserActive && previewCurrent
                && !textFieldHasFocus && !sheetAttached && !recordingShortcut
        }
    }

    public static func action(for key: CaptureKeyPress) -> CapturePreviewAction? {
        switch key.keyCode {
        case CaptureKeyCode.escape:
            return key.hasModifiers ? nil : .close
        case CaptureKeyCode.returnKey, CaptureKeyCode.enter:
            return key.hasModifiers ? nil : .edit
        case CaptureKeyCode.delete, CaptureKeyCode.forwardDelete:
            return !key.hasModifiers || key.isCommandOnly ? .discard : nil
        default:
            break
        }
        if key.isCommandOnly {
            if key.isLetter("c", physical: CaptureKeyCode.c) { return .copy }
            if key.isLetter("s", physical: CaptureKeyCode.s) { return .save }
            if key.isLetter("w", physical: CaptureKeyCode.w) { return .close }
            return nil
        }
        if !key.hasModifiers, key.isLetter("e", physical: CaptureKeyCode.e) { return .edit }
        return nil
    }
}
