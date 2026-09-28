import AppKit
import IslandKit
import SwiftUI

/// App icons for the mixer's columns, drawn once into small bitmaps and kept only for listed apps.
@MainActor
enum MixerIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: MixerApp) -> NSImage {
        if let cached = cache[app.id] { return cached }
        let source = NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        let image = bitmap(source)
        cache[app.id] = image
        return image
    }

    /// Drops icons of apps no longer listed.
    static func keep(_ ids: Set<String>) {
        guard cache.keys.contains(where: { !ids.contains($0) }) else { return }
        cache = cache.filter { ids.contains($0.key) }
    }

    private static func bitmap(_ source: NSImage) -> NSImage {
        let side: CGFloat = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The system output's column: mute, fader (0…100 %) and its percentage.
struct MixerMasterColumn: View {
    @ObservedObject var audio: IslandSystemAudio
    let layout: MixerDeskLayout
    @Binding var editing: String?

    var body: some View {
        VStack(spacing: MixerDeskLayout.spacing) {
            Button { audio.setMuted(!audio.isMuted) } label: {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(audio.isMuted ? Color.red : Color.white.opacity(0.85))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 10))
            .disabled(!audio.hasMute)
            .opacity(audio.hasMute ? 1 : 0.45)
            .help(audio.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")
            .frame(height: MixerDeskLayout.topHeight)
            MixerCaption(text: "Output")
            if let volume = audio.volume {
                let shown = audio.isMuted ? 0 : volume
                IslandLevelSlider(value: Binding(get: { shown }, set: set), range: 0...MixerLevel.systemMaximum, vertical: true,
                                  accessibilityLabel: "Output volume")
                    .frame(width: MixerDeskLayout.faderWidth, height: layout.track)
                MixerPercentLabel(id: "system", gain: shown, maximum: MixerLevel.systemMaximum, editing: $editing, commit: set)
                    .frame(height: MixerDeskLayout.footerHeight)
            } else {
                Text("Output unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(height: layout.track + MixerDeskLayout.footerHeight + MixerDeskLayout.spacing)
            }
        }
        .frame(width: MixerDeskLayout.masterWidth)
    }

    /// Raising the level above zero also unmutes, as the volume keys do.
    private func set(_ value: Double) {
        if audio.isMuted, value > 0 { audio.setMuted(false) }
        audio.setVolume(value)
    }
}

/// One app's column: icon with its playing, route and pin marks, name, fader (0…200 % with a mark at
/// 100 %), reset, percentage and mute. Apps that manage their own audio get no fader.
struct MixerAppColumn: View {
    let row: MixerRow
    let outputs: [MixerDevice]
    let layout: MixerDeskLayout
    @Binding var editing: String?
    let controller: MixerController

    var body: some View {
        VStack(spacing: MixerDeskLayout.spacing) {
            header.frame(height: MixerDeskLayout.topHeight)
            if row.couldNotApply {
                MixerCaption(text: "Couldn’t apply", tint: .orange)
                    .help("MenuSprite could not apply this level or output, so \(row.app.name) plays as usual. Change it to try again.")
                    .accessibilityLabel("\(row.app.name): level could not be applied")
            } else {
                MixerCaption(text: row.app.name)
            }
            if row.app.isBypassed {
                Text("Set this app’s volume in the app itself.")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(height: layout.track + MixerDeskLayout.footerHeight + MixerDeskLayout.spacing)
            } else {
                IslandLevelSlider(value: Binding(get: { row.gain }, set: { controller.setGain($0, for: row) }),
                                  range: 0...MixerLevel.appMaximum, vertical: true, marker: MixerLevel.unity, overTint: .orange,
                                  editingChanged: { controller.setEditing(row, $0) }, accessibilityLabel: "\(row.app.name) volume")
                    .frame(width: MixerDeskLayout.faderWidth, height: layout.track)
                footer.frame(height: MixerDeskLayout.footerHeight)
            }
        }
        .frame(width: MixerDeskLayout.columnWidth)
        .contentShape(Rectangle())
        .contextMenu { MixerAppMenu(row: row, outputs: outputs, controller: controller) }
        .help(row.app.name)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(IslandStyle.tertiaryText)
                .frame(width: 18)
                .opacity(row.isPinned ? 1 : 0)
                .accessibilityHidden(!row.isPinned)
            Spacer(minLength: 0)
            icon
            Spacer(minLength: 0)
            Menu { MixerAppMenu(row: row, outputs: outputs, controller: controller) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandStyle.secondaryText)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .accessibilityLabel("\(row.app.name) options")
        }
    }

    private var icon: some View {
        Image(nsImage: MixerIcons.icon(for: row.app))
            .resizable()
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                if row.app.isPlaying {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .accessibilityLabel("Playing")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if row.route != nil { routeBadge.offset(x: -3, y: 3) }
            }
    }

    private var routeBadge: some View {
        let name = outputs.first { $0.uid == row.route }?.name
        return Image(systemName: row.routeMissing ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(row.routeMissing ? Color.orange : Color.white)
            .padding(2)
            .background(Circle().fill(Color.black))
            .help(row.routeMissing ? "Playing on the default output until this device is back." : (name ?? "Own output"))
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { controller.reset(row) } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 6))
            .foregroundStyle(IslandStyle.secondaryText)
            .opacity(row.gain == MixerLevel.unity ? 0 : 1)
            .disabled(row.gain == MixerLevel.unity)
            .help("Reset to 100%")
            MixerPercentLabel(id: row.id, gain: row.gain, maximum: MixerLevel.appMaximum, editing: $editing) { controller.setGain($0, for: row) }
            Button { controller.toggleMute(row) } label: {
                Image(systemName: row.gain <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(row.gain <= 0 ? Color.red : IslandStyle.secondaryText)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 6))
            .help(row.gain <= 0 ? "Unmute" : "Mute")
            .accessibilityLabel(row.gain <= 0 ? "Unmute \(row.app.name)" : "Mute \(row.app.name)")
        }
    }
}

/// The app menu (ellipsis or right-click): pin and move, output, reset, hide. Apps with no stable
/// identity get only the output choice and reset.
struct MixerAppMenu: View {
    let row: MixerRow
    let outputs: [MixerDevice]
    let controller: MixerController

    var body: some View {
        if row.isArrangeable {
            Button(row.isPinned ? "Unpin" : "Pin to Front") { controller.togglePin(row) }
            Button("Move Left") { controller.move(row, forward: false) }.disabled(!row.canMoveLeft)
            Button("Move Right") { controller.move(row, forward: true) }.disabled(!row.canMoveRight)
            Divider()
        }
        if !row.app.isBypassed {
            Section("Output") {
                Toggle("Default", isOn: Binding(get: { row.route == nil }, set: { if $0 { controller.setRoute(nil, for: row) } }))
                ForEach(outputs, id: \.uid) { device in
                    Toggle(device.isDefault ? "\(device.name) (current)" : device.name,
                           isOn: Binding(get: { row.route == device.uid && !row.routeMissing },
                                         set: { if $0 { controller.setRoute(device.uid, for: row) } }))
                }
                if row.routeMissing {
                    Toggle("Output unavailable", isOn: .constant(true)).disabled(true)
                }
            }
            Divider()
            Button("Reset to 100%") { controller.reset(row) }
        }
        if row.isArrangeable {
            Divider()
            Button("Hide from the list") { controller.hide(row) }
        }
    }
}

/// A one-line caption under a column's top control.
struct MixerCaption: View {
    let text: String
    var tint = Color.white.opacity(0.75)
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .frame(height: MixerDeskLayout.captionHeight)
    }
}
