import SwiftUI

/// Settings › Content › Downloads: the switch and folder (the same controls the page shows until it is
/// set up), then what the closed island shows while and after a download arrives. A folder chosen here
/// never opens or focuses the island.
struct DownloadsOptions: View {
    let section: DownloadsSection
    @ObservedObject var model: DownloadsModel
    @ObservedObject var preferences: DownloadsPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DownloadsSetupView(section: section, setup: section.setup, style: .settings) {
                section.chooseFolder(from: .settings)
            }
            if let path = preferences.folderPath, section.setup != .unavailable {
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Divider()
            Toggle("Show progress beside the camera", isOn: $preferences.showsActivity)
            Text("While a file downloads, the closed island shows its name and percentage.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Download complete notice", isOn: $preferences.showsNotice)
            Text("Only a download that finished in this folder is announced; files you move in are listed quietly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
