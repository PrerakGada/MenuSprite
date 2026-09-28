import Combine
import IslandKit
import SwiftUI

/// Today's events and the month, read from EventKit, plus the optional countdown in the closed
/// island and the Calendar tile on the Controls page. The page is always available: without access
/// it explains and offers the request. All reading lives in `CalendarModel`.
@MainActor
final class CalendarSection: IslandSection {
    let id = IslandSectionID.calendar
    let model: CalendarModel
    private unowned let environment: IslandEnvironment
    private let control: IslandControlModel
    private var visibility: AnyCancellable?

    init(environment: IslandEnvironment) {
        self.environment = environment
        model = CalendarModel(environment: environment,
                              preview: environment.isHeadless ? CalendarPreviewData.requested() : nil)
        control = IslandControlModel(.calendar) { [weak environment] in environment?.open(.calendar) }
        control.availability = Self.tileAvailability(visible: environment.settings.isVisible(.calendar), environment: environment)
        environment.register(control)
        visibility = environment.settingsStore.$value
            .map { $0.isVisible(.calendar) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                guard let self else { return }
                control.availability = Self.tileAvailability(visible: visible, environment: self.environment)
                self.environment.invalidate()
            }
    }

    /// The tile is a shortcut to the page, so it exists only while the page is shown.
    private static func tileAvailability(visible: Bool, environment: IslandEnvironment) -> IslandAvailability {
        visible ? .available : .unavailable("Show “Calendar” on the Content tab.", fixTitle: "Show") { [weak environment] in
            environment?.actions.openSettings(.calendar)
        }
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight { .fill }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(CalendarPageView(model: model, context: context))
    }

    func options() -> AnyView? { AnyView(CalendarOptionsView(model: model)) }

    func islandDidStart() { model.islandDidStart() }
    func islandDidStop() { model.islandDidStop() }
    func pageDidAppear() { model.pageDidAppear() }
    func pageDidDisappear() { model.pageDidDisappear() }
}
