import IslandKit
import SwiftUI

/// The settings window's page: a warning when another island is on, the title with the master switch,
/// the tab row with the open button, and the chosen tab below. Content fills the page height; the
/// other tabs scroll.
struct IslandSettingsView: View {
    @ObservedObject var model: IslandSettingsModel
    @ObservedObject var settings: IslandSettingsStore
    let environment: IslandEnvironment
    let presentation: IslandPresentation
    let open: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let page = max(0, proxy.size.width - 2 * IslandSettingsStyle.margin)
            VStack(alignment: .leading, spacing: 0) {
                header(page)
                    .padding(.horizontal, IslandSettingsStyle.margin)
                    .padding(.top, 22)
                IslandTabRow(tab: $model.tab, width: page, canOpen: settings.value.enabled, open: open)
                    .padding(.horizontal, IslandSettingsStyle.margin)
                    .padding(.vertical, 18)
                tab(page)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func header(_ width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.otherIslandOn {
                Label("Vorssaint's Dynamic Island is also on. Turn one off so they don't overlap.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dynamic Island").font(.system(size: 22, weight: .bold))
                    Text("Music, controls and everyday tools in one place at the top of your screen. Optional: turn it off and MenuSprite's own panels work as before.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Dynamic Island", isOn: settings.binding(\.enabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
            }
            IslandMenuRoomHint(presentation: presentation, settings: settings, model: model) { environment.showPermissions() }
        }
    }

    @ViewBuilder private func tab(_ width: CGFloat) -> some View {
        switch model.tab {
        case .content:
            IslandContentTab(model: model, environment: environment, settings: settings, width: width)
                .padding(.horizontal, IslandSettingsStyle.margin)
                .padding(.bottom, 22)
        case .layout:
            scrolling { IslandLayoutTab(model: model, environment: environment, settings: settings, width: width) }
        case .activity:
            scrolling { IslandActivityTab(model: model, environment: environment, settings: settings, width: width) }
        case .behavior:
            scrolling { IslandBehaviorTab(environment: environment, settings: settings, width: width) }
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical) {
            content()
                .padding(.horizontal, IslandSettingsStyle.margin)
                .padding(.bottom, 28)
        }
    }
}

/// Layout / Content / Activity / Behavior as segments (a pop-up menu when they would not fit), and the
/// button that opens the island.
struct IslandTabRow: View {
    @Binding var tab: IslandSettingsTab
    let width: CGFloat
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        let widths = IslandSettingsTab.allCases.map { IslandSettingsStyle.textWidth($0.title) }
        HStack(spacing: IslandTabRowFit.spacing) {
            if IslandTabRowFit.style(available: width, titleWidths: widths) == .segmented {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
            Button(action: open) {
                Image(systemName: "arrow.up.forward.app").frame(width: 22)
            }
            .disabled(!canOpen)
            .help("Open Dynamic Island")
            .accessibilityLabel("Open Dynamic Island")
            Spacer(minLength: 0)
        }
        .controlSize(.large)
    }

    private var picker: some View {
        Picker("Settings section", selection: $tab) {
            ForEach(IslandSettingsTab.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Under the title when the island would have to measure the menus on a display without a notch and
/// cannot, because Accessibility is off.
private struct IslandMenuRoomHint: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var settings: IslandSettingsStore
    @ObservedObject var model: IslandSettingsModel
    let openPermissions: () -> Void

    var body: some View {
        let notched = presentation.display?.cutout.isPhysical
        if IslandSettingsHints.menuRoomNeedsAccessibility(settings.value, displayIsNotched: notched, trusted: model.accessibilityTrusted) {
            IslandAccessibilityHint(message: "Allow Accessibility so the island can find free room beside the menus on this display instead of hiding.",
                                    openPermissions: openPermissions)
        }
    }
}
