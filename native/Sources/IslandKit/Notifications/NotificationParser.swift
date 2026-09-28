import Foundation

/// Why something that looked like a notification was not mirrored. Logged by kind only, never
/// with its text.
public enum NotificationParseIssue: String, Error, Hashable, Sendable {
    /// Nothing labelled as the title (a body alone is not a message).
    case noTitle
    /// Two titles: stacked senders or two messages, never merged.
    case multipleTitles
    /// One title but two headers, subtitles or bodies.
    case duplicateField
    /// A field over 16 384 bytes.
    case fieldTooLong
    /// No labelled fields and not two or three plain texts.
    case unrecognisedLayout
    /// No text at all.
    case noText
}

/// A notification root found in the tree, with its text already split into fields.
public struct NotificationCandidate: Equatable, Sendable {
    public var handle: Int
    public var identifier: String?
    public var fields: NotificationFields
    /// Image descriptions inside the card (and around it, in a same-text wrapper): possible app names.
    public var imageLabels: [String]
    public var isPersistent: Bool
}

/// What one parse found, plus what it could not make sense of (for the log).
public struct NotificationParseReport: Equatable, Sendable {
    public var candidates: [NotificationCandidate] = []
    public var rejected: [NotificationParseIssue] = []
    /// Subroles that mention notifications but are not the four known ones: a sign the OS changed.
    public var unknownSubroles: Set<String> = []
    /// Text identifiers other than header, title, subtitle and body.
    public var unknownTextIdentifiers: Set<String> = []
    public init() {}
}

/// Turns a read of Notification Center's windows into notification candidates. Every doubtful case
/// is rejected: a partial or merged message must never reach the inbox or authorise an action.
public enum NotificationParser {
    enum Field: String, CaseIterable { case header, title, subtitle, body }

    /// The static texts and image labels under one node.
    struct Collected: Equatable {
        var labelled: [LabelledText] = []
        var unlabelled: [String] = []
        var unknown: Set<String> = []
        var images: [String] = []
        var tooLong = false
        var texts: [String] { labelled.map { "\($0.field.rawValue):\($0.value)" } + unlabelled }
    }

    struct LabelledText: Equatable { var field: Field; var value: String }

    public static func parse(windows: [NotificationAXNode]) -> NotificationParseReport {
        var report = NotificationParseReport()
        for window in windows { walk(window, stack: nil, into: &report) }
        return report
    }

    private enum StackKind { case banner, alert }

    private static func walk(_ node: NotificationAXNode, stack: StackKind?, into report: inout NotificationParseReport) {
        guard !node.isEditable else { return }
        switch node.subrole {
        case NotificationAX.bannerSubrole?, NotificationAX.alertSubrole?:
            let persistent = node.subrole == NotificationAX.alertSubrole || stack == .alert
            let collected = collect(node)
            report.unknownTextIdentifiers.formUnion(collected.unknown)
            switch fields(from: collected) {
            case .success(let fields):
                report.candidates.append(NotificationCandidate(handle: node.handle, identifier: node.identifier, fields: fields,
                                                               imageLabels: unique(collected.images), isPersistent: persistent))
            case .failure(let issue):
                report.rejected.append(issue)
            }
        case NotificationAX.bannerStackSubrole?, NotificationAX.alertStackSubrole?:
            let kind: StackKind = (node.subrole == NotificationAX.alertStackSubrole || stack == .alert) ? .alert : .banner
            for child in node.children { _ = walkStack(child, kind: kind, around: [], into: &report) }
        default:
            if let subrole = node.subrole, subrole.localizedCaseInsensitiveContains("notification") {
                report.unknownSubroles.insert(subrole)
            }
            for child in node.children { walk(child, stack: stack, into: &report) }
        }
    }

    /// Inside a stack a card is the innermost node whose text is one complete message. A wrapper
    /// holding exactly the same complete message hands over to that child (keeping its own image
    /// labels, where the app icon may sit); a node with two titles is split into its children; any
    /// other incomplete node is rejected rather than cut into partial pieces. Returns how many
    /// candidates it added.
    private static func walkStack(_ node: NotificationAXNode, kind: StackKind, around images: [String],
                                  into report: inout NotificationParseReport) -> Int {
        guard !node.isEditable else { return 0 }
        if let subrole = node.subrole, [NotificationAX.bannerSubrole, NotificationAX.alertSubrole,
                                        NotificationAX.bannerStackSubrole, NotificationAX.alertStackSubrole].contains(subrole) {
            let before = report.candidates.count
            walk(node, stack: kind, into: &report)
            return report.candidates.count - before
        }
        // A bare text is never a card on its own: it would split a message from its sender.
        guard node.role != NotificationAX.staticTextRole else { return 0 }
        let collected = collect(node)
        report.unknownTextIdentifiers.formUnion(collected.unknown)
        switch fields(from: collected) {
        case .success(let fields):
            let same = node.children.filter { child in
                guard !child.isEditable, child.role != NotificationAX.staticTextRole else { return false }
                let inner = collect(child)
                return inner.texts == collected.texts && (try? self.fields(from: inner).get()) == fields
            }
            if same.count == 1 {
                return walkStack(same[0], kind: kind, around: images + collected.images, into: &report)
            }
            report.candidates.append(NotificationCandidate(handle: node.handle, identifier: node.identifier, fields: fields,
                                                           imageLabels: unique(images + collected.images),
                                                           isPersistent: kind == .alert))
            return 1
        case .failure(.multipleTitles):
            var found = 0
            for child in node.children { found += walkStack(child, kind: kind, around: [], into: &report) }
            if found == 0 { report.rejected.append(.multipleTitles) }
            return found
        case .failure(.noText):
            return 0
        case .failure(let issue):
            report.rejected.append(issue)
            return 0
        }
    }

    /// Texts and image labels under a node. Editable fields are skipped whole (their contents are
    /// never read), and text inside buttons is their label, not the message.
    static func collect(_ node: NotificationAXNode) -> Collected {
        var result = Collected()
        func visit(_ node: NotificationAXNode, inControl: Bool) {
            guard !node.isEditable else { return }
            if node.role == NotificationAX.staticTextRole, !inControl, let raw = node.text {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    if value.utf8.count > NotificationAX.maxFieldBytes { result.tooLong = true }
                    let identifier = node.identifier?.trimmingCharacters(in: .whitespaces) ?? ""
                    if identifier.isEmpty {
                        result.unlabelled.append(value)
                    } else if let field = Field(rawValue: identifier.lowercased()) {
                        result.labelled.append(LabelledText(field: field, value: value))
                    } else {
                        result.unknown.insert(identifier)
                    }
                }
            }
            if node.role == NotificationAX.imageRole, let label = node.imageLabel {
                let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value.utf8.count <= NotificationAX.maxLabelBytes { result.images.append(value) }
            }
            for child in node.children { visit(child, inControl: inControl || node.isControl) }
        }
        visit(node, inControl: false)
        return result
    }

    /// Exactly one title and at most one of each other field; legacy banners with two or three
    /// unlabelled texts read as title, (subtitle), body.
    static func fields(from collected: Collected) -> Result<NotificationFields, NotificationParseIssue> {
        if collected.tooLong { return .failure(.fieldTooLong) }
        if !collected.labelled.isEmpty {
            var values: [Field: [String]] = [:]
            for text in collected.labelled { values[text.field, default: []].append(text.value) }
            let titles = values[.title] ?? []
            if titles.count > 1 { return .failure(.multipleTitles) }
            guard let title = titles.first else { return .failure(.noTitle) }
            if [Field.header, .subtitle, .body].contains(where: { (values[$0]?.count ?? 0) > 1 }) { return .failure(.duplicateField) }
            return .success(NotificationFields(header: values[.header]?.first, title: title,
                                               subtitle: values[.subtitle]?.first, body: values[.body]?.first))
        }
        switch collected.unlabelled.count {
        case 0: return .failure(collected.unknown.isEmpty ? .noText : .unrecognisedLayout)
        case 2: return .success(NotificationFields(title: collected.unlabelled[0], body: collected.unlabelled[1]))
        case 3: return .success(NotificationFields(title: collected.unlabelled[0], subtitle: collected.unlabelled[1],
                                                   body: collected.unlabelled[2]))
        default: return .failure(.unrecognisedLayout)
        }
    }

    /// Fields for a single root, as the reader re-reads it before acting.
    public static func fields(of root: NotificationAXNode) -> Result<NotificationFields, NotificationParseIssue> {
        fields(from: collect(root))
    }

    /// A root's identifier counts as a durable native identity only when it carries a UUID-shaped
    /// part; structural markers do not.
    public static func nativeIdentity(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty, identifier.utf8.count <= NotificationAX.maxIdentifierBytes,
              containsUUID(identifier) else { return nil }
        return identifier
    }

    /// True when the text contains 8-4-4-4-12 hexadecimal digits separated by hyphens.
    static func containsUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let hyphen = UInt8(ascii: "-")
        let pattern = "00000000-0000-0000-0000-000000000000".utf8.map { $0 == hyphen }
        guard bytes.count >= pattern.count else { return false }
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        return (0...(bytes.count - pattern.count)).contains { start in
            pattern.indices.allSatisfy { index in
                pattern[index] ? bytes[start + index] == hyphen : isHex(bytes[start + index])
            }
        }
    }

    /// The app's label from the root's formatted description, "<app>, <title>, <subtitle>, <body>":
    /// the exact field suffix is removed and the rest is the app. Never split on commas, which can be
    /// part of any field. A description without that suffix, or with nothing before it, names nothing.
    public static func appLabel(description: String?, fields: NotificationFields) -> String? {
        guard let description, description.utf8.count <= NotificationAX.maxDescriptionBytes else { return nil }
        let parts = [fields.title, fields.subtitle, fields.body].compactMap { $0 }
        let suffix = ", " + parts.joined(separator: ", ")
        guard description.hasSuffix(suffix) else { return nil }
        let label = String(description.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= NotificationAX.maxLabelBytes else { return nil }
        return label
    }

    /// Image labels that could name the app: not the sender, conversation or message themselves.
    public static func appImageLabels(_ labels: [String], fields: NotificationFields) -> [String] {
        let taken = Set([fields.title, fields.subtitle, fields.body].compactMap { $0?.lowercased() })
        return unique(labels.filter { !taken.contains($0.lowercased()) })
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
