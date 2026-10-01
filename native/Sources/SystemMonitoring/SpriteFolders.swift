import Foundation

/// Where a sprite's own files live: `~/Library/Application Support/MenuSprite/Sprites/<sprite id>/`.
/// Commands of a sprite that has files run there with `SPRITE_DIR` set. Spec: `docs/agent-authoring.md`.
///
/// The folder holds two kinds of file: the ones its spec carries (`files`), and whatever its scripts write
/// there (a cache, a log, a chart.png). A manifest dotfile lists the first kind, so reading a spec back
/// carries exactly the files a spec wrote, and a later apply replaces or removes only those: a script's
/// own state survives every apply, and a binary file `get` could never carry is never deleted for being
/// missing from the spec.
public enum SpriteFolders {
    /// Set once at launch by the headless sandbox, so its sprites' files never touch the real folder.
    nonisolated(unsafe) public static var rootOverride: URL?
    public static var root: URL {
        rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite", isDirectory: true)
            .appendingPathComponent("Sprites", isDirectory: true)
    }
    public static func directory(for id: UUID, root: URL = SpriteFolders.root) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static let maximumFiles = 20
    public static let maximumFileBytes = 256 * 1024
    /// The names the last applied spec wrote, as a JSON list. A dotfile, so no spec can name it and no
    /// cleanup removes it.
    public static let manifestName = ".menusprite-files.json"
    /// How many entries a folder written before manifests existed is looked through for spec files.
    static let legacyScanLimit = 200

    /// A sprite's spec files, as `get` carries them, and the ones it could not carry.
    public struct Contents: Sendable, Equatable {
        public var files: [String: String]
        /// "name: why", for each file the spec should carry but cannot (missing, too large, not text). A file
        /// left out for its size or content stays in the folder through every apply.
        public var skipped: [String]
        public init(files: [String: String] = [:], skipped: [String] = []) { self.files = files; self.skipped = skipped }
    }

    /// The files a spec wrote into `directory`: the names in its manifest or, for a folder from before
    /// manifests, every top-level regular file a spec could have written (a valid name, text, small enough).
    /// Reads at most `maximumFiles` files of at most `maximumFileBytes` each, in name order, so a script that
    /// fills its folder can never make a read large or slow.
    public static func contents(in directory: URL) -> Contents {
        var result = Contents()
        let listed = manifest(in: directory)
        let names = listed ?? Array(entries(in: directory).prefix(legacyScanLimit))
        for (index, name) in names.sorted().enumerated() {
            guard result.files.count < maximumFiles else {
                result.skipped.append("\(names.count - index) more files are past the \(maximumFiles) a spec carries"); break
            }
            switch read(name, in: directory) {
            case .success(let text): result.files[name] = text
            // A folder from before manifests also holds the scripts' own output; that is not the spec's to carry.
            case .failure(let reason): if listed != nil || reason.reportedWithoutManifest { result.skipped.append("\(name): \(reason.text)") }
            }
        }
        return result
    }

    /// The spec files in `directory`, by name. See `contents(in:)`.
    public static func files(in directory: URL) -> [String: String] { contents(in: directory).files }

    /// Whether `directory` holds spec files, without reading any of them: the compiler only needs to know
    /// whether a sprite's commands run in its folder.
    public static func hasFiles(in directory: URL) -> Bool {
        if let listed = manifest(in: directory) { return !listed.isEmpty }
        return entries(in: directory).prefix(legacyScanLimit).contains { name in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
                && (attributes[.size] as? NSNumber)?.intValue ?? .max <= maximumFileBytes
        }
    }

    /// The names the last applied spec wrote, or nil when the folder has no manifest (or no folder).
    public static func manifest(in directory: URL) -> [String]? {
        let url = directory.appendingPathComponent(manifestName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 64 * 1024,
              let data = FileManager.default.contents(atPath: url.path),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return names.filter(isValidName)
    }

    public static func writeManifest(_ names: [String], in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: names.sorted(), options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent(manifestName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Top-level names a spec could use, in name order: no dotfiles, valid characters.
    public static func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter(isValidName).sorted()
    }

    /// A file name a spec may use: letters, digits, `.`, `_` and `-`, not starting with a dot, ≤ 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    private struct Unreadable: Error {
        var text: String
        /// Worth reporting even in a folder from before manifests: a file a spec could have written that
        /// has since grown too large. A binary file there is a script's output, not a lost spec file.
        var reportedWithoutManifest = false
    }

    private static func read(_ name: String, in directory: URL) -> Result<String, Unreadable> {
        let path = directory.appendingPathComponent(name).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .failure(Unreadable(text: "the spec wrote it, but it is no longer in the folder"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(Unreadable(text: "not a regular file, so the spec does not carry it; applying leaves it alone"))
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? .max
        guard size <= maximumFileBytes else {
            let shown = size >= 1 << 20 ? "\(size >> 20) MiB" : "\(size >> 10) KiB"
            return .failure(Unreadable(text: "\(shown), over the \(maximumFileBytes >> 10) KiB a spec carries, so the spec does not carry it; applying leaves it alone",
                                       reportedWithoutManifest: true))
        }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            return .failure(Unreadable(text: "not UTF-8 text, so the spec does not carry it; applying leaves it alone"))
        }
        return .success(text)
    }
}
