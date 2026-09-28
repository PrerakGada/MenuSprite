import IslandKit
import SwiftUI

/// The Notifications section's two options, kept in their own defaults keys.
@MainActor
final class NotificationPreferencesStore: ObservableObject {
    /// New messages also appear as a notice beside the camera.
    @Published var showBanners: Bool {
        didSet { defaults.set(showBanners, forKey: NotificationPreferences.showBannersKey); changed() }
    }
    /// Close the native banner once the island has shown it. Off unless the person opts in.
    @Published var closeOriginals: Bool {
        didSet { defaults.set(closeOriginals, forKey: NotificationPreferences.closeOriginalsKey); changed() }
    }
    var changed: () -> Void = {}
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showBanners = defaults.object(forKey: NotificationPreferences.showBannersKey) as? Bool ?? NotificationPreferences.showBannersDefault
        closeOriginals = defaults.object(forKey: NotificationPreferences.closeOriginalsKey) as? Bool ?? NotificationPreferences.closeOriginalsDefault
    }
}

/// Settings › Content › Notifications: the Accessibility row while it is missing, then the options.
struct NotificationsOptionsView: View {
    @ObservedObject var preferences: NotificationPreferencesStore
    @ObservedObject var store: NotificationMirrorStore
    let requestAccess: () -> Void
    let openAccessSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.trusted {
                HStack(spacing: 10) {
                    Image(systemName: "accessibility").font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility").font(.headline)
                        Text("Not allowed. " + NotificationsCopy.accessReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Allow…", action: requestAccess)
                    Button("Open Settings", action: openAccessSettings)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
            }
            option("Show new notifications in the island",
                   "Each new banner also appears beside the camera for a few seconds.",
                   isOn: $preferences.showBanners)
            option("Close the macOS banner",
                   "Closes the original about a second after the island shows it. Alerts that wait for you, such as alarms, are never closed. A long alert sound may stop early.",
                   isOn: $preferences.closeOriginals)
                .disabled(!preferences.showBanners)
            Text(NotificationsCopy.privacy).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { store.refreshTrust() }
    }

    private func option(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}
