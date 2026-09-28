import SwiftUI

/// "Show formatting": the pad's Markdown rendered read-only — headings, paragraphs, bullet and
/// numbered lists with depth, block quotes with depth, code blocks, rules, and inline bold, italic,
/// code and links. Uses the system's full Markdown parser, keeping what it could parse, and falls
/// back to the plain text. Built only while shown; the stored text never changes.
struct ScratchpadMarkdownView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MarkdownBlock.parse(text)) { block in
                    MarkdownBlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .scrollIndicators(.automatic)
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case listItem(depth: Int, marker: String)
        case quote(depth: Int)
        case code
        case rule
    }

    let id: Int
    let kind: Kind
    var content: AttributedString

    static func parse(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(text))]
        }
        var blocks: [MarkdownBlock] = []
        var identity: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let runIdentity = components.first?.identity ?? -1
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            if runIdentity == identity, !blocks.isEmpty {
                blocks[blocks.count - 1].content.append(piece)
            } else {
                identity = runIdentity
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind(of: components), content: piece))
            }
        }
        for index in blocks.indices where blocks[index].kind == .code {
            let trimmed = String(blocks[index].content.characters).trimmingCharacters(in: .newlines)
            blocks[index].content = AttributedString(trimmed)
        }
        return blocks.isEmpty ? [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(text))] : blocks
    }

    /// Components run from the innermost block outwards.
    private static func kind(of components: [PresentationIntent.IntentType]) -> Kind {
        var listDepth = 0
        var quoteDepth = 0
        var ordinal: Int?
        var ordered: Bool?
        for component in components {
            switch component.kind {
            case .listItem(let value): if ordinal == nil { ordinal = value }
            case .orderedList: listDepth += 1; if ordered == nil { ordered = true }
            case .unorderedList: listDepth += 1; if ordered == nil { ordered = false }
            case .blockQuote: quoteDepth += 1
            default: break
            }
        }
        switch components.first?.kind {
        case .header(let level): return .heading(level)
        case .codeBlock: return .code
        case .thematicBreak: return .rule
        default: break
        }
        if listDepth > 0 {
            return .listItem(depth: listDepth, marker: ordered == true ? "\(ordinal ?? 1)." : "•")
        }
        if quoteDepth > 0 { return .quote(depth: quoteDepth) }
        return .paragraph
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 13.5), weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 2)
        case .paragraph:
            Text(block.content).font(.system(size: 13)).foregroundStyle(.white)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 13).monospacedDigit()).foregroundStyle(IslandStyle.secondaryText)
                Text(block.content).font(.system(size: 13)).foregroundStyle(.white)
            }
            .padding(.leading, CGFloat(depth - 1) * 16)
        case .quote(let depth):
            HStack(spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 2)
                Text(block.content).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.75))
            }
            .padding(.leading, CGFloat(depth - 1) * 10)
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(block.content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        case .rule:
            Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1).padding(.vertical, 4)
        }
    }
}
