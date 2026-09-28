import Foundation

/// An app the resolver can name: running now, or installed.
public struct NotificationAppRecord: Hashable, Sendable {
    public var name: String
    public var bundleID: String
    public var path: String?

    public init(name: String, bundleID: String, path: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.path = path
    }
}

/// Works out which app a notification came from, from the label the banner shows. Only a whole,
/// unambiguous name is accepted: a partial, technical or shared name names nothing, so the inbox
/// shows a neutral bell rather than the wrong app.
public enum NotificationSourceResolver {
    /// Unicode direction marks that can wrap a name without being visible.
    static let directionMarks: Set<Unicode.Scalar> = {
        var marks: Set<Unicode.Scalar> = ["\u{061C}", "\u{200E}", "\u{200F}"]
        for value in 0x202A...0x202E { if let scalar = Unicode.Scalar(value) { marks.insert(scalar) } }
        for value in 0x2066...0x2069 { if let scalar = Unicode.Scalar(value) { marks.insert(scalar) } }
        return marks
    }()

    /// Trimmed, with direction marks removed.
    public static func normalise(_ label: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: label.unicodeScalars.filter { !directionMarks.contains($0) })
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func comparable(_ label: String) -> String {
        normalise(label).folding(options: [.caseInsensitive], locale: nil)
    }

    /// A running app whose name matches wins when it is the only one (several processes of one app
    /// count once). Otherwise running and installed apps together must give exactly one bundle
    /// identifier; two installed apps sharing a name resolve to none. `installed` is only called
    /// when running apps do not settle it.
    public static func resolve(_ label: String, running: [NotificationAppRecord],
                               installed: () -> [NotificationAppRecord]) -> NotificationAppRecord? {
        let key = comparable(label)
        guard !key.isEmpty else { return nil }
        let live = running.filter { comparable($0.name) == key }
        if Set(live.map(\.bundleID)).count == 1 { return live.first }
        let all = live + installed().filter { comparable($0.name) == key }
        guard Set(all.map(\.bundleID)).count == 1 else { return nil }
        return all.first
    }

    /// Several image labels (an app icon beside a contact photo): the app is the one bundle
    /// identifier they resolve to. Unrecognised labels are ignored; labels naming two apps name none.
    public static func resolve(imageLabels: [String], running: [NotificationAppRecord],
                               installed: () -> [NotificationAppRecord]) -> NotificationAppRecord? {
        var cached: [NotificationAppRecord]?
        var matches: [NotificationAppRecord] = []
        for label in imageLabels {
            let match = resolve(label, running: running) {
                if cached == nil { cached = installed() }
                return cached ?? []
            }
            if let match { matches.append(match) }
        }
        guard Set(matches.map(\.bundleID)).count == 1 else { return nil }
        return matches.first
    }

    /// The source of a parsed notification. A header names the app directly (resolved only for its
    /// icon and bundle). Otherwise the formatted description's app part, and only when there is
    /// none, the image labels. A label that resolves to no app leaves the source unknown.
    public static func source(for candidate: NotificationCandidate, description: String?,
                              running: [NotificationAppRecord],
                              installed: () -> [NotificationAppRecord]) -> NotificationSource? {
        let fields = candidate.fields
        if let header = fields.header {
            let record = resolve(header, running: running, installed: installed)
            return NotificationSource(name: normalise(header), bundleID: record?.bundleID, path: record?.path)
        }
        let record: NotificationAppRecord?
        if let label = NotificationParser.appLabel(description: description, fields: fields) {
            record = resolve(label, running: running, installed: installed)
        } else {
            let labels = NotificationParser.appImageLabels(candidate.imageLabels, fields: fields)
            record = resolve(imageLabels: labels, running: running, installed: installed)
        }
        return record.map { NotificationSource(name: $0.name, bundleID: $0.bundleID, path: $0.path) }
    }
}
