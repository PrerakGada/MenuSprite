import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// The Downloads section's rules (core sections spec §4, activity spec §3.4 and §4.11), restated.

private let folder = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func file(_ inode: UInt64, size: Int64 = 100, modified: Double = 1, regular: Bool = true) -> DownloadFileIdentity {
    DownloadFileIdentity(device: 16_777_231, inode: inode, size: size, modified: modified, isRegular: regular)
}

private func inFolder(_ name: String) -> URL { folder.appendingPathComponent(name) }

// MARK: Partial names

@Test func eachBrowsersPartialFormatIsRecognisedWithItsFinalName() {
    #expect(DownloadNaming.partial("report.pdf.crdownload")! == (.chromium, "report.pdf"))
    #expect(DownloadNaming.partial("Unconfirmed 812345.crdownload")! == (.chromium, "Unconfirmed 812345"))
    #expect(DownloadNaming.partial("movie.mp4.download")! == (.safari, "movie.mp4"))
    #expect(DownloadNaming.partial("archive.zip.part")! == (.firefox, "archive.zip"))
    #expect(DownloadNaming.partial("ARCHIVE.ZIP.PART")?.kind == .firefox)
    #expect(DownloadNaming.partial("photo.jpg") == nil)
    #expect(DownloadNaming.partial("partial") == nil)
    #expect(DownloadNaming.partial(".crdownload") == nil)
    #expect(DownloadPartialKind.safari.isBundle)
    #expect(!DownloadPartialKind.chromium.isBundle && !DownloadPartialKind.firefox.isBundle)
}

@Test func onlyTheOneExpectedPayloadInsideASafariBundleIsInspected() {
    let bundle = inFolder("movie.mp4.download")
    #expect(DownloadNaming.payloadURL(inBundle: bundle) == bundle.appendingPathComponent("movie.mp4"))
    #expect(DownloadNaming.payloadURL(inBundle: inFolder("movie.mp4.crdownload")) == nil)
    #expect(DownloadNaming.finalURL(for: bundle) == inFolder("movie.mp4"))
    #expect(DownloadNaming.finalURL(for: inFolder("photo.jpg")) == inFolder("photo.jpg"))
}

@Test func longNamesAreShortenedInTheMiddleKeepingTheExtension() {
    let name = "quarterly-financial-statements-for-the-board-final-v3.pdf"
    let short = DownloadNaming.middleTruncated(name, limit: 32)
    #expect(short.count == 32)
    #expect(short.hasSuffix(".pdf"))
    #expect(short.hasPrefix("quarterly"))
    #expect(short.contains("…"))
    #expect(DownloadNaming.middleTruncated("photo.jpg", limit: 32) == "photo.jpg")
    #expect(DownloadNaming.middleTruncated(String(repeating: "a", count: 40), limit: 20).count == 20)
}

// MARK: Completion proof

@Test func aPublishedDownloadIsFinishedOnlyWithANewRegularFileAtAFinalPath() {
    let url = inFolder("report.pdf")
    #expect(DownloadProof.publicationFinished(isFinished: true, url: url, current: file(7), baseline: nil))
    // Not finished yet, no file, a directory, or still carrying the in-progress extension.
    #expect(!DownloadProof.publicationFinished(isFinished: false, url: url, current: file(7), baseline: nil))
    #expect(!DownloadProof.publicationFinished(isFinished: true, url: url, current: nil, baseline: nil))
    #expect(!DownloadProof.publicationFinished(isFinished: true, url: url, current: file(7, regular: false), baseline: nil))
    #expect(!DownloadProof.publicationFinished(isFinished: true, url: inFolder("report.pdf.crdownload"), current: file(7), baseline: nil))
}

@Test func anUnrelatedFileAlreadyAtTheDestinationIsNeverCalledFinished() {
    let url = inFolder("report.pdf")
    let existing = file(3, size: 500, modified: 10)
    #expect(!DownloadProof.publicationFinished(isFinished: true, url: url, current: existing, baseline: existing))
    // The same inode rewritten (new size or time) is a different file state, so it counts.
    #expect(DownloadProof.publicationFinished(isFinished: true, url: url, current: file(3, size: 900, modified: 12), baseline: existing))
    #expect(DownloadProof.publicationFinished(isFinished: true, url: url, current: file(4, size: 500, modified: 10), baseline: existing))
}

@Test func aMovedPublicationStaysTheSameDownloadOnlyWithTheFileLastSeenAndTheOldPathGone() {
    let lastSeen = file(42, size: 10)
    #expect(DownloadProof.acceptsMove(lastSeen: lastSeen, moved: file(42, size: 20), oldPathExists: false))
    #expect(!DownloadProof.acceptsMove(lastSeen: lastSeen, moved: file(42), oldPathExists: true))
    #expect(!DownloadProof.acceptsMove(lastSeen: lastSeen, moved: file(43), oldPathExists: false))
    #expect(!DownloadProof.acceptsMove(lastSeen: nil, moved: file(42), oldPathExists: false))
    #expect(!DownloadProof.acceptsMove(lastSeen: lastSeen, moved: nil, oldPathExists: false))
}

@Test func aPartialIsFinishedWhenItDisappearsAndItsFinalNameIsTheSameInode() {
    let partial = file(99, size: 4_000)
    #expect(DownloadProof.partialFinished(partial: partial, partialStillExists: false, final: file(99, size: 5_000)))
    #expect(!DownloadProof.partialFinished(partial: partial, partialStillExists: true, final: file(99)))
    // Firefox's placeholder left behind, a missing final file, a directory, or an unknown partial.
    #expect(!DownloadProof.partialFinished(partial: partial, partialStillExists: false, final: file(12)))
    #expect(!DownloadProof.partialFinished(partial: partial, partialStillExists: false, final: nil))
    #expect(!DownloadProof.partialFinished(partial: partial, partialStillExists: false, final: file(99, regular: false)))
    #expect(!DownloadProof.partialFinished(partial: nil, partialStillExists: false, final: file(99)))
    var otherDevice = file(99)
    otherDevice.device = 1
    #expect(!DownloadProof.partialFinished(partial: partial, partialStillExists: false, final: otherDevice))
}

// MARK: Publications

@Test func publicationsAreShownOnlyForDownloadsDirectlyInsideTheFolder() {
    let folders = [folder]
    func accepts(_ url: URL, cancelled: Bool = false, operation: DownloadPublication.Operation = .downloading) -> Bool {
        DownloadPublication.accepts(cancelled: cancelled, operation: operation, candidates: [url], folders: folders)
    }
    #expect(accepts(inFolder("report.pdf.crdownload")))
    #expect(accepts(inFolder("report.pdf"), operation: .receiving))
    #expect(!accepts(inFolder("report.pdf"), operation: .other))
    #expect(!accepts(inFolder("report.pdf"), cancelled: true))
    #expect(!accepts(inFolder("nested/report.pdf")))
    #expect(!accepts(folder))
    #expect(!accepts(URL(fileURLWithPath: "/Users/example/Desktop/report.pdf")))
    #expect(DownloadPublication.isDirectChild(URL(fileURLWithPath: "/Users/example/Downloads/a.zip"),
                                              of: URL(fileURLWithPath: "/Users/example/Downloads/")))
}

@Test func aPublicationSeenThroughASymbolicLinkStillCounts() {
    let aliases = [URL(fileURLWithPath: "/tmp/dl"), URL(fileURLWithPath: "/private/tmp/dl")]
    let published = URL(fileURLWithPath: "/tmp/dl/a.zip")
    let resolved = URL(fileURLWithPath: "/private/tmp/dl/a.zip")
    #expect(DownloadPublication.accepts(cancelled: false, operation: .downloading, candidates: [published, resolved],
                                        folders: [aliases[1]]))
    #expect(!DownloadPublication.accepts(cancelled: false, operation: .downloading, candidates: [URL(fileURLWithPath: "/private/tmp/a.zip")],
                                         folders: aliases))
}

@Test func aFileNotWrittenYetStillMatchesAnExistingFolderUnderPrivate() {
    // /private/tmp exists, the download does not: a check that consults the disk would call them unrelated.
    let pending = URL(fileURLWithPath: "/private/tmp/not-downloaded-\(UUID().uuidString).zip")
    #expect(DownloadPublication.isDirectChild(pending, of: URL(fileURLWithPath: "/private/tmp", isDirectory: true)))
}

@Test func aPublicationMovedOutsideTheFolderDisappears() {
    let before = inFolder("report.pdf.crdownload")
    let after = URL(fileURLWithPath: "/Users/example/Documents/report.pdf")
    #expect(DownloadPublication.accepts(cancelled: false, operation: .downloading, candidates: [before], folders: [folder]))
    #expect(!DownloadPublication.accepts(cancelled: false, operation: .downloading, candidates: [after], folders: [folder]))
}

@Test func aFractionIsShownOnlyWhenDeterminateWithAPositiveFiniteTotal() {
    #expect(DownloadPublication.fraction(0.42, total: 1_000, indeterminate: false) == 0.42)
    #expect(DownloadPublication.fraction(0.42, total: 1_000, indeterminate: true) == nil)
    #expect(DownloadPublication.fraction(0.42, total: 0, indeterminate: false) == nil)
    #expect(DownloadPublication.fraction(.nan, total: 1_000, indeterminate: false) == nil)
    #expect(DownloadPublication.fraction(1.7, total: 1_000, indeterminate: false) == 1)
    #expect(DownloadPublication.fraction(-0.2, total: 1_000, indeterminate: false) == 0)
}

// MARK: Coalescing

@Test func aThousandProgressChangesCoalesceIntoOneBatchWithTheFinalValue() {
    var batch = DownloadBatch<Int, Double>()
    var schedules = 0
    for step in 1...1_000 where batch.record(Double(step) / 1_000, for: 7) { schedules += 1 }
    #expect(schedules == 1)
    let flushed = batch.flush()
    #expect(flushed == [7: 1.0])
    let second = batch.flush()
    #expect(second.isEmpty)
    let rescheduled = batch.record(0.5, for: 7)
    #expect(rescheduled)
}

@Test func unpublishingTakesItsEvidenceOutWithoutWaitingForTheBatch() {
    var batch = DownloadBatch<Int, String>()
    _ = batch.record("half", for: 1)
    _ = batch.record("other", for: 2)
    let taken = batch.take(1)
    #expect(taken == "half")
    let rest = batch.flush()
    #expect(rest == [2: "other"])
}

@Test func aQueuedSnapshotCannotChangeAfterItWasCaptured() {
    struct Snapshot: Equatable { var fraction: Double }
    var batch = DownloadBatch<Int, Snapshot>()
    var live = Snapshot(fraction: 0.3)
    _ = batch.record(live, for: 1)
    live.fraction = 0.9
    let flushed = batch.flush()
    #expect(flushed[1] == Snapshot(fraction: 0.3))
}

// MARK: Merging

@Test func scanningListsEveryVisibleEntryNewestFirstIncludingImagesAndFolders() {
    let image = DownloadFolderEntry(url: inFolder("saved.png"), date: epoch.addingTimeInterval(30), isDirectory: false)
    let directory = DownloadFolderEntry(url: inFolder("Project"), date: epoch.addingTimeInterval(10), isDirectory: true)
    let older = DownloadFolderEntry(url: inFolder("notes.txt"), date: epoch, isDirectory: false)
    let items = DownloadMerge.items(transfers: [], partials: [], files: [older, image, directory], finished: [], now: epoch)
    #expect(items.map(\.name) == ["saved.png", "Project", "notes.txt"])
    #expect(items.allSatisfy { $0.status == .saved })
    #expect(items[1].isDirectory)
}

@Test func partialTransfersStaySeparateAndFirefoxsPlaceholderIsNotListedTwice() {
    let partial = DownloadPartial(url: inFolder("archive.zip.part"), kind: .firefox, identity: file(5, size: 2_048),
                                  modified: epoch.addingTimeInterval(-5))
    let placeholder = DownloadFolderEntry(url: inFolder("archive.zip"), date: epoch.addingTimeInterval(-6), isDirectory: false)
    let other = DownloadFolderEntry(url: inFolder("photo.jpg"), date: epoch.addingTimeInterval(-60), isDirectory: false)
    let items = DownloadMerge.items(transfers: [], partials: [partial], files: [placeholder, other], finished: [], now: epoch)
    #expect(items.count == 2)
    #expect(items[0].name == "archive.zip")
    #expect(items[0].status == .inProgress(fraction: nil, bytes: 2_048, active: true))
    #expect(items[0].revealURL == partial.url)
    #expect(items[1].name == "photo.jpg")
}

@Test func aDestinationAlreadyOnDiskCannotHideOngoingProgress() {
    let transfer = DownloadTransfer(url: inFolder("movie.mp4"), fraction: 0.4, bytes: 400, isPaused: false, firstSeen: epoch.addingTimeInterval(-90))
    let existing = DownloadFolderEntry(url: inFolder("movie.mp4"), date: epoch, isDirectory: false)
    let items = DownloadMerge.items(transfers: [transfer], partials: [], files: [existing], finished: [], now: epoch)
    #expect(items.count == 1)
    #expect(items[0].status == .inProgress(fraction: 0.4, bytes: 400, active: true))
}

@Test func aPublicationRepresentsItsPartialSoTheDownloadAppearsOnce() {
    let transfer = DownloadTransfer(url: inFolder("report.pdf.crdownload"), fraction: 0.7, bytes: nil, isPaused: false, firstSeen: epoch)
    let partial = DownloadPartial(url: inFolder("report.pdf.crdownload"), kind: .chromium, identity: file(8), modified: epoch)
    let safari = DownloadTransfer(url: inFolder("movie.mp4"), fraction: 0.2, bytes: nil, isPaused: false, firstSeen: epoch)
    let bundle = DownloadPartial(url: inFolder("movie.mp4.download"), kind: .safari, identity: nil, modified: epoch)
    let items = DownloadMerge.items(transfers: [transfer, safari], partials: [partial, bundle], files: [], finished: [], now: epoch)
    #expect(items.count == 2)
    #expect(Set(items.map(\.name)) == ["report.pdf", "movie.mp4"])
    #expect(items.allSatisfy { $0.fraction != nil })
}

@Test func completionsDoNotDuplicateTheFilesTheyBecame() {
    let saved = inFolder("report.pdf")
    let completion = DownloadCompletion(url: saved, date: epoch, identity: file(8))
    let entry = DownloadFolderEntry(url: saved, date: epoch, isDirectory: false)
    let items = DownloadMerge.items(transfers: [], partials: [], files: [entry], finished: [completion], now: epoch)
    #expect(items.count == 1)
    // Before the next scan lists it, the just-finished item stands in for it.
    let early = DownloadMerge.items(transfers: [], partials: [], files: [], finished: [completion], now: epoch)
    #expect(early.map(\.name) == ["report.pdf"])
}

@Test func deletedFilesDisappearOnTheNextScan() {
    let a = DownloadFolderEntry(url: inFolder("a.txt"), date: epoch, isDirectory: false)
    let b = DownloadFolderEntry(url: inFolder("b.txt"), date: epoch, isDirectory: false)
    #expect(DownloadMerge.items(transfers: [], partials: [], files: [a, b], finished: [], now: epoch).count == 2)
    #expect(DownloadMerge.items(transfers: [], partials: [], files: [a], finished: [], now: epoch).map(\.name) == ["a.txt"])
}

@Test func aCrowdedFolderHandsOnlyItsNewestEntriesToTheMainThread() {
    let entries = (0..<500).map { DownloadFolderEntry(url: inFolder("f\($0)"), date: epoch.addingTimeInterval(Double($0)), isDirectory: false) }
    let newest = DownloadMerge.newest(entries.shuffled(), limit: DownloadMerge.listLimit, date: \.date)
    #expect(newest.count == 200)
    #expect(newest.first?.url.lastPathComponent == "f499")
    #expect(newest.last?.url.lastPathComponent == "f300")
    #expect(DownloadMerge.partialLimit == 32 && DownloadMerge.publicationLimit == 32)
}

@Test func aPartialIsActiveForTwoMinutesAfterItsLastWriteAndOneTimerMarksTheEnd() {
    let fresh = DownloadPartial(url: inFolder("a.crdownload"), kind: .chromium, identity: nil, modified: epoch.addingTimeInterval(-30))
    let quiet = DownloadPartial(url: inFolder("b.crdownload"), kind: .chromium, identity: nil, modified: epoch.addingTimeInterval(-600))
    let newer = DownloadPartial(url: inFolder("c.crdownload"), kind: .chromium, identity: nil, modified: epoch.addingTimeInterval(-10))
    #expect(DownloadMerge.isActive(fresh, now: epoch))
    #expect(!DownloadMerge.isActive(quiet, now: epoch))
    #expect(DownloadMerge.nextExpiry(of: [fresh, quiet, newer], now: epoch) == epoch.addingTimeInterval(90))
    #expect(DownloadMerge.nextExpiry(of: [quiet], now: epoch) == nil)
}

@Test func activeTransfersLeadAndAbandonedOrPausedOnesSortByDate() {
    let abandoned = DownloadPartial(url: inFolder("old.zip.crdownload"), kind: .chromium, identity: nil, modified: epoch.addingTimeInterval(-86_400))
    let paused = DownloadTransfer(url: inFolder("paused.iso"), fraction: 0.5, bytes: nil, isPaused: true, firstSeen: epoch.addingTimeInterval(-300))
    let live = DownloadTransfer(url: inFolder("live.dmg"), fraction: nil, bytes: 10, isPaused: false, firstSeen: epoch.addingTimeInterval(-900))
    let recent = DownloadFolderEntry(url: inFolder("recent.png"), date: epoch.addingTimeInterval(-60), isDirectory: false)
    let items = DownloadMerge.items(transfers: [paused, live], partials: [abandoned], files: [recent], finished: [], now: epoch)
    #expect(items.map(\.name) == ["live.dmg", "recent.png", "paused.iso", "old.zip"])
    #expect(!items[2].isActive && !items[3].isActive)
}

@Test func justFinishedItemsKeepTheLastFiveOnePerPathAndAreAnnouncedOnce() {
    var finished: [DownloadCompletion] = []
    for index in 0..<7 {
        finished = DownloadMerge.adding(DownloadCompletion(url: inFolder("f\(index)"), date: epoch.addingTimeInterval(Double(index)),
                                                           identity: file(UInt64(index))), to: finished)
    }
    #expect(finished.map(\.url.lastPathComponent) == ["f6", "f5", "f4", "f3", "f2"])
    let again = DownloadCompletion(url: inFolder("f4"), date: epoch.addingTimeInterval(20), identity: file(4))
    #expect(!DownloadMerge.isNew(again, in: finished))
    let replaced = DownloadCompletion(url: inFolder("f4"), date: epoch.addingTimeInterval(20), identity: file(40))
    #expect(DownloadMerge.isNew(replaced, in: finished))
    finished = DownloadMerge.adding(replaced, to: finished)
    #expect(finished.count == 5)
    #expect(finished.first == replaced)
    #expect(finished.filter { $0.url.lastPathComponent == "f4" }.count == 1)
    #expect(DownloadMerge.finishedLifetime == 15)
}

// MARK: The compact strip

private let arrowWidth: CGFloat = 17.5

@Test func theDownloadWingIsFiftySixOrNothingByRoom() {
    for room in stride(from: CGFloat(0), through: 93, by: 0.5) {
        let wing = DownloadStripFit.wing(room: room, nameWidth: nil, arrowWidth: arrowWidth, stripHeight: 32)
        #expect(wing == (room >= 44 ? min(56, room) : 0))
    }
    #expect(DownloadStripFit.wing(room: 520, nameWidth: nil, arrowWidth: arrowWidth, stripHeight: 32) == 56)
}

@Test func onlyACrowdedPhysicalNotchMovesADownloadBelowTheCamera() {
    #expect(DownloadStripFit.placement(room: 20, physicalCamera: true, nameWidth: 80, arrowWidth: arrowWidth, stripHeight: 32) == .footer)
    #expect(DownloadStripFit.placement(room: 20, physicalCamera: false, nameWidth: 80, arrowWidth: arrowWidth, stripHeight: 24) == .hidden)
    #expect(DownloadStripFit.placement(room: 44, physicalCamera: true, nameWidth: 80, arrowWidth: arrowWidth, stripHeight: 32) == .wings(44))
}

@Test func shortNamesDoNotReserveTheNinetyFourPointWingAndLongNamesAreCapped() {
    let short = DownloadStripFit.wing(room: 300, nameWidth: 12, arrowWidth: arrowWidth, stripHeight: 32)
    #expect(short == 64)
    let long = DownloadStripFit.wing(room: 300, nameWidth: 600, arrowWidth: arrowWidth, stripHeight: 32)
    #expect(long == 160)
    // The music strip's wider preferences never stretch a download.
    #expect(DownloadStripFit.wing(room: 520, nameWidth: 40, arrowWidth: arrowWidth, stripHeight: 32) < 94)
}

@Test func aNameFitsOnceNinetyFourPointsAreAvailable() {
    let below = DownloadStripFit.wing(room: 93, nameWidth: 200, arrowWidth: arrowWidth, stripHeight: 32)
    #expect(below == 56 && !DownloadStripFit.showsName(wing: below))
    let at = DownloadStripFit.wing(room: 94, nameWidth: 200, arrowWidth: arrowWidth, stripHeight: 32)
    #expect(at == 94 && DownloadStripFit.showsName(wing: at))
}

@Test func theMeasuredWingHoldsTheWholeNameBesideItsArrow() {
    for height in stride(from: CGFloat(24), through: 64, by: 4) {
        for name in stride(from: CGFloat(20), through: 110, by: 7) {
            let wing = DownloadStripFit.wing(room: 400, nameWidth: name, arrowWidth: arrowWidth, stripHeight: height)
            let inset = DownloadStripFit.edgeInset(stripHeight: height, contentHeight: DownloadStripFit.arrowSize(stripHeight: height), round: true)
            let spaceForName = wing - inset - arrowWidth - DownloadStripFit.arrowToName - DownloadStripFit.nameToCamera
            #expect(spaceForName >= name - 0.001)
            #expect(DownloadStripFit.nameWing.contains(wing))
        }
    }
}

@Test func crowdedMenusKeepTheShortIndicatorWithoutAClippedName() {
    let wing = DownloadStripFit.wing(room: 60, nameWidth: 120, arrowWidth: arrowWidth, stripHeight: 32)
    #expect(wing == 56)
    #expect(DownloadStripFit.showsArrow(wing: wing) && DownloadStripFit.showsPercent(wing: wing))
    #expect(!DownloadStripFit.showsName(wing: wing))
    #expect(!DownloadStripFit.showsArrow(wing: 39) && DownloadStripFit.showsPercent(wing: 36) && !DownloadStripFit.showsPercent(wing: 35))
}

@Test func theArrowFitsPastTheCurvedEdgeOfTheShortWing() {
    for height in stride(from: CGFloat(24), through: 64, by: 1) {
        let size = DownloadStripFit.arrowSize(stripHeight: height)
        let inset = DownloadStripFit.edgeInset(stripHeight: height, contentHeight: size, round: true)
        #expect(inset + arrowWidth * size / 17 <= DownloadStripFit.defaultWing - 4)
    }
    #expect(DownloadStripFit.arrowSize(stripHeight: 32) == 17)
    #expect(DownloadStripFit.arrowSize(stripHeight: 24) == 14)
}

/// Distance from a point inside the strip to its left silhouette (straight side and bottom corner arc).
private func clearance(_ point: CGPoint, height: CGFloat) -> CGFloat {
    let shoulder = min(14, 0.19 * height)
    let radius = min(28, 0.34 * height, height / 2)
    let centre = CGPoint(x: shoulder + radius, y: height - radius)
    var distances = [point.x - shoulder, height - point.y]
    if point.x < centre.x, point.y > centre.y {
        distances.append(radius - hypot(point.x - centre.x, point.y - centre.y))
    }
    return distances.min()!
}

@Test func everythingTheStripDrawsKeepsFivePointsFromTheCurve() {
    for height in stride(from: CGFloat(24), through: 64, by: 1) {
        let arrow = DownloadStripFit.arrowSize(stripHeight: height)
        let boxes: [(size: CGFloat, round: Bool)] = [(arrow, true), (arrow, false), (11 * 0.72, false), (10 * 0.72, false)]
        for box in boxes {
            let inset = DownloadStripFit.edgeInset(stripHeight: height, contentHeight: box.size, round: box.round)
            let top = (height - box.size) / 2
            var edge: [CGPoint] = []
            for step in 0...40 {
                let t = CGFloat(step) / 40
                if box.round {
                    let angle = CGFloat.pi / 2 + t * CGFloat.pi
                    edge.append(CGPoint(x: inset + box.size / 2 + cos(angle) * box.size / 2,
                                        y: top + box.size / 2 + sin(angle) * box.size / 2))
                } else {
                    edge.append(CGPoint(x: inset, y: top + t * box.size))
                    edge.append(CGPoint(x: inset + t * box.size, y: top + box.size))
                }
            }
            #expect(edge.allSatisfy { clearance($0, height: height) >= DownloadStripFit.edgeGap - 0.01 },
                    "height \(height), box \(box.size) round \(box.round)")
        }
    }
}

@Test func everyWingIsEitherNothingOrAtLeastFortyFour() {
    for room in stride(from: CGFloat(0), through: 300, by: 1) {
        for name: CGFloat? in [nil, 10, 90, 400] {
            let wing = DownloadStripFit.wing(room: room, nameWidth: name, arrowWidth: arrowWidth, stripHeight: 32)
            #expect(wing == 0 || wing >= 44)
            #expect(wing <= max(room, 0))
        }
    }
}

// MARK: The notice

@Test func aFinishedDownloadRaisesTheLowestPriorityNoticeForSixSecondsOpeningThePage() {
    #expect(IslandNoticeKind.downloadComplete.priority == 0)
    #expect(IslandNoticeKind.downloadComplete.duration == 6)
    #expect(IslandNoticeKind.downloadComplete.section == .downloads)
    #expect(!IslandNoticeKind.downloadComplete.replaces(.battery))
    #expect(IslandNoticeKind.volume.replaces(.downloadComplete))
}

@Test func downloadsComeSecondInTheAutomaticOrderAndMayShareOnlyWithATimer() {
    var choice = IslandActivityChoice()
    #expect(choice.resolve(live: [.downloads, .agents, .calendar, .music], timerRunning: false)?.primary == .downloads)
    #expect(IslandActivityChoice.companions(live: [.timer, .downloads], timerRunning: false) == [.downloads])
    choice.combine(.downloads, live: [.timer, .downloads], timerRunning: false)
    #expect(choice.resolve(live: [.timer, .downloads], timerRunning: false)?.companion == .downloads)
}
