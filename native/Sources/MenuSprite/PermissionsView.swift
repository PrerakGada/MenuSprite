import SwiftUI
import PermissionModel

private enum Theme {
    static let violet = Color(nsColor: NSColor(name: "MenuSpriteAccent") { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor(red: 0.722, green: 0.631, blue: 0.953, alpha: 1)
        } else {
            NSColor(red: 0.463, green: 0.322, blue: 0.906, alpha: 1)
        }
    })
}

struct PermissionsView: View {
    @ObservedObject var store: PermissionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search permissions", text: $store.search)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("permission-search")
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator.opacity(0.5)))
                .frame(maxWidth: 300)
                Picker("Show", selection: $store.filter) {
                    ForEach(PermissionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 345)
                Spacer(minLength: 0)
                Text("\(store.visiblePermissions.count) of \(PermissionCatalog.all.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 26).padding(.vertical, 13)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.visiblePermissions.isEmpty {
                        ContentUnavailableView("No matching permissions", systemImage: "magnifyingglass",
                            description: Text("Try another search or choose All to see every category."))
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(PermissionCatalog.groups, id: \.self) { group in
                        let rows = store.visiblePermissions.filter { $0.group == group }
                        if !rows.isEmpty {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group).font(.headline)
                                if rows.first?.isOtherAccess == true {
                                    Text("Registrations and app-owned resources")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 19).padding(.bottom, 9)
                            VStack(spacing: 0) {
                                ForEach(rows) { permission in
                                    PermissionRow(permission: permission, store: store)
                                    if permission.id != rows.last?.id { Divider().padding(.leading, 52) }
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.35)))
                        }
                    }
                }
                .padding(.horizontal, 26).padding(.bottom, 24)
            }
            .accessibilityIdentifier("permissions-list")
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.violet)
        .frame(minWidth: 870, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            if let image = NSImage(named: "BrandIcon") {
                Image(nsImage: image).resizable().frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Permissions & Access").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("MenuSprite’s access to your Mac, in one place.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Read-only monitoring is configured in Monitoring & Sprites. Grants don’t enable features.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button { store.refresh() } label: {
                Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("refresh-permissions")
        }
        .padding(.horizontal, 26).padding(.top, 19).padding(.bottom, 20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = store.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.violet)
                    Text(notice).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss message").accessibilityLabel("Dismiss message")
                }
                Divider()
            }
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("macOS controls permission grants and revocations.")
                Spacer()
                if let checked = store.lastRefresh {
                    Text("Checked \(checked.formatted(date: .omitted, time: .standard))").monospacedDigit()
                } else { Text("Checking app access…") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 26).padding(.vertical, 12)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @ObservedObject var store: PermissionStore
    private var observation: Observation { store.observation(for: permission.id) }
    private var isExpanded: Bool { store.expanded.contains(permission.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 13) {
                Button {
                    if isExpanded { store.expanded.remove(permission.id) }
                    else { store.expanded.insert(permission.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).frame(width: 8).foregroundStyle(.secondary)
                        Image(systemName: permission.icon)
                            .font(.system(size: 17, weight: .medium)).frame(width: 23).foregroundStyle(Theme.violet)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(permission.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Used by: \(permission.usedBy)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(permission.name), \(isExpanded ? "hide" : "show") details")
                .accessibilityIdentifier("details-\(permission.id.rawValue)")

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: statusIcon).font(.system(size: 10, weight: .semibold))
                        Text(observation.state.label).font(.system(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    if observation.stale { Text("Stale · refresh to retry").font(.caption2).foregroundStyle(.orange) }
                }.frame(width: 190, alignment: .leading)
                    .accessibilityIdentifier("status-\(permission.id.rawValue)")

                actions.frame(width: 174, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text(permission.explanation).font(.callout).textSelection(.enabled)
                    Text(observation.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if !observation.resources.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(observation.resources, id: \.name) { resource in
                                GridRow {
                                    Text(resource.name).foregroundStyle(.secondary)
                                    Text(resource.value).textSelection(.enabled)
                                }
                            }
                        }.font(.callout)
                    }
                    if let destination = permission.settings {
                        Text(permission.id == .notifications ? "System Settings → Notifications → MenuSprite" : destination.path)
                            .font(.callout).foregroundStyle(.secondary)
                        Text("If the section link opens the overview, follow this path. An unused app may not be listed yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Applies to: MenuSprite (\(Bundle.main.bundleIdentifier ?? "unknown identity"))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Checked \(observation.checkedAt.formatted(date: .abbreviated, time: .standard)) · \(observation.method)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.leading, 55).padding(.trailing, 18).padding(.bottom, 15)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if permission.id == .login {
                if [.enabled, .requiresApproval, .notRegistered, .notFound].contains(observation.state) {
                    Button([.notRegistered, .notFound].contains(observation.state) ? "Enable at login" : "Disable at login") { store.changeLoginRegistration() }
                        .disabled(store.requestInFlight != nil)
                        .accessibilityIdentifier("change-login")
                }
                Button("Manage in System Settings") { store.manage(permission) }
                    .controlSize(.small).accessibilityIdentifier("manage-login")
            } else {
                if permission.canRequest(observation.state) {
                    Button(store.requestInFlight == permission.id ? "Requesting…" : "Request Access…") { store.request(permission) }
                        .disabled(store.requestInFlight != nil)
                        .accessibilityIdentifier("request-\(permission.id.rawValue)")
                }
                if permission.settings != nil {
                    Button("Manage in System Settings") { store.manage(permission) }
                        .controlSize(.small).accessibilityIdentifier("manage-\(permission.id.rawValue)")
                } else {
                    Text(permission.isOtherAccess ? "No configured access" : "No supported request")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        switch observation.state {
        case .granted, .pasteboardAllow, .enabled: .green
        case .limited, .writeOnly, .restricted, .requiresApproval: .orange
        case .notGranted, .pasteboardDeny: .secondary
        default: .secondary
        }
    }
    private var statusIcon: String {
        switch observation.state {
        case .granted, .pasteboardAllow, .enabled: "checkmark.circle.fill"
        case .restricted: "lock.fill"
        case .unknown: "questionmark.circle"
        case .limited, .writeOnly, .requiresApproval: "circle.lefthalf.filled"
        case .unavailable, .unavailableInBuild: "minus.circle"
        default: "circle"
        }
    }
}
