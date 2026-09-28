import AppKit
import IslandKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Content › Clipboard: turning history on, what macOS allows, where it opens, the
/// "Copied" notice, the shortcut, what is kept, apps to skip, and clearing it.
struct ClipboardOptionsView: View {
    @ObservedObject var model: ClipboardHistoryModel
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var settings: IslandSettingsStore
    @ObservedObject var shortcut: IslandToolShortcut
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $preferences.keepHistory) {
                labelled("Keep clipboard history",
                         "Keeps what you copy on this Mac only, in a private file (not encrypted). Nothing is read until this is on.")
            }
            .toggleStyle(.switch)
            if preferences.keepHistory { accessRow }
            accessibilityRow
            Picker("Where Clipboard opens", selection: Binding(
                get: { settings.value.clipboardInIsland },
                set: { value in settings.update { $0.clipboardInIsland = value } })) {
                Text("Dynamic Island").tag(true)
                Text("Separate window").tag(false)
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { settings.value.indicators.contains(.clipboard) },
                                 set: { on in settings.update { $0.setIndicator(.clipboard, on) } })) {
                labelled("Notify when something is copied", "Shows “Copied” in the island. Copied content stays private until you open the clipboard.")
            }
            .toggleStyle(.switch)
            IslandToolShortcutRow(title: "Open clipboard history", shortcut: $preferences.shortcut, registration: shortcut)
            Toggle("Also save copied images and files", isOn: $preferences.includeMedia).toggleStyle(.switch)
            Toggle(isOn: $preferences.skipSensitive) {
                labelled("Skip text that looks like a password or key",
                         "Copies that apps mark as private, such as from password managers, are always skipped.")
            }
            .toggleStyle(.switch)
            Picker("Keep up to", selection: Binding(get: { preferences.limit.stored },
                                                    set: { preferences.limit = ClipboardLimit(stored: $0) })) {
                ForEach(ClipboardLimit.storedChoices, id: \.self) { stored in
                    Text(stored == 0 ? "Unlimited" : "\(ClipboardLimit(stored: stored).title) items").tag(stored)
                }
            }
            Text("Pinned items never count toward the limit.").font(.caption).foregroundStyle(.secondary)
            ignoredApps
            Button("Clear History…", role: .destructive) { confirmingClear = true }
                .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
                    Button("Clear History", role: .destructive) { model.clearAll() }
                } message: {
                    Text("Every saved item goes, pinned ones too, with their images and files on disk.")
                }
        }
        .onAppear {
            guard !model.isPreview else { return }
            model.accessibilityTrusted = AXIsProcessTrusted()
            model.refreshAccess()
        }
    }

    private func labelled(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var accessRow: some View {
        switch model.access {
        case .allowed:
            status("MenuSprite can read what you copy.", ok: true)
        case .none:
            EmptyView()
        case .some(let access):
            VStack(alignment: .leading, spacing: 6) {
                status("Not saving yet: macOS asks before apps read what other apps copy.", ok: false)
                Text(access == .notAsked
                     ? "Press Ask macOS and choose Allow, or set MenuSprite to Allow in System Settings › Privacy & Security › Paste from Other Apps."
                     : "In System Settings › Privacy & Security › Paste from Other Apps, set MenuSprite to Allow.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if access == .notAsked { Button("Ask macOS") { model.askSystem() } }
                    Button("Open System Settings") { ClipboardHistoryModel.openPasteSettings() }
                }
            }
        }
    }

    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.accessibilityTrusted {
                status("Choosing an item pastes it into the app you were using.", ok: true)
            } else {
                status("Choosing an item copies it. To paste straight into apps, allow MenuSprite in Accessibility.", ok: false)
                Button("Open Accessibility Settings") { ClipboardHistoryModel.openAccessibilitySettings() }
            }
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
        }
        .font(.callout)
    }

    // MARK: Apps to skip

    private var ignoredApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            labelled("Apps to skip", "Copies made while one of these apps is in front are never kept.")
            ForEach(preferences.ignoredApps, id: \.self) { bundle in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(bundle)).resizable().frame(width: 18, height: 18)
                    Text(Self.name(bundle))
                    Spacer()
                    Button { preferences.ignoredApps.removeAll { $0 == bundle } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            Button("Add App…", action: addApps)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Skip"
        panel.begin { response in
            guard response == .OK else { return }
            let bundles = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated {
                for bundle in bundles where !preferences.ignoredApps.contains(bundle) { preferences.ignoredApps.append(bundle) }
            }
        }
    }

    private static func name(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(_ bundle: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
