import Foundation

/// The in-progress formats browsers leave in a downloads folder. A partial's final name is its own
/// name without the extension, so a transfer can be matched to the file it becomes.
public enum DownloadPartialKind: String, CaseIterable, Sendable {
    /// Chromium browsers (Chrome, Edge, Brave, Arc, Vivaldi, Opera): one growing file.
    case chromium = "crdownload"
    /// Safari: a bundle directory holding the payload under its final name.
    case safari = "download"
    /// Firefox: one growing file, beside a placeholder that already has the final name.
    case firefox = "part"

    /// Safari's partial is a directory; the others are regular files.
    public var isBundle: Bool { self == .safari }
}

/// Names of things in the watched folder.
public enum DownloadNaming {
    /// The partial format and final name of a top-level entry, or nil for an ordinary file.
    public static func partial(_ name: String) -> (kind: DownloadPartialKind, finalName: String)? {
        let ns = name as NSString
        guard let kind = DownloadPartialKind(rawValue: ns.pathExtension.lowercased()) else { return nil }
        let finalName = ns.deletingPathExtension
        guard !finalName.isEmpty else { return nil }
        return (kind, finalName)
    }

    /// Whether a path still carries a browser's in-progress extension.
    public static func isPartial(_ url: URL) -> Bool { partial(url.lastPathComponent) != nil }

    /// The file a transfer at `url` becomes: the same place without an in-progress extension.
    public static func finalURL(for url: URL) -> URL {
        guard let partial = partial(url.lastPathComponent) else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(partial.finalName)
    }

    /// For the Safari bundle at `bundle`, the one payload file inspected inside it. Nothing else in a
    /// bundle (resume data, its property list) is ever read.
    public static func payloadURL(inBundle bundle: URL) -> URL? {
        guard let partial = partial(bundle.lastPathComponent), partial.kind.isBundle else { return nil }
        return bundle.appendingPathComponent(partial.finalName)
    }

    /// Shortens a name in the middle, keeping its extension, for text that can only be cut at the end
    /// (a notice's detail). Names within the limit are returned unchanged.
    public static func middleTruncated(_ name: String, limit: Int) -> String {
        guard limit >= 5, name.count > limit else { return name }
        let keep = limit - 1
        let ext = (name as NSString).pathExtension
        let tail = ext.isEmpty ? keep / 2 : min(keep - 4, max(keep / 3, ext.count + 4))
        return String(name.prefix(keep - tail)) + "…" + String(name.suffix(tail))
    }
}
