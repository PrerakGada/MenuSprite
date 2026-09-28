import AppKit
import SwiftUI

/// The floating tools' surface: frosted dark material with an optional opaque black fill over it
/// (0 translucent … 1 opaque), rounded like the island's cards.
struct FrostedBackground: View {
    var opacity: Double
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            FrostedMaterial()
            Color.black.opacity(0.35 + 0.65 * opacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct FrostedMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
