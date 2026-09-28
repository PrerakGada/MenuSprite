import AppKit
import IslandKit
import SwiftUI

/// One entry of a pop-up menu a card shows.
enum IslandMenuEntry {
    case item(String, checked: Bool = false, enabled: Bool = true, action: @MainActor () -> Void)
    case separator
}

/// A plain button that pops an AppKit menu at the pointer. AppKit's pop-up runs synchronously, so
/// the island can be held open for exactly as long as the menu is up.
struct IslandMenuButton<Label: View>: View {
    let environment: IslandEnvironment
    let entries: () -> [IslandMenuEntry]
    @ViewBuilder let label: Label

    var body: some View {
        Button { IslandMenuPresenter.present(entries(), environment: environment) } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
enum IslandMenuPresenter {
    /// The last menu's handlers, kept until the next menu: an item's target is weak.
    private static var handlers: [IslandMenuHandler] = []

    static func present(_ entries: [IslandMenuEntry], environment: IslandEnvironment) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        handlers = []
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let checked, let enabled, let action):
                let handler = IslandMenuHandler(action)
                let item = NSMenuItem(title: title, action: #selector(IslandMenuHandler.run), keyEquivalent: "")
                item.target = handler
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
                handlers.append(handler)
            }
        }
        environment.actions.holdOpen(true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        environment.actions.holdOpen(false)
    }
}

@MainActor
final class IslandMenuHandler: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// The whole percent a level card shows, rolling its digits unless Reduce Motion is on.
struct IslandPercentText: View {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let percent = value.map(IslandLevelReadout.percent)
        Text(percent.map { "\($0)%" } ?? "—")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(percent ?? 0)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: percent)
    }
}

/// The readout menu of a level row: the percent right-aligned in a fixed column, then a chevron, so
/// the volume and brightness rows end on the same column and their sliders line up.
struct IslandReadoutLabel: View {
    let value: Double?
    var body: some View {
        HStack(spacing: 3) {
            IslandPercentText(value: value).frame(width: 36, alignment: .trailing)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(IslandStyle.secondaryText)
        }
    }
}

/// The device (or display) line under a tall level card: a symbol, the name and a chevron.
struct IslandDeviceLabel: View {
    let symbol: String
    let title: String
    var warning = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(warning ? Color.orange : IslandStyle.secondaryText)
    }
}
