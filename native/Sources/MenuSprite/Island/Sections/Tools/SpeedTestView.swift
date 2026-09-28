import IslandKit
import SwiftUI

/// The speed test as a hosted utility: download and upload in Mbps, latency and jitter, one button.
/// It starts only when pressed.
struct SpeedTestPanel: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 26) {
                reading("Download", symbol: "arrow.down", value: model.lastResult?.download)
                reading("Upload", symbol: "arrow.up", value: model.lastResult?.upload)
                Spacer(minLength: 0)
            }
            .opacity(model.isRunning ? 0.45 : 1)
            statusLine
            HStack(spacing: 8) {
                if model.isRunning {
                    Button("Stop", action: model.cancel).buttonStyle(SpeedTestButtonStyle())
                } else {
                    Button(action: model.start) {
                        Label(model.lastResult == nil ? "Speed test" : "Test again", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .buttonStyle(SpeedTestButtonStyle())
                    .help(Self.dataNote)
                }
            }
            Text(Self.dataNote)
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let dataNote = "Measures against Cloudflare's speed servers for about ten seconds. A fast connection can use several hundred megabytes."

    private func reading(_ title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map(SpeedTestMath.format) ?? "—")
                    .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(value == nil ? IslandStyle.tertiaryText : .white)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: value)
                if value != nil {
                    Text("Mbps").font(.system(size: 11, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .running(let phase):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(Self.progressText(phase)).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                }
                if let window = model.window {
                    ProgressView(timerInterval: window, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            }
        case .failed(let phase):
            Text("Test failed while measuring \(phase.rawValue).").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange)
        case .cancelled:
            Text("Test stopped.").font(.system(size: 11)).foregroundStyle(IslandStyle.secondaryText)
        case .idle, .finished:
            if let latency = model.lastResult?.latency {
                Text("Latency \(Self.milliseconds(latency.median)) · jitter \(Self.milliseconds(latency.jitter))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText)
            } else {
                Text("Download, upload and latency, measured when you press the button.")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
        }
    }

    private static func progressText(_ phase: SpeedTestPhase) -> String {
        switch phase {
        case .latency: "Testing latency…"
        case .download: "Testing download…"
        case .upload: "Testing upload…"
        }
    }

    private static func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }
}

private struct SpeedTestButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.13)))
            .contentShape(Capsule())
    }
}
