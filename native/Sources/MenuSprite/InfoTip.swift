import SwiftUI

/// A small ⓘ that keeps an explanation off the page: hovering shows it as a tooltip, clicking opens it
/// in a popover that stays until the next click elsewhere.
struct InfoTip: View {
    let text: String
    @State private var open = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading).padding(14)
        }
    }
}
