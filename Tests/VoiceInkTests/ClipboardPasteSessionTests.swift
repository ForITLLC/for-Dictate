import Foundation
import XCTest
@testable import VoiceInk

/// Uses the production coordinator with synthetic clipboard/event/delay effects only.
/// No NSPasteboard, Accessibility, keyboard events, app singleton or user data is opened.
final class ClipboardPasteSessionTests: XCTestCase {
    private let ownership = ClipboardPasteOwnership(text: "new dictation", sessionID: "session-A", changeCount: 10)

    private var original: ClipboardPasteOwnership.Snapshot {
        .init(text: ownership.text, sessionID: ownership.sessionID, changeCount: ownership.changeCount)
    }

    @MainActor
    func testReplacementDuringPrePasteDelayNeverDispatches() async {
        var board = original
        var events: [ClipboardPasteKeyEvent] = []
        let result = await ClipboardPasteCoordinator.deliver(
            ownership: ownership, current: { board },
            waitBeforePaste: { board = .init(text: "old sentinel", sessionID: nil, changeCount: 11) },
            dispatch: {
                await ClipboardPasteCoordinator.postShortcut(
                    ownership: self.ownership, current: { board },
                    waitBetweenEvents: {}, post: { events.append($0) }
                )
            }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertFalse(result.didPostPasteCommand, "Ownership loss cannot enable auto-send or Auto Learn success.")
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testReplacementAfterCommandDownReleasesModifierWithoutV() async {
        var board = original
        var events: [ClipboardPasteKeyEvent] = []
        let result = await ClipboardPasteCoordinator.postShortcut(
            ownership: ownership, current: { board },
            waitBetweenEvents: { board = .init(text: "old sentinel", sessionID: nil, changeCount: 11) },
            post: { events.append($0) }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertFalse(result.didPostPasteCommand)
        XCTAssertEqual(events, [.commandDown, .commandUp])
    }

    @MainActor
    func testReplacementAfterVDownReleasesBothKeysAndDoesNotReportSuccess() async {
        var board = original
        var waits = 0
        var events: [ClipboardPasteKeyEvent] = []
        let result = await ClipboardPasteCoordinator.postShortcut(
            ownership: ownership, current: { board },
            waitBetweenEvents: {
                waits += 1
                if waits == 2 { board = .init(text: "foreign", sessionID: nil, changeCount: 11) }
            },
            post: { events.append($0) }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertFalse(result.didPostPasteCommand)
        XCTAssertEqual(events, [.commandDown, .vDown, .vUp, .commandUp])
        XCTAssertEqual(waits, 2, "An uncertain paste is never retried.")
    }

    @MainActor
    func testUnchangedClipboardPostsExactlyOneShortcut() async {
        let board = original
        var events: [ClipboardPasteKeyEvent] = []
        var waits = 0
        let result = await ClipboardPasteCoordinator.deliver(
            ownership: ownership, current: { board }, waitBeforePaste: { waits += 1 },
            dispatch: {
                await ClipboardPasteCoordinator.postShortcut(
                    ownership: self.ownership, current: { board },
                    waitBetweenEvents: { waits += 1 }, post: { events.append($0) }
                )
            }
        )
        XCTAssertEqual(result, .commandPosted)
        XCTAssertTrue(result.didPostPasteCommand)
        XCTAssertEqual(events, [.commandDown, .vDown, .vUp, .commandUp])
        XCTAssertEqual(waits, 4)
    }

    @MainActor
    func testSameTextFromAnotherSessionIsNotOurClipboard() async {
        let board = ClipboardPasteOwnership.Snapshot(text: ownership.text, sessionID: "session-B", changeCount: 11)
        var events: [ClipboardPasteKeyEvent] = []
        let result = await ClipboardPasteCoordinator.postShortcut(
            ownership: ownership, current: { board }, waitBetweenEvents: {}, post: { events.append($0) }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testChangeAwayAndBackCannotPasteOrRestoreEvenWithSameTextAndMarker() async {
        // A foreign writer restored every clipboard value; only the generation differs.
        let board = ClipboardPasteOwnership.Snapshot(text: ownership.text, sessionID: ownership.sessionID, changeCount: 12)
        var events: [ClipboardPasteKeyEvent] = []
        var restores = 0
        let result = await ClipboardPasteCoordinator.postShortcut(
            ownership: ownership, current: { board }, waitBetweenEvents: {}, post: { events.append($0) }
        )
        let restored = ClipboardPasteCoordinator.restoreIfOwned(
            ownership: ownership, current: { board }, restore: { restores += 1 }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(restored)
        XCTAssertEqual(restores, 0)
    }

    @MainActor
    func testRestoreSkipsForeignContentsAndAllowsUnchangedOwnedContents() {
        var board = ClipboardPasteOwnership.Snapshot(text: "foreign", sessionID: nil, changeCount: 11)
        var restores = 0
        XCTAssertFalse(ClipboardPasteCoordinator.restoreIfOwned(
            ownership: ownership, current: { board }, restore: { restores += 1 }
        ))
        XCTAssertEqual(restores, 0)
        board = original
        XCTAssertTrue(ClipboardPasteCoordinator.restoreIfOwned(
            ownership: ownership, current: { board }, restore: { restores += 1 }
        ))
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testAppleScriptRechecksImmediatelyBeforeExecution() async {
        var board = original
        var scripts = 0
        let result = await ClipboardPasteCoordinator.deliver(
            ownership: ownership, current: { board }, waitBeforePaste: {},
            dispatch: {
                board = .init(text: "foreign", sessionID: nil, changeCount: 11)
                return ClipboardPasteCoordinator.postAppleScript(
                    ownership: self.ownership, current: { board }, post: { scripts += 1; return true }
                )
            }
        )
        XCTAssertEqual(result, .clipboardChanged)
        XCTAssertFalse(result.didPostPasteCommand)
        XCTAssertEqual(scripts, 0)
    }

    @MainActor
    func testUnchangedAppleScriptDispatchesOnceAndPreservesFailureResult() {
        let board = original
        var scripts = 0
        XCTAssertEqual(ClipboardPasteCoordinator.postAppleScript(
            ownership: ownership, current: { board }, post: { scripts += 1; return true }
        ), .commandPosted)
        XCTAssertEqual(scripts, 1)
        XCTAssertEqual(ClipboardPasteCoordinator.postAppleScript(
            ownership: ownership, current: { board }, post: { scripts += 1; return false }
        ), .commandNotPosted)
        XCTAssertEqual(scripts, 2)
    }

    @MainActor
    func testDirectTypingDoesNotReadOrWaitOnClipboard() async {
        var reads = 0
        var waits = 0
        var dispatches = 0
        let result = await ClipboardPasteCoordinator.deliver(
            ownership: nil,
            current: { reads += 1; return self.original },
            waitBeforePaste: { waits += 1 },
            dispatch: { dispatches += 1; return .commandPosted }
        )
        XCTAssertEqual(result, .commandPosted)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(dispatches, 1)
    }

    @MainActor
    func testCancellationAfterCommandDownStillReleasesModifier() async {
        let board = original
        let task = Task { @MainActor in
            var events: [ClipboardPasteKeyEvent] = []
            let result = await ClipboardPasteCoordinator.postShortcut(
                ownership: self.ownership, current: { board },
                waitBetweenEvents: {
                    withUnsafeCurrentTask { task in
                        if let task { task.cancel() }
                    }
                },
                post: { events.append($0) }
            )
            return (result, events)
        }
        let (result, events) = await task.value
        XCTAssertEqual(result, .commandNotPosted)
        XCTAssertFalse(result.didPostPasteCommand)
        XCTAssertEqual(events, [.commandDown, .commandUp])
    }
}
