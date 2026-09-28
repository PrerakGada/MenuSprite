import IslandKit
import SwiftUI

/// The strip's left wing: the timer's own mark in orange (timer, stopwatch, paused, finished), at the
/// island's end and clear of its curved corner. Hidden when the wing is too narrow to hold it.
struct TimerStripMark: View {
    @ObservedObject var engine: TimerEngine

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let size = TimerStripMetrics.markSize(height: height)
            if TimerStripMetrics.showsMark(wing: proxy.size.width) {
                Image(systemName: engine.stripSymbol)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: size, height: size)
                    .padding(.leading, TimerStripMetrics.edgeInset(stripHeight: height, contentHeight: size, cornerRadius: size / 2))
                    .frame(width: proxy.size.width, height: height, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The strip's right wing: the compact reading ("14m", "59s", "1h35", "12:05"), ticking once a
/// second while running and only while on screen.
struct TimerStripReading: View {
    @ObservedObject var engine: TimerEngine

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let font = TimerStripMetrics.readingFontSize(height: height)
            if TimerStripMetrics.showsReading(wing: proxy.size.width) {
                Text(engine.stripText())
                    .font(.system(size: font, weight: .medium).monospacedDigit())
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.leading, TimerStripMetrics.cameraAir)
                    .padding(.trailing, TimerStripMetrics.edgeInset(stripHeight: height,
                                                                    contentHeight: TimerStripMetrics.textBoxHeight(fontSize: font)))
                    .frame(width: proxy.size.width, height: height, alignment: .trailing)
            }
        }
        .onAppear { engine.watch() }
        .onDisappear { engine.unwatch() }
        .accessibilityElement()
        .accessibilityLabel(engine.session?.title ?? "Timer")
        .accessibilityValue(engine.stripText())
    }
}
