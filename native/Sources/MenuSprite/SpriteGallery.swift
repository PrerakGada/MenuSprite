import SwiftUI
import SystemMonitoring

/// Ready-made sprites, drawn live with this Mac's readings, to add as they are and then design.
/// Only what the gallery shows is sampled, and only while it is open. Spec: `docs/sprite-gallery.md`.
struct SpriteGallery: View {
    @ObservedObject var store: MonitoringStore
    /// Opens a saved sprite in the studio.
    let edit: (SpriteConfiguration) -> Void
    @AppStorage("MenuSprite.GalleryCategory") private var categoryStored = ""
    @State private var search = ""
    /// One drawn sample per template, made once per opening.
    @State private var previews: [String: SpriteConfiguration] = [:]

    private var category: SpriteTemplate.Category? { SpriteTemplate.Category(rawValue: categoryStored) }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private func matches(_ template: SpriteTemplate) -> Bool {
        guard searching else { return category.map { template.category == $0 } ?? true }
        return "\(template.name) \(template.summary) \(template.category.rawValue) \(template.readingIDs.joined(separator: " "))"
            .localizedStandardContains(search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Gallery").font(.headline)
                Text("\(SpriteTemplates.all.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Search the gallery", text: $search).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260).accessibilityIdentifier("gallery-search")
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", icon: "square.grid.2x2", selected: category == nil) { categoryStored = "" }
                    ForEach(SpriteTemplate.Category.allCases, id: \.self) { item in
                        chip(item.rawValue, icon: item.icon, selected: category == item) { categoryStored = item.rawValue }
                    }
                }.padding(.horizontal, 20)
            }
            .disabled(searching).opacity(searching ? 0.5 : 1)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if category == nil && !searching { sets }
                    let shown = SpriteTemplates.all.filter(matches)
                    if shown.isEmpty {
                        ContentUnavailableView("Nothing in the gallery matches", systemImage: "magnifyingglass",
                                               description: Text("Try a reading's name, like swap, fan or Claude. Readings has every reading to build your own."))
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(SpriteTemplate.Category.allCases.filter { item in shown.contains { $0.category == item } }, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(item.rawValue, systemImage: item.icon).font(.system(size: 13, weight: .semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(shown.filter { $0.category == item }) { tile($0) }
                            }
                        }
                    }
                }.padding(20)
            }
            Divider()
            Text("Each one is an ordinary sprite: add it, then click it in My sprites to change anything. Reset to template, in the studio, brings it back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .onAppear {
            previews = Dictionary(uniqueKeysWithValues: SpriteTemplates.all.map { ($0.id, $0.make(metric: store.knownMetric)) })
            store.setSurfaceMetrics("gallery", Set(SpriteTemplates.all.flatMap(\.readingIDs)))
        }
        .onDisappear { store.setSurfaceMetrics("gallery", []) }
        .accessibilityIdentifier("sprite-gallery")
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: Sets

    private var sets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sets", systemImage: "square.stack.3d.up").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(SpriteTemplates.sets) { set in
                    let missing = set.templateIDs.filter { store.sprites(from: $0).isEmpty }.count
                    VStack(alignment: .leading, spacing: 8) {
                        Text(set.name).font(.system(size: 13, weight: .semibold))
                        Text(set.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        FlowLayout(spacing: 5) {
                            ForEach(set.templateIDs, id: \.self) { id in
                                if let preview = previews[id] { MenuBarChip(config: preview, store: store) }
                            }
                        }
                        HStack {
                            Text(missing == 0 ? "All in your menu bar" : "\(set.templateIDs.count - missing) of \(set.templateIDs.count) in your menu bar")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(missing == set.templateIDs.count ? "Add all \(missing)" : "Add the \(missing) missing") { store.add(set) }
                                .disabled(missing == 0).accessibilityIdentifier("add-set-\(set.id)")
                        }.controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                }
            }
        }
    }

    // MARK: Templates

    /// Why this Mac cannot draw the template yet: the first reading it reports as unavailable.
    private func unavailable(_ template: SpriteTemplate) -> String? {
        for id in template.readingIDs {
            if let reading = store.readings[id], reading.number == nil, reading.text == nil, let issue = reading.issue { return issue }
        }
        return nil
    }

    private func tile(_ template: SpriteTemplate) -> some View {
        let added = store.sprites(from: template.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                if let preview = previews[template.id] { MenuBarChip(config: preview, store: store) }
                Spacer(minLength: 0)
            }
            Text(template.name).font(.system(size: 13, weight: .semibold))
            Text(template.summary).font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let issue = unavailable(template) {
                Label(issue, systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let first = added.first {
                    Label("In your menu bar", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { edit(first) }.accessibilityIdentifier("edit-template-\(template.id)")
                    Button { store.add(template) } label: { Image(systemName: "plus") }
                        .help("Add another").accessibilityLabel("Add another \(template.name)")
                } else {
                    Spacer()
                    Button("Add") { store.add(template) }.accessibilityIdentifier("add-template-\(template.id)")
                }
            }.controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(added.isEmpty ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.45)))
    }
}
