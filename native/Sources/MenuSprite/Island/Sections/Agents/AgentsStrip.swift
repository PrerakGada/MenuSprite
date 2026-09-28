import AppKit
import IslandKit
import SwiftUI

/// What the closed island shows beside the camera while an agent works.
struct AgentStripContent: Equatable {
    enum Value: Equatable {
        /// A stopwatch counting up from the earliest working turn's start.
        case clock(Date)
        case text(String)
    }

    var value: Value
    /// The first working agent: the reading wears its tint.
    var agent: AgentKind
    /// When the reading's width can next change without new data: the clock gaining a digit, or a
    /// limit renewing.
    var nextChange: Date?

    /// Time since the earliest turn; written tokens and API value summed over working turns; the
    /// binding limit of the first working agent. API value falls back to tokens when nothing could be
    /// priced, and Limit to Time while no limit is known.
    static func make(_ snapshot: AgentActivitySnapshot, windows: [AgentLimitWindow], options: AgentOptions, now: Date) -> AgentStripContent? {
        guard let agent = snapshot.workingAgents.first(where: options.isOn), let start = snapshot.earliestStart else { return nil }
        let clock = AgentStripContent(value: .clock(start), agent: agent, nextChange: nextDigit(start: start, now: now))
        switch options.reading {
        case .time:
            return clock
        case .tokens:
            return AgentStripContent(value: .text(tokens(snapshot)), agent: agent)
        case .cost:
            guard let cost = snapshot.cost else { return AgentStripContent(value: .text(tokens(snapshot)), agent: agent) }
            return AgentStripContent(value: .text((snapshot.costIsMinimum ? "≥" : "") + AgentFormat.cost(cost)), agent: agent)
        case .limit:
            guard let window = AgentLimits.binding(windows.filter { $0.agent == agent }, now: now) else { return clock }
            return AgentStripContent(value: .text(AgentLimits.percent(window, display: options.limitDisplay, now: now)),
                                     agent: agent, nextChange: window.resetsAt.flatMap { $0 > now ? $0 : nil })
        }
    }

    /// Written tokens, marked as a minimum when part of a turn went unread.
    private static func tokens(_ snapshot: AgentActivitySnapshot) -> String {
        (snapshot.tokensAreMinimum ? "≥" : "") + AgentFormat.tokens(snapshot.outputTokens)
    }

    func text(at now: Date) -> String {
        switch value {
        case .clock(let start): AgentFormat.elapsed(now.timeIntervalSince(start))
        case .text(let text): text
        }
    }

    /// The clock gains a character at 10 minutes, an hour and ten hours.
    private static func nextDigit(start: Date, now: Date) -> Date? {
        let elapsed = now.timeIntervalSince(start)
        return [600.0, 3600, 36_000].first { $0 > elapsed }.map { start.addingTimeInterval($0) }
    }

    /// The wing this reading needs beside a camera `height` tall, with `count` working agents' marks.
    @MainActor func wing(count: Int, now: Date, height: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: AgentStrip.fontSize(height: height), weight: .medium)
        let reading = (text(at: now) as NSString).size(withAttributes: [.font: font]).width
        let readingInset = AgentStrip.textInset(height: height, fontSize: AgentStrip.fontSize(height: height))
        let marksInset = AgentStrip.edgeInset(height: height, contentHeight: AgentStrip.markSize(count: count))
        return AgentStrip.wing(readingWidth: reading.rounded(.up) + readingInset,
                               marksWidth: AgentStrip.marksWidth(count: count) + marksInset, inset: 0)
    }
}

/// The working agents' marks, breathing, at the island's left end.
struct AgentStripMarks: View {
    @ObservedObject var activity: AgentActivityService
    @ObservedObject var options: AgentsOptionsStore
    /// In a running timer's wing the marks sit toward the camera instead of at the end.
    var companion = false

    var body: some View {
        let agents = activity.snapshot.workingAgents.filter(options.value.isOn)
        let size = AgentStrip.markSize(count: agents.count)
        GeometryReader { proxy in
            let height = proxy.size.height
            let inset = AgentStrip.edgeInset(height: height, contentHeight: size)
            HStack(spacing: 1) {
                ForEach(agents) { agent in
                    AgentMark(agent: agent, size: size, animated: true)
                        .frame(width: 1.45 * size + 1, height: size)
                }
            }
            .padding(.leading, companion ? 0 : inset)
            .frame(width: proxy.size.width, height: height, alignment: companion ? .center : .leading)
            .opacity(proxy.size.width >= AgentStrip.marksMinimum || companion ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// The reading at the island's right end, in the first working agent's tint.
struct AgentStripReading: View {
    @ObservedObject var activity: AgentActivityService
    @ObservedObject var limits: AgentLimitsModel
    @ObservedObject var options: AgentsOptionsStore

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fontSize = AgentStrip.fontSize(height: height)
            if proxy.size.width >= AgentStrip.readingMinimum,
               let content = AgentStripContent.make(activity.snapshot, windows: limits.windows, options: options.value, now: limits.now) {
                reading(content)
                    .font(.system(size: fontSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(content.agent.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: proxy.size.width - AgentStrip.textInset(height: height, fontSize: fontSize), height: height,
                           alignment: .trailing)
            }
        }
    }

    @ViewBuilder private func reading(_ content: AgentStripContent) -> some View {
        switch content.value {
        case .clock(let start): Text(timerInterval: start...Date.distantFuture, countsDown: false)
        case .text(let text): Text(text)
        }
    }
}

/// The resting island's left wing: a ring filled by the binding limit, or the first agent's mark
/// when no limit is known.
struct AgentRestLeft: View {
    @ObservedObject var limits: AgentLimitsModel
    @ObservedObject var options: AgentsOptionsStore
    let firstSeen: AgentKind?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let window = AgentLimits.binding(limits.windows, now: limits.now) {
                    let tone = AgentLimitTone.tone(used: window.used(at: limits.now))
                    AgentRing(fraction: AgentLimits.fraction(window, display: options.value.limitDisplay, now: limits.now),
                              tint: tone.color(window.agent))
                } else if let firstSeen {
                    AgentMark(agent: firstSeen, size: 10).frame(width: 10, height: 10)
                }
            }
            .padding(.leading, AgentStrip.restInset(height: proxy.size.height))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

/// The resting island's right wing: the binding limit's percentage, or today's API value.
struct AgentRestRight: View {
    @ObservedObject var limits: AgentLimitsModel
    @ObservedObject var options: AgentsOptionsStore

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: proxy.size.width - AgentStrip.restInset(height: proxy.size.height), height: proxy.size.height,
                       alignment: .trailing)
        }
    }

    private var text: String {
        if let window = AgentLimits.binding(limits.windows, now: limits.now) {
            return AgentLimits.percent(window, display: options.value.limitDisplay, now: limits.now)
        }
        return limits.todayValue().map { AgentFormat.cost($0) } ?? ""
    }
}

/// An 11-pt ring, 2-pt line, filled clockwise from twelve o'clock.
struct AgentRing: View {
    var fraction: Double
    var tint: Color
    var body: some View {
        ZStack {
            Circle().inset(by: 1).stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle().inset(by: 1).trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}
