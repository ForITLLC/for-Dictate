import Foundation

enum ClipboardPasteResult: Equatable, Sendable {
    case commandPosted
    case commandNotPosted
    case commandPartiallyPosted
    case clipboardChanged

    var didPostPasteCommand: Bool { self == .commandPosted }
}

struct ClipboardPasteOwnership: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let text: String?
        let sessionID: String?
        let changeCount: Int
    }

    let text: String
    let sessionID: String
    let changeCount: Int

    func owns(_ snapshot: Snapshot) -> Bool {
        snapshot.text == text && snapshot.sessionID == sessionID
            && snapshot.changeCount == changeCount
    }
}

enum ClipboardPasteKeyEvent: Equatable, Sendable {
    case commandDown, vDown, vUp, commandUp
}

/// Production paste sequencing with injectable clipboard, delay and event effects.
/// Direct typing passes no ownership and does not read or wait on the clipboard.
@MainActor
enum ClipboardPasteCoordinator {
    @discardableResult
    static func restoreIfOwned(
        ownership: ClipboardPasteOwnership,
        current: () -> ClipboardPasteOwnership.Snapshot,
        restore: () -> Void
    ) -> Bool {
        guard ownership.owns(current()) else { return false }
        restore()
        return true
    }

    static func deliver(
        ownership: ClipboardPasteOwnership?,
        current: () -> ClipboardPasteOwnership.Snapshot,
        waitBeforePaste: () async -> Void,
        dispatch: () async -> ClipboardPasteResult
    ) async -> ClipboardPasteResult {
        guard let ownership else { return await dispatch() }
        await waitBeforePaste()
        if let failure = failure(ownership: ownership, current: current) { return failure }
        return await dispatch()
    }

    static func postAppleScript(
        ownership: ClipboardPasteOwnership,
        current: () -> ClipboardPasteOwnership.Snapshot,
        post: () -> Bool
    ) -> ClipboardPasteResult {
        if let failure = failure(ownership: ownership, current: current) { return failure }
        return post() ? .commandPosted : .commandNotPosted
    }

    static func postShortcut(
        ownership: ClipboardPasteOwnership,
        current: () -> ClipboardPasteOwnership.Snapshot,
        waitBetweenEvents: () async -> Void,
        post: (ClipboardPasteKeyEvent) -> Void
    ) async -> ClipboardPasteResult {
        if let failure = failure(ownership: ownership, current: current) { return failure }
        var vIsDown = false
        post(.commandDown)
        defer {
            // Aborting after any suspension must not leave a synthetic key held down.
            if vIsDown { post(.vUp) }
            post(.commandUp)
        }
        await waitBetweenEvents()
        if let failure = failure(ownership: ownership, current: current) { return failure }
        post(.vDown)
        vIsDown = true
        await waitBetweenEvents()
        if let failure = failure(ownership: ownership, current: current, partiallyPosted: true) {
            return failure
        }
        post(.vUp)
        vIsDown = false
        await waitBetweenEvents()
        if let failure = failure(ownership: ownership, current: current, partiallyPosted: true) {
            return failure
        }
        return .commandPosted
    }

    private static func failure(
        ownership: ClipboardPasteOwnership,
        current: () -> ClipboardPasteOwnership.Snapshot,
        partiallyPosted: Bool = false
    ) -> ClipboardPasteResult? {
        guard ownership.owns(current()) else { return .clipboardChanged }
        guard !Task.isCancelled else {
            return partiallyPosted ? .commandPartiallyPosted : .commandNotPosted
        }
        return nil
    }
}
