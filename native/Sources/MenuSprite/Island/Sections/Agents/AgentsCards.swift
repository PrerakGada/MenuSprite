import IslandKit
import SwiftUI

/// One agent's plan limits: the session window and the most used longer one, each with its renewal,
/// its figure as left or used, and a meter with a pace tick.
struct AgentLimitsCard: View {
    let agent: AgentKind
    let windows: [AgentLimitWindow]
    let status: AgentLimitStatus?
    let display: AgentLimitDisplay
    let working: Bool
    /// False while nothing asks for limits (a settings preview with the island off).
    var following = true
    let now: Date

    var body: some View {
        let rows = AgentLimits.cardRows(windows, agent: agent, now: now)
        let age = status?.readAt.map { max(0, now.timeIntervalSince($0)) }
        AgentCardFrame {
            HStack(spacing: 5) {
                AgentMark(agent: agent, size: 11).frame(width: 12, height: 12)
                Text(agent.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
        } accessory: {
            HStack(spacing: 6) {
                if let plan = status?.plan { AgentChip(text: plan, tint: agent.color) }
                if working { AgentPulse(color: agent.color).frame(width: 9, height: 9) }
            }
        } content: {
            if rows.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { AgentLimitRow(window: $0, display: display, now: now) }
                    if rows.count == 1, let age, age > 600 {
                        Text("Updated " + AgentFormat.ago(age)).font(.system(size: 9.5)).foregroundStyle(IslandStyle.tertiaryText)
                    }
                }
            }
        }
        .opacity((age ?? 0) > 1800 ? 0.6 : 1)
        .help(tooltip(age: age))
    }

    @ViewBuilder private var empty: some View {
        if let issue = status?.issue {
            if issue.hasPrefix("Not signed in") {
                AgentCardMessage(title: "Not signed in", detail: "Limits appear once \(agent.productName) is signed in on this Mac.")
            } else {
                AgentCardMessage(title: "Limits unavailable", detail: issue)
            }
        } else if following {
            AgentCardMessage(title: "Checking limits…", detail: "\(agent.title) reports them through the login on this Mac.")
        } else {
            AgentCardMessage(title: "Plan limits", detail: "Read while the island is on.")
        }
    }

    private func tooltip(age: Double?) -> String {
        var lines = ["\(agent.title) plan limits, as \(agent.title)'s usage service reports them."]
        if let age { lines.append(age < 60 ? "Updated just now" : "Updated " + AgentFormat.ago(age)) }
        if let notice = status?.notice { lines.append(notice) }
        return lines.joined(separator: "\n")
    }
}

struct AgentLimitRow: View {
    let window: AgentLimitWindow
    let display: AgentLimitDisplay
    let now: Date

    var body: some View {
        let used = window.used(at: now)
        let tone = AgentLimitTone.tone(used: used)
        let tint = tone.color(window.agent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.shortTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
                if let reset = window.resetsAt, reset > now {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 7.5, weight: .semibold))
                        Text(AgentFormat.countdown(reset.timeIntervalSince(now)))
                    }
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandStyle.tertiaryText)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(AgentLimits.percent(window, display: display, now: now))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tone == .agent ? Color.white : tint)
                    Text(display == .left ? "left" : "used").font(.system(size: 9, weight: .medium)).foregroundStyle(IslandStyle.tertiaryText)
                }
            }
            AgentLimitMeter(fraction: AgentLimits.fraction(window, display: display, now: now), tint: tint,
                            tick: AgentLimits.paceTick(window, display: display, now: now))
        }
        .help(tooltip(used: used))
    }

    private func tooltip(used: Double) -> String {
        var lines = [window.shortTitle, "\(Int(used.rounded()))% used", "\(Int((100 - used).rounded()))% left"]
        if let reset = window.resetsAt { lines.append("Renews " + reset.formatted(date: .abbreviated, time: .shortened)) }
        return lines.joined(separator: "\n")
    }
}

/// A 4-pt capsule meter with a thin white tick where the window's time has got to.
struct AgentLimitMeter: View {
    var fraction: Double
    var tint: Color
    var tick: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint.opacity(0.9)).frame(width: clamped > 0 ? max(4, width * clamped) : 0)
                if let tick {
                    Capsule().fill(Color.white.opacity(0.95)).frame(width: 1.5, height: 8).offset(x: width * tick - 0.75)
                }
            }
        }
        .frame(height: 4)
    }
}

/// What is working now: up to two turns with their clock and spend, or each agent's last activity.
struct AgentNowCard: View {
    let snapshot: AgentActivitySnapshot
    /// Agents that are on and have been seen, for the idle rows.
    let agents: [AgentKind]
    let now: Date

    var body: some View {
        let working = snapshot.working
        let tint = working.first?.agent.color ?? Color.white.opacity(0.75)
        AgentCardFrame {
            AgentCardTitle(symbol: "waveform", title: "Now", tint: tint)
        } accessory: {
            HStack(spacing: 6) {
                if working.count > 2 { AgentChip(text: "+\(working.count - 2)", tint: tint) }
                if !working.isEmpty { AgentPulse(color: tint).frame(width: 9, height: 9) }
            }
        } content: {
            VStack(alignment: .leading, spacing: working.isEmpty ? 6 : 4) {
                if working.isEmpty {
                    ForEach(agents) { idleRow($0) }
                    if agents.isEmpty { Text("Idle").font(.system(size: 11, weight: .medium)).foregroundStyle(IslandStyle.secondaryText) }
                } else {
                    ForEach(working.prefix(2)) { workingRow($0) }
                }
            }
        }
        .help(tooltip(working))
    }

    private func workingRow(_ turn: AgentLiveTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            AgentMark(agent: turn.agent, size: 9, animated: true).frame(width: 11, height: 13)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(turn.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(timerInterval: turn.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(turn.agent.color)
                        .fixedSize()
                }
                Text(subline(turn)).font(.system(size: 9)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
            }
        }
    }

    private func idleRow(_ agent: AgentKind) -> some View {
        HStack(spacing: 6) {
            AgentMark(agent: agent, size: 9).frame(width: 11, height: 11)
            Text(agent.productName).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 4)
            Text(snapshot.lastActivity[agent].map { AgentFormat.ago(now.timeIntervalSince($0)) } ?? "Idle")
                .font(.system(size: 10)).foregroundStyle(IslandStyle.tertiaryText).lineLimit(1)
        }
    }

    /// Model · "20K written" · "$4.56", each only when known.
    private func subline(_ turn: AgentLiveTurn) -> String {
        var parts: [String] = []
        if let model = turn.model.flatMap(AgentFormat.modelName) { parts.append(model) }
        if turn.tokens.output > 0 { parts.append((turn.partial ? "≥ " : "") + AgentFormat.tokens(turn.tokens.output) + " written") }
        if let cost = turn.cost, cost > 0 { parts.append((turn.unpriced || turn.partial ? "≥ " : "") + AgentFormat.cost(cost)) }
        return parts.isEmpty ? turn.agent.productName : parts.joined(separator: " · ")
    }

    private func tooltip(_ working: [AgentLiveTurn]) -> String {
        guard !working.isEmpty else { return "No agent is working." }
        let tokens = working.reduce(AgentTokens()) { $0 + $1.tokens }
        let share = tokens.total > 0 ? Int((Double(tokens.cacheRead) / Double(tokens.total) * 100).rounded()) : 0
        return "\(AgentFormat.tokens(tokens.total)) tokens this turn · \(share)% from cache"
    }
}
