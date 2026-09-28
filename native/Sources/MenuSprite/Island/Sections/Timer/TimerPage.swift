import AppKit
import IslandKit
import SwiftUI

/// The Timer page: the setup view when nothing runs, the running session's row otherwise.
struct TimerPage: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var preferences: TimerPreferences
    let context: IslandPageContext

    var body: some View {
        Group {
            if let session = engine.session {
                TimerActiveView(engine: engine, session: session)
            } else {
                TimerSetupView(engine: engine, preferences: preferences, context: context)
            }
        }
        .frame(width: context.width, alignment: .top)
        .allowsHitTesting(!context.isPreview)
    }
}

/// The big orange clock's look, shared by the setup preview and the running page.
private enum TimerClockStyle {
    static let preview = Font.system(size: 26, weight: .thin).monospacedDigit()
    static let running = Font.system(size: 62, weight: .thin).monospacedDigit()
    /// Wide enough for "0:00:00", so the ruler never changes width as the preview grows an hour.
    static let previewWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .thin)
        return ceil(("0:00:00" as NSString).size(withAttributes: [.font: font]).width) + 2
    }()
}

// MARK: Setup

private struct TimerSetupView: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var preferences: TimerPreferences
    let context: IslandPageContext

    var body: some View {
        let mode = preferences.value.mode
        let wide = TimerPageLayout.isWide(context.width)
        let layout = TimerPageLayout.setup(mode: mode, width: context.width, budget: context.budget)
        VStack(alignment: .leading, spacing: TimerPageLayout.gap) {
            HStack(spacing: 12) {
                TimerModePicker(selection: mode) { engine.setMode($0) }
                Spacer(minLength: 0)
                if wide { startButton(mode) }
            }
            .frame(height: TimerPageLayout.modeRow)
            rulerRow(mode: mode, wide: wide)
                .frame(height: layout.ruler)
            if mode == .pomodoro && wide {
                TimerPomodoroReadouts(engine: engine, plan: preferences.value.plan)
                    .frame(height: TimerPageLayout.readouts)
            }
            if !wide {
                HStack(spacing: 12) {
                    if mode != .stopwatch { previewClock(mode).fixedSize() }
                    if mode == .pomodoro { TimerPomodoroReadouts(engine: engine, plan: preferences.value.plan) }
                    Spacer(minLength: 0)
                    startButton(mode)
                }
                .frame(height: TimerPageLayout.bottomRow)
            }
        }
        .frame(width: context.width, height: layout.height, alignment: .top)
    }

    @ViewBuilder private func rulerRow(mode: TimerMode, wide: Bool) -> some View {
        HStack(spacing: 14) {
            if mode == .stopwatch {
                Spacer(minLength: 0)
                clock("00:00").frame(width: TimerClockStyle.previewWidth, alignment: .trailing)
            } else {
                TimerRulerView(minutes: rulerBinding(mode), accessibilityLabel: mode == .pomodoro ? "Focus length" : "Minutes",
                               onStep: { engine.minuteTick() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide { previewClock(mode).frame(width: TimerClockStyle.previewWidth, alignment: .trailing) }
            }
        }
    }

    private func rulerBinding(_ mode: TimerMode) -> Binding<Int> {
        if mode == .pomodoro {
            return Binding(get: { preferences.value.plan.focusMinutes },
                           set: { minutes in engine.setPlan { $0.focusMinutes = minutes } })
        }
        return Binding(get: { engine.countdownMinutes }, set: { engine.countdownMinutes = $0 })
    }

    private func previewClock(_ mode: TimerMode) -> some View {
        let minutes = mode == .pomodoro ? preferences.value.plan.focusMinutes : engine.countdownMinutes
        return clock(TimerFormat.clock(countdown: TimerSession.countdownLength(minutes: minutes)))
    }

    private func clock(_ text: String) -> some View {
        Text(text)
            .font(TimerClockStyle.preview)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func startButton(_ mode: TimerMode) -> some View {
        Button { engine.start() } label: {
            Text("Start")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode == .pomodoro ? "Each phase begins when you press it. The cycle ends with its last focus session." : "")
    }
}

/// The three modes as plain words, with an orange underline that slides to the chosen one.
private struct TimerModePicker: View {
    let selection: TimerMode
    let choose: (TimerMode) -> Void
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            ForEach(TimerMode.allCases) { mode in
                Button { choose(mode) } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == selection ? Color.white : Color.white.opacity(0.5))
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            if mode == selection {
                                Capsule().fill(Color.orange).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == selection ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

/// Short break, long break, how often the long one comes and how many sessions: each opens a menu
/// of every allowed value. They spread across the row, or scroll sideways when they do not fit.
private struct TimerPomodoroReadouts: View {
    @ObservedObject var engine: TimerEngine
    let plan: PomodoroPlan

    private struct Readout: Identifiable {
        let id: String
        let value: Int
        let choices: [Int]
        let isMinutes: Bool
        let path: WritableKeyPath<PomodoroPlan, Int>
    }

    private var readouts: [Readout] {
        [Readout(id: "Short break", value: plan.shortBreakMinutes, choices: PomodoroPlan.breakChoices, isMinutes: true, path: \.shortBreakMinutes),
         Readout(id: "Long break", value: plan.longBreakMinutes, choices: PomodoroPlan.breakChoices, isMinutes: true, path: \.longBreakMinutes),
         Readout(id: "Long break every", value: plan.sessionsBeforeLongBreak, choices: PomodoroPlan.sessionChoices, isMinutes: false, path: \.sessionsBeforeLongBreak),
         Readout(id: "Sessions", value: plan.totalSessions, choices: PomodoroPlan.sessionChoices, isMinutes: false, path: \.totalSessions)]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(readouts.enumerated()), id: \.element.id) { index, readout in
                    if index > 0 { Spacer(minLength: 12) }
                    item(readout)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) { ForEach(readouts) { item($0) } }
                    .padding(.trailing, 16)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
    }

    private func text(_ readout: Readout, _ value: Int) -> String {
        readout.isMinutes ? TimerFormat.minutes(value) : "\(value)"
    }

    private func item(_ readout: Readout) -> some View {
        Button {
            TimerChoiceMenu.show(choices: readout.choices, current: readout.value, title: { text(readout, $0) },
                                 holdOpen: engine.holdOpen) { value in
                engine.setPlan { $0[keyPath: readout.path] = value }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(readout.id)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(IslandStyle.tertiaryText)
                HStack(spacing: 3) {
                    Text(text(readout, readout.value))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.orange.opacity(0.8))
                }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(readout.id)
        .accessibilityValue(text(readout, readout.value))
    }
}

// MARK: Active

/// The running (or paused, or finished) session: two round buttons, the phase title and a big clock.
private struct TimerActiveView: View {
    @ObservedObject var engine: TimerEngine
    let session: TimerSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    if let primary { primary }
                    TimerRoundButton(symbol: "xmark", label: session.isFinished ? "Done" : "Cancel",
                                     tint: .white, fill: Color.white.opacity(0.18)) { engine.dismiss() }
                }
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        title(size: 17)
                        clock
                    }
                    .fixedSize()
                    VStack(alignment: .trailing, spacing: -6) {
                        title(size: 13)
                        clock.minimumScaleFactor(0.6)
                    }
                }
            }
            .frame(height: TimerPageLayout.active)
            if let plan = session.plan {
                Text("Session \(session.sessionNumber) of \(plan.totalSessions)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .frame(height: TimerPageLayout.activeSessionLine, alignment: .top)
            }
        }
    }

    private var primary: TimerRoundButton? {
        let orange = Color.orange.opacity(0.28)
        if session.isRunning {
            return TimerRoundButton(symbol: "pause.fill", label: "Pause", tint: .orange, fill: orange) { engine.pause() }
        }
        if session.isPaused {
            return TimerRoundButton(symbol: "play.fill", label: "Resume", tint: .orange, fill: orange) { engine.resume() }
        }
        if let next = session.nextPhase {
            return TimerRoundButton(symbol: "play.fill", label: "Start \(next.title)", tint: .orange, fill: orange) { engine.startNextPhase() }
        }
        return nil
    }

    private func title(size: CGFloat) -> some View {
        Text(session.title)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var clock: some View {
        Text(engine.clockText())
            .font(TimerClockStyle.running)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .accessibilityLabel(session.phase.title)
            .accessibilityValue(session.phase.countsDown ? TimerFormat.duration(engine.reading()) : engine.clockText())
    }
}

/// A 52-pt round button with a symbol, as on the running page.
private struct TimerRoundButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A native menu of values with a check on the current one, popped up at the pointer. The island is
/// held open while it is up.
@MainActor
enum TimerChoiceMenu {
    static func show(choices: [Int], current: Int, title: (Int) -> String, holdOpen: (Bool) -> Void,
                     choose: @escaping (Int) -> Void) {
        let target = Target(choose)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for value in choices {
            let item = NSMenuItem(title: title(value), action: #selector(Target.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = value
            item.state = value == current ? .on : .off
            menu.addItem(item)
        }
        holdOpen(true)
        menu.popUp(positioning: menu.items.first { $0.tag == current }, at: NSEvent.mouseLocation, in: nil)
        holdOpen(false)
        withExtendedLifetime(target) {}
    }

    @MainActor
    private final class Target: NSObject {
        let choose: (Int) -> Void
        init(_ choose: @escaping (Int) -> Void) { self.choose = choose }
        @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
    }
}
