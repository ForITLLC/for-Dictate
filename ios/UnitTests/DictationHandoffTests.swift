import XCTest

final class DictationHandoffTests: XCTestCase {
    private var directory: URL!
    private var store: DictationHandoffStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-handoff-\(UUID().uuidString)", isDirectory: true)
        store = DictationHandoffStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: The link the keyboard opens

    func testOpenURLCarriesTheRequest() {
        let id = UUID()
        let url = DictationHandoff.openURL(for: id)
        XCTAssertEqual(url.scheme, "io.forit.dictate")
        XCTAssertEqual(url.host, "dictate")
        XCTAssertEqual(DictationHandoff.requestID(from: url), id)
    }

    func testOtherLinksAreNotRequests() throws {
        let id = UUID().uuidString
        for text in [
            "https://dictate?request=\(id)",
            "io.forit.dictate://settings?request=\(id)",
            "io.forit.dictate://dictate",
            "io.forit.dictate://dictate?request=not-a-uuid",
            "io.forit.dictate://dictate?other=\(id)",
        ] {
            XCTAssertNil(DictationHandoff.requestID(from: try XCTUnwrap(URL(string: text))), text)
        }
    }

    // MARK: Request

    func testAFreshRequestIsReadBack() throws {
        let request = DictationRequest(id: UUID(), createdAt: now)
        try store.write(request)
        XCTAssertEqual(store.request(now: now.addingTimeInterval(2)), request)
    }

    func testAStaleRequestIsIgnored() throws {
        try store.write(DictationRequest(id: UUID(), createdAt: now))
        XCTAssertNil(store.request(now: now.addingTimeInterval(DictationHandoff.requestLifetime + 1)))
    }

    func testAClearedRequestIsGone() throws {
        try store.write(DictationRequest(id: UUID(), createdAt: now))
        store.clearRequest()
        XCTAssertNil(store.request(now: now))
    }

    // MARK: State

    func testOnlyAReadyAppWithTimeLeftAcceptsRequests() {
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(DictationState(phase: .ready, requestID: nil, updatedAt: now, readyUntil: later).acceptsRequests(at: now))
        XCTAssertFalse(DictationState(phase: .ready, requestID: nil, updatedAt: now, readyUntil: later).acceptsRequests(at: later))
        XCTAssertFalse(DictationState(phase: .ready, requestID: nil, updatedAt: now, readyUntil: nil).acceptsRequests(at: now))
        for phase in [DictationState.Phase.idle, .recording, .transcribing] {
            XCTAssertFalse(DictationState(phase: phase, requestID: nil, updatedAt: now, readyUntil: later).acceptsRequests(at: now))
        }
    }

    func testStateIsReadBack() throws {
        let state = DictationState(phase: .recording, requestID: UUID(), updatedAt: now, readyUntil: nil)
        try store.write(state)
        XCTAssertEqual(store.state(), state)
    }

    // MARK: Result

    func testAResultIsTakenOnce() throws {
        let id = UUID()
        try store.write(DictationResult(requestID: id, text: "Hello there.", failure: nil, createdAt: now))
        XCTAssertEqual(store.takeResult(for: id, now: now)?.text, "Hello there.")
        XCTAssertNil(store.takeResult(for: id, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.json").path))
    }

    func testAResultForAnotherRequestIsLeft() throws {
        let id = UUID()
        try store.write(DictationResult(requestID: id, text: "Mine.", failure: nil, createdAt: now))
        XCTAssertNil(store.takeResult(for: UUID(), now: now))
        XCTAssertEqual(store.takeResult(for: id, now: now)?.text, "Mine.")
    }

    func testAStaleResultIsRemovedAndNeverTyped() throws {
        let id = UUID()
        try store.write(DictationResult(requestID: id, text: "Too late.", failure: nil, createdAt: now))
        let late = now.addingTimeInterval(DictationHandoff.resultLifetime + 1)
        XCTAssertNil(store.takeResult(for: id, now: late))
        XCTAssertNil(store.takeResult(for: id, now: now))
    }

    func testRemoveStaleResultKeepsAFreshOne() throws {
        let id = UUID()
        try store.write(DictationResult(requestID: id, text: "Fresh.", failure: nil, createdAt: now))
        store.removeStaleResult(now: now.addingTimeInterval(5))
        XCTAssertEqual(store.takeResult(for: id, now: now.addingTimeInterval(6))?.text, "Fresh.")
    }

    func testRemoveStaleResultRemovesAnOldOne() throws {
        let id = UUID()
        try store.write(DictationResult(requestID: id, text: "Old.", failure: nil, createdAt: now))
        store.removeStaleResult(now: now.addingTimeInterval(DictationHandoff.resultLifetime + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.json").path))
    }

    // MARK: Spacing and clean-up

    func testSeparatorKeepsDictationOffThePreviousWord() {
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello", before: "there"), " ")
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello.", before: "Next"), " ")
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello ", before: "there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello\n", before: "there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello", before: ", there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: "(", before: "there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: nil, before: "there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: "", before: "there"), "")
        XCTAssertEqual(InsertionSpacing.separator(after: "Hello", before: ""), "")
    }

    func testCleanUpDropsNoiseAndFillerWords() {
        XCTAssertEqual(DictationText.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(DictationText.clean("  Um, send the report (coughs) today.  "), "send the report today.")
    }
}
