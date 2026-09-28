import Foundation

/// Owner-only files for things people type or copy: folders 0700, files 0600 (re-applied on every
/// write), atomic writes verified by reading them back. Reads say precisely why they failed, because
/// "missing" and "could not read" must never be confused: only a missing file may be replaced.
public enum IslandPrivateFile {
    public enum ReadResult: Equatable, Sendable {
        case data(Data)
        case missing
        /// The file exists but could not be read (permissions, I/O). Never overwrite it.
        case unreadable(String)
    }

    public enum WriteError: Error, Equatable {
        case folder(String)
        case write(String)
        /// The file on disk does not hold what was written.
        case verification
    }

    public static func read(_ url: URL) -> ReadResult {
        do {
            return .data(try Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // A dangling link or an unreadable parent also reports "no such file"; only trust it when
            // nothing at all sits at the path.
            return FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url) ? .unreadable(error.localizedDescription) : .missing
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Creates the folder (and its parents) owner-only, and re-applies 0700 to the folder itself.
    public static func prepareFolder(_ folder: URL) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw WriteError.folder(error.localizedDescription)
        }
    }

    /// Writes atomically, applies 0600, and reads the file back to confirm it holds `data`.
    public static func write(_ data: Data, to url: URL, verify: Bool = true) throws {
        try prepareFolder(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw WriteError.write(error.localizedDescription)
        }
        guard verify else { return }
        guard case .data(let written) = read(url), written == data else { throw WriteError.verification }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// The scratchpad's saving rules, kept apart from the disk so every failure case can be tested:
/// no save before a load succeeded, a file that could not be read blocks every save (even of an
/// empty document) until a later load succeeds, a failed reload revokes saving, an unchanged
/// document is not rewritten, and a failed write keeps the edits and raises the warning until a
/// write succeeds.
public struct ScratchpadPersistence: Sendable, Equatable {
    public enum LoadOutcome: Equatable, Sendable {
        case loaded(ScratchpadDocument)
        /// No file yet: start fresh, and saving is allowed.
        case missing
        /// The file exists but could not be read, is damaged, or is from a newer build: left untouched.
        case failed
    }

    public private(set) var canSave = false
    public private(set) var loadFailed = false
    public private(set) var saveFailed = false
    public private(set) var lastSaved: ScratchpadDocument?

    public init() {}

    /// Applies a load. Returns the document to show, or nil when the notes could not be opened.
    public mutating func loaded(_ outcome: LoadOutcome) -> ScratchpadDocument? {
        switch outcome {
        case .loaded(let document):
            canSave = true
            loadFailed = false
            lastSaved = document
            return document
        case .missing:
            canSave = true
            loadFailed = false
            lastSaved = nil
            return ScratchpadDocument()
        case .failed:
            canSave = false
            loadFailed = true
            lastSaved = nil
            return nil
        }
    }

    /// Whether `document` should be written now.
    public func shouldWrite(_ document: ScratchpadDocument) -> Bool {
        canSave && document != lastSaved
    }

    public mutating func wrote(_ document: ScratchpadDocument, success: Bool) {
        if success {
            lastSaved = document
            saveFailed = false
        } else {
            saveFailed = true
        }
    }

    /// Decodes a file's bytes; anything unreadable, damaged or newer is `.failed`.
    public static func outcome(of read: IslandPrivateFile.ReadResult) -> LoadOutcome {
        switch read {
        case .missing: return .missing
        case .unreadable: return .failed
        case .data(let data):
            guard let document = try? decoder().decode(ScratchpadDocument.self, from: data),
                  document.version <= ScratchpadDocument.version else { return .failed }
            return .loaded(document)
        }
    }

    public static func encode(_ document: ScratchpadDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(document)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
