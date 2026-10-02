import AppKit
import SwiftUI

/// Draws the menu-bar icon choices to PNG files without showing anything or saving a choice:
/// the hub's picker card in both appearances, and every icon at real menu-bar size on a light and a
/// dark bar, in colour and (where it has one) monochrome.
///
///     MenuSprite --menu-bar-icon-render <dir>
@MainActor
enum MenuBarIconRenderHarness {
    static func runIfRequested() {
        // `--feedback-render` rides on this hook so MenuSpriteMain needs no edit; move it there when convenient.
        FeedbackRenderHarness.runIfRequested()
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--menu-bar-icon-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String] = []

        for (name, appearance, choice, monochrome) in [("card-dark", NSAppearance.Name.darkAqua, MenuBarIconChoice.arranger, false),
                                                       ("card-light", .aqua, .mochi, false),
                                                       ("card-mono-dark", .darkAqua, .peek, true)] {
            let host = NSHostingView(rootView: HubMenuBarIconCard(choice: choice, monochrome: monochrome).frame(width: 450).padding(12)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = directory.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            report.append("\(name) → \(url.lastPathComponent)")
        }

        // Every icon on a 24 pt bar, sized exactly as AppDelegate.applyMenuBarIcon sizes it.
        let height = max(18, NSStatusBar.system.thickness - 2)
        for (name, dark) in [("bar-light", false), ("bar-dark", true)] {
            for monochrome in [false, true] {
                let choices = MenuBarIconChoice.allCases.filter { !monochrome || $0.hasMonochrome }
                let images = choices.map { $0.image(monochrome: monochrome) }
                let widths = images.map { image in image.map { ceil(height * $0.size.width / max(1, $0.size.height)) } ?? 0 }
                let size = NSSize(width: widths.reduce(12) { $0 + $1 + 14 }, height: 24)
                let picture = NSImage(size: size, flipped: false) { rect in
                    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); rect.fill()
                    var x: CGFloat = 12
                    for (image, width) in zip(images, widths) {
                        guard let image else { continue }
                        let frame = NSRect(x: x, y: (24 - height) / 2, width: width, height: height)
                        if image.isTemplate {
                            let tinted = NSImage(size: frame.size, flipped: false) { r in
                                image.draw(in: r); (dark ? NSColor.white : NSColor.black).set(); r.fill(using: .sourceAtop); return true
                            }
                            tinted.draw(in: frame)
                        } else { image.draw(in: frame) }
                        x += width + 14
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
                let file = "\(name)\(monochrome ? "-mono" : "").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
                let missing = zip(choices, images).filter { $0.1 == nil }.map(\.0.rawValue)
                report.append("\(file): \(choices.count) icons at \(Int(height)) pt, missing \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
            }
        }
        print(report.joined(separator: "\n"))
        exit(0)
    }
}
