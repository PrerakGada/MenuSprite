import AppKit
import IslandKit
import SwiftUI

/// Settings › Content › Recent captures: where previews and controls appear, what happens after a
/// screenshot, the save folder, recording sound, the two global shortcuts (none assigned until the
/// person records one) and the Screen Recording status.
struct CapturesOptionsView: View {
    @ObservedObject var options: CaptureOptions
    @ObservedObject var settings: IslandSettingsStore
    @ObservedObject var service: CaptureService
    @ObservedObject var shortcuts: CaptureShortcuts
    let headless: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show screenshot previews here", isOn: Binding(
                get: { settings.value.indicators.contains(.captures) },
                set: { on in settings.update { $0.setIndicator(.captures, on) } }))
            Picker("Capture controls", selection: Binding(
                get: { settings.value.capturesInIsland },
                set: { value in settings.update { $0.capturesInIsland = value } })) {
                Text("Dynamic Island").tag(true)
                Text("Separate window").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("After a screenshot", selection: $options.afterAction) {
                ForEach(CaptureAfterAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            HStack(spacing: 8) {
                Text("Save to")
                Label(options.resolvedSaveFolder.lastPathComponent, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .help(options.resolvedSaveFolder.path)
                Button("Choose…", action: chooseFolder)
            }
            Toggle("Show a preview after each screenshot", isOn: $options.showsPreview)

            Divider()
            Text("Screen recording").font(.headline)
            Toggle("Record the sound of the Mac", isOn: $options.recordsSystemAudio)
            Toggle("Record the microphone", isOn: Binding(get: { options.recordsMicrophone },
                                                          set: { options.setRecordsMicrophone($0, headless: headless) }))
            Picker("Countdown", selection: $options.countdown) {
                ForEach(CaptureRecordingRules.countdownChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                }
            }
            .fixedSize()

            Divider()
            Text("Keyboard shortcuts").font(.headline)
            shortcutRow("Screenshot", $options.screenshotShortcut, taken: shortcuts.taken.contains(.screenshot))
            shortcutRow("Screen recording", $options.recordingShortcut, taken: shortcuts.taken.contains(.recording))

            Divider()
            HStack(spacing: 8) {
                Image(systemName: service.hasAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(service.hasAccess ? Color.green : Color.orange)
                Text(service.hasAccess ? "Screen Recording is allowed." : "Screen Recording is not allowed yet.")
                Spacer()
                Button("Open System Settings") { CapturePermission.openSettings() }
                if !service.hasAccess {
                    Button("Start over") { CapturePermission.startOver() }
                        .help("Clears an old permission left by a previous version of MenuSprite, so macOS asks again.")
                }
            }
            .font(.callout)
        }
        .onAppear { service.refreshAccess() }
    }

    private func shortcutRow(_ title: String, _ binding: Binding<IslandShortcut?>, taken: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                IslandShortcutRecorder(shortcut: binding)
            }
            if taken {
                Text("Another app already uses this shortcut.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = options.resolvedSaveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { options.saveFolder = url }
    }
}
