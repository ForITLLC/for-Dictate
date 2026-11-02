import Foundation
import XCTest
@testable import VoiceInk

final class TinycastHistorySnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_290_000)
    private let lowID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let highID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!

    private func entry(id: UUID? = nil, date: Date? = nil, text: String = "Synthetic raw dictation",
                       enhanced: String? = "Synthetic preferred dictation", status: String? = "completed",
                       duration: TimeInterval = 1.25) -> TinycastHistoryEntry? {
        TinycastHistoryEntry(id: id ?? lowID, timestamp: date ?? now, rawText: text,
                             enhancedText: enhanced, duration: duration, status: status)
    }

    private func snapshot(_ entries: [TinycastHistoryEntry], limit: Int = 8_388_608) throws -> Data {
        var builder = try TinycastHistorySnapshotBuilder(updatedAt: now, maximumBytes: limit)
        for entry in entries { try builder.append(entry) }
        return builder.encodedSnapshot()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCompletedAndLegacyRowsAreEligibleButOtherStatesAreNot() {
        XCTAssertNotNil(entry(status: "completed"))
        XCTAssertNotNil(entry(status: nil))
        for status in ["pending", "failed", "canceled", "cancelled", "", "unknown"] {
            XCTAssertNil(entry(status: status), status)
        }
    }

    func testEmptyAndKnownLegacyFailurePlaceholdersAreNotSuccessful() {
        for text in ["", " \n\t", "The transcription was canceled.",
                     "Transcription Failed: No model selected", "Enhancement failed: synthetic failure"] {
            XCTAssertNil(entry(text: text, status: nil))
        }
    }

    func testPreferredTextRejectsEnhancementFailureAndPreservesRawWhitespace() throws {
        let raw = "  Synthetic original\n"
        for enhanced in [nil, "", " \t", "Enhancement failed: synthetic failure",
                         "Transcription Failed: synthetic failure", "The transcription was canceled."] {
            let value = try XCTUnwrap(entry(text: raw, enhanced: enhanced))
            XCTAssertEqual(value.text, raw)
            XCTAssertEqual(value.rawText, raw)
        }
        XCTAssertEqual(entry(text: raw, enhanced: "  Preferred\n")?.text, "  Preferred\n")
    }

    func testSourceBundleLocalizedFailureMessagesAreRejected() {
        let keys = ["Enhancement failed: %@", "Transcription Failed: %@"]
        let bundles = [Bundle.main] + Bundle.main.localizations.compactMap {
            Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:))
        }
        for bundle in bundles {
            for key in keys {
                let format = bundle.localizedString(forKey: key, value: key, table: nil)
                let message = String(format: format, "synthetic failure")
                XCTAssertEqual(HistorySuccessPolicy.preferredText(rawText: "Original", enhancedText: message), "Original")
                XCTAssertFalse(HistorySuccessPolicy.isSuccessful(status: nil, rawText: message))
            }
        }
    }

    func testSelectionUsesNewestTimestampThenNormalizedIdentifier() throws {
        let older = try XCTUnwrap(entry(id: UUID(), date: now.addingTimeInterval(-1)))
        let sameTimeHigh = try XCTUnwrap(entry(id: highID))
        let sameTimeLow = try XCTUnwrap(entry(id: lowID))
        let payload = try object(snapshot([older, sameTimeHigh, sameTimeLow]))
        let rows = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String },
                       [lowID.uuidString.lowercased(), highID.uuidString.lowercased(), older.id])
    }

    func testSubmillisecondRowsUseWireTimestampUUIDTieInAllSelections() throws {
        let high = try XCTUnwrap(entry(id: highID, date: now.addingTimeInterval(0.0009)))
        let low = try XCTUnwrap(entry(id: lowID, date: now.addingTimeInterval(0.0001)))
        XCTAssertEqual(high.timestamp, low.timestamp)
        XCTAssertEqual(high.orderingMilliseconds, low.orderingMilliseconds)
        XCTAssertTrue(HistorySuccessPolicy.precedes(timestamp: now.addingTimeInterval(0.0001), id: low.id,
                                                    timestamp: now.addingTimeInterval(0.0009), id: high.id))
        let payload = try object(snapshot([high, low]))
        let rows = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, [low.id, high.id])
    }

    func testEnvelopeAndEntryHaveOnlyContractFieldsAndRealUTCDate() throws {
        let payload = try object(snapshot([XCTUnwrap(entry())]))
        XCTAssertEqual(Set(payload.keys), ["schemaVersion", "updatedAt", "truncated", "entries"])
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        let rows = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(row.keys), ["id", "timestamp", "text", "rawText", "duration"])
        let timestamp = try XCTUnwrap(row["timestamp"] as? String)
        XCTAssertTrue(timestamp.hasSuffix("Z"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(try XCTUnwrap(formatter.date(from: timestamp)).timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEscapingAndMultibyteBoundRetainsWholeNewestRecord() throws {
        let text = String(repeating: "é🙂\"\\\n", count: 30)
        let newest = try XCTUnwrap(entry(text: text, enhanced: nil))
        let older = try XCTUnwrap(entry(id: highID, date: now.addingTimeInterval(-1), text: text, enhanced: nil))
        let oneSize = try snapshot([newest]).count
        let data = try snapshot([older, newest], limit: oneSize)
        XCTAssertLessThanOrEqual(data.count, oneSize)
        let payload = try object(data)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        let rows = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["text"] as? String, text)
        XCTAssertEqual(rows.first?["rawText"] as? String, text)
    }

    func testOversizedNewestDoesNotBackfillWithOlderSmallRecord() throws {
        let newest = try XCTUnwrap(entry(text: String(repeating: "x", count: 1_000), enhanced: nil))
        let older = try XCTUnwrap(entry(id: highID, date: now.addingTimeInterval(-1), text: "Small", enhanced: nil))
        let payload = try object(snapshot([older, newest], limit: 500))
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(payload["entries"] as? [[String: Any]]).isEmpty)
    }

    func testSmallerUUIDCanEnterBeforeOmittedTimestampTie() throws {
        let high = try XCTUnwrap(entry(id: highID, text: String(repeating: "x", count: 1_000), enhanced: nil))
        let low = try XCTUnwrap(entry(id: lowID, text: "Fits", enhanced: nil))
        let payload = try object(snapshot([high, low], limit: 400))
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        let rows = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, low.id)
    }

    func testExactEnvelopeBoundaryCannotPublishOneExtraByte() throws {
        let value = try XCTUnwrap(entry())
        let full = try snapshot([value])
        XCTAssertEqual(try snapshot([value], limit: full.count).count, full.count)
        let limited = try snapshot([value], limit: full.count - 1)
        XCTAssertLessThanOrEqual(limited.count, full.count - 1)
        XCTAssertEqual(try object(limited)["truncated"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(object(limited)["entries"] as? [[String: Any]]).isEmpty)
    }

    func testProductionEightMiBCapIncludesBothTextValuesAndEnvelope() throws {
        XCTAssertEqual(TinycastHistorySnapshotBuilder.maximumEncodedBytes, 8_388_608)
        let value = try XCTUnwrap(entry(text: String(repeating: "é", count: 2_100_000), enhanced: nil))
        var builder = try TinycastHistorySnapshotBuilder(updatedAt: now)
        try builder.append(value)
        XCTAssertEqual(builder.encodedRecordCount, 0, "An oversized source record must be omitted before allocating its full JSON value.")
        let data = builder.encodedSnapshot()
        XCTAssertLessThanOrEqual(data.count, 8_388_608)
        let payload = try object(data)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(payload["entries"] as? [[String: Any]]).isEmpty)
    }

    func testEscapeExpansionIsRejectedBeforeFullEntryEncoding() throws {
        let value = try XCTUnwrap(entry(text: String(repeating: "\u{0001}", count: 300), enhanced: nil))
        var builder = try TinycastHistorySnapshotBuilder(updatedAt: now, maximumBytes: 500)
        try builder.append(value)
        XCTAssertEqual(builder.encodedRecordCount, 0)
        let payload = try object(builder.encodedSnapshot())
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(payload["entries"] as? [[String: Any]]).isEmpty)
    }

    func testPreflightCountsEncodedEscapingAndUnicodeBytes() throws {
        let value = try XCTUnwrap(entry(text: "é🙂\u{2028}\u{2029}\"\\/\n\r\t\u{0001}", enhanced: nil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let actual = try encoder.encode(value)
        XCTAssertEqual(try TinycastHistorySnapshotBuilder.encodedEntrySize(value, upTo: actual.count), actual.count)
        XCTAssertNil(try TinycastHistorySnapshotBuilder.encodedEntrySize(value, upTo: actual.count - 1))
    }

    func testPlaceholderRecognitionDoesNotNormalizeWholeLongPayloads() throws {
        let large = String(repeating: "é🙂", count: 100_000)
        XCTAssertEqual(HistorySuccessPolicy.preferredText(rawText: "Original", enhancedText: "Enhancement failed: " + large), "Original")
        XCTAssertFalse(HistorySuccessPolicy.isSuccessful(status: nil, rawText: "Transcription Failed: " + large))
        XCTAssertTrue(HistorySuccessPolicy.isSuccessful(status: nil, rawText: "The transcription was canceled. " + large))
    }

    func testInvalidMetadataAndDuplicateIdentifiersCannotPublishInvalidContract() throws {
        XCTAssertNil(entry(duration: -.infinity))
        XCTAssertNil(entry(duration: .nan))
        XCTAssertNil(entry(duration: -1))
        XCTAssertNil(entry(date: Date(timeIntervalSince1970: .infinity)))
        XCTAssertNotNil(entry(duration: 0))
        XCTAssertThrowsError(try snapshot([XCTUnwrap(entry()), XCTUnwrap(entry())]))
        XCTAssertThrowsError(try snapshot([], limit: 1))
    }

    func testRebuildingAfterDeletionPublishesEmptySnapshotWithoutOldRecords() throws {
        let before = try object(snapshot([XCTUnwrap(entry())]))
        XCTAssertEqual((before["entries"] as? [[String: Any]])?.count, 1)
        let after = try object(snapshot([]))
        XCTAssertEqual((after["entries"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(after["truncated"] as? Bool, false)
    }

    func testEmitConsumerFixtureIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["FORIT_SYNTHETIC_HISTORY_FIXTURE_PATH"], !path.isEmpty else { return }
        let value = try XCTUnwrap(entry(text: "Synthetic raw: \"ForIT\" 🙂\n", enhanced: "Synthetic preferred: ForIT 🙂\n"))
        let data = try snapshot([value])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
