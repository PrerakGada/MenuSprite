import IslandKit

/// Made-up messages for the off-screen render harness, so the page, the banner and the message card
/// can be checked without real notifications: `--sample-notifications` fills the inbox,
/// `--sample-notifications-denied` shows the page as it looks without Accessibility.
enum NotificationSamples {
    enum Mode { case populated, denied }

    static var mode: Mode? {
        let arguments = CommandLine.arguments
        if arguments.contains("--sample-notifications-denied") { return .denied }
        return arguments.contains("--sample-notifications") ? .populated : nil
    }

    private static let close = "Name:Close\nTarget:0x0\nSelector:(null)"

    private static func app(_ name: String, _ bundleID: String) -> NotificationSource {
        NotificationSource(name: name, bundleID: bundleID, path: "/System/Applications/\(name).app")
    }

    /// Oldest first.
    static let items: [NotificationSnapshotItem] = [
        NotificationSnapshotItem(fields: NotificationFields(header: "Calendar", title: "Design review", body: "Tomorrow at 10:00 · Studio 2"),
                                 source: app("Calendar", "com.apple.iCal"), element: 1, canPress: true, closeAction: close),
        NotificationSnapshotItem(fields: NotificationFields(header: "Mail", title: "Asha Mehta", subtitle: "September invoice",
                                                            body: "Attaching the invoice for September. Tell me if anything needs to change before the month closes."),
                                 source: app("Mail", "com.apple.mail"), element: 2, canPress: true, closeAction: close),
        NotificationSnapshotItem(fields: NotificationFields(title: "Backup finished", body: "Your files were copied to the external drive."),
                                 element: 3, canPress: false),
        NotificationSnapshotItem(fields: NotificationFields(header: "Reminders", title: "Pay the electricity bill", body: "Due today"),
                                 source: app("Reminders", "com.apple.reminders"), element: 4, canPress: true, isPersistent: true),
        NotificationSnapshotItem(fields: NotificationFields(header: "Messages", title: "Nidhi", subtitle: "Hackathon team",
                                                            body: "Pushed the new screens. Can you look before the call? The onboarding flow changed quite a bit."),
                                 source: app("Messages", "com.apple.MobileSMS"), element: 5, canPress: true, closeAction: close),
    ]
}
