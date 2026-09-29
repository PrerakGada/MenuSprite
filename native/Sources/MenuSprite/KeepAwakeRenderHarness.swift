import AppKit
import SwiftUI

/// Draws the hub's Keep Awake card and every active icon × colour to PNG files without showing a
/// window, saving a setting or holding the Mac awake. The store reads a throwaway defaults suite.
///
///     MenuSprite --keep-awake-render <dir>
@MainActor
enum KeepAwakeRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--keep-awake-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "MenuSprite.KeepAwakeRender.\(UUID().uuidString)"
        let store = PowerStore(preferences: UserDefaults(suiteName: suite)!)
        store.jiggle = true
        for (name, appearance) in [("card-dark", NSAppearance.Name.darkAqua), ("card-light", .aqua)] {
            let host = NSHostingView(rootView: HubKeepAwakeCard(power: store, showAll: true).frame(width: 450).padding(12)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        // Rows: tints; columns: icons — on a dark and a light bar, at the brand item's real size.
        let height = max(18, NSStatusBar.system.thickness - 2), itemWidth = ceil(height * 1.5)
        for (name, dark) in [("icons-dark", true), ("icons-light", false)] {
            let cell = NSSize(width: itemWidth + 16, height: 26)
            let size = NSSize(width: cell.width * CGFloat(AwakeIcon.allCases.count) + 12, height: cell.height * CGFloat(AwakeTint.allCases.count) + 8)
            let picture = NSImage(size: size, flipped: true) { rect in
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); rect.fill()
                for (row, tint) in AwakeTint.allCases.enumerated() {
                    for (column, icon) in AwakeIcon.allCases.enumerated() {
                        guard let image = AwakeIconArt.image(icon: icon, tint: tint, size: NSSize(width: itemWidth, height: height)) else { continue }
                        let frame = NSRect(x: 6 + CGFloat(column) * cell.width + (cell.width - image.size.width) / 2,
                                           y: 4 + CGFloat(row) * cell.height + (cell.height - height) / 2, width: image.size.width, height: height)
                        if image.isTemplate {
                            NSImage(size: frame.size, flipped: false) { r in
                                image.draw(in: r); (dark ? NSColor.white : NSColor.black).set(); r.fill(using: .sourceAtop); return true
                            }.draw(in: frame)
                        } else { image.draw(in: frame) }
                    }
                }
                return true
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            picture.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        store.stopAwake()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Keep Awake render written to \(directory.path)")
        exit(0)
    }
}
