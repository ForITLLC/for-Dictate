import Foundation
import XCTest
@testable import VoiceInk

final class CompanyDictionarySnapshotTests: XCTestCase {
    private let date = "2026-11-03T04:02:08.765Z"

    private func term(_ index: Int = 1) -> [String: Any] {
        ["term_id": String(format: "00000000-0000-0000-0000-%012d", index),
         "canonical_spelling": "ForIT", "spoken_forms": ["For IT", "four it"],
         "meaning": "The company name.", "kind": "product", "is_active": false,
         "revision": 2_147_483_647, "updated_at": date]
    }

    private func snapshot(_ terms: [[String: Any]]? = nil) -> [String: Any] {
        let rows = terms ?? [term()]
        return ["schemaVersion": 1, "companyId": CompanyDictionarySnapshot.supportCompanyID,
                "version": "\"opaque-v7-read-all\"", "terms": rows, "total": rows.count,
                "updated_at": date, "canEdit": false]
    }

    private func decode(_ object: [String: Any]) throws -> CompanyDictionarySnapshot {
        try JSONDecoder().decode(CompanyDictionarySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCompleteSnapshotPreservesServerFieldsAndInactiveAliases() throws {
        let result = try decode(snapshot())
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.companyID, CompanyDictionarySnapshot.supportCompanyID)
        XCTAssertEqual(result.version, "\"opaque-v7-read-all\"")
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.updatedAt, date)
        XCTAssertFalse(result.canEdit)
        let row = try XCTUnwrap(result.terms.first)
        XCTAssertEqual(row.id, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(row.canonicalSpelling, "ForIT")
        XCTAssertEqual(row.spokenForms, ["For IT", "four it"])
        XCTAssertEqual(row.meaning, "The company name.")
        XCTAssertEqual(row.kind, .product)
        XCTAssertFalse(row.isActive)
        XCTAssertEqual(row.revision, 2_147_483_647)
        XCTAssertEqual(row.updatedAt, date)
    }

    func testEmptySnapshotAcceptsNullOrHistoricalUpdateTime() throws {
        var object = snapshot([])
        object["updated_at"] = NSNull()
        XCTAssertEqual(try decode(object).terms, [])
        XCTAssertNil(try decode(object).updatedAt)
        // Active-only responses may have no selected rows but an inactive-row timestamp.
        object["updated_at"] = date
        XCTAssertEqual(try decode(object).updatedAt, date)
    }

    func testMalformedTypesSchemaCompanyAndMissingFieldsFail() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(CompanyDictionarySnapshot.self, from: Data("{".utf8)))
        for (key, value) in [("schemaVersion", 2 as Any), ("schemaVersion", true),
                             ("companyId", "c0efa09e-4bda-4a9d-a177-4c77076b7f76"),
                             ("canEdit", "false"), ("terms", NSNull()), ("updated_at", NSNull())] {
            var object = snapshot(); object[key] = value
            XCTAssertThrowsError(try decode(object), key)
        }
        for key in snapshot().keys {
            var object = snapshot(); object.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(object), key)
        }
    }

    func testCompleteCountBoundsAndUniqueStableIDs() throws {
        XCTAssertEqual(try decode(snapshot((1...1_000).map { term($0) })).total, 1_000)
        XCTAssertThrowsError(try decode(snapshot((1...1_001).map { term($0) })))
        XCTAssertThrowsError(try decode(snapshot([term(), term()])))
        for count in [-1, 0, 2] {
            var object = snapshot(); object["total"] = count
            XCTAssertThrowsError(try decode(object))
        }
        for id in ["00000000-0000-0000-0000-000000000000", "not-a-guid", "AAAAAAAA-0000-0000-0000-000000000001"] {
            var row = term(); row["term_id"] = id
            XCTAssertThrowsError(try decode(snapshot([row])))
        }
    }

    func testTermTypesKindsAndSQLRevisions() throws {
        for kind in ["term", "person", "product"] {
            var row = term(); row["kind"] = kind; row["revision"] = 1; row["is_active"] = true
            XCTAssertTrue(try decode(snapshot([row])).terms[0].isActive)
        }
        for (key, value) in [("revision", 0 as Any), ("revision", -1), ("revision", 2_147_483_648),
                             ("revision", 1.5), ("revision", true), ("kind", "unknown"),
                             ("is_active", 1), ("spoken_forms", "For IT"), ("meaning", NSNull())] {
            var row = term(); row[key] = value
            XCTAssertThrowsError(try decode(snapshot([row])), key)
        }
        for key in term().keys {
            var row = term(); row.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(snapshot([row])), key)
        }
    }

    func testUTF16LimitsPreserveUnicodeBeyondLocalByteBudget() throws {
        var row = term()
        row["canonical_spelling"] = String(repeating: "😀", count: 50) // 100 UTF-16 units, 200 UTF-8 bytes.
        row["meaning"] = String(repeating: "😀", count: 250)
        row["spoken_forms"] = (0..<12).map { "Alias \($0)" }
        XCTAssertEqual(try decode(snapshot([row])).terms[0].spokenForms.count, 12)
        row["canonical_spelling"] = String(repeating: "😀", count: 51)
        XCTAssertThrowsError(try decode(snapshot([row])))
        row = term(); row["meaning"] = String(repeating: "x", count: 501)
        XCTAssertThrowsError(try decode(snapshot([row])))
        row = term(); row["canonical_spelling"] = String(repeating: "\u{FDFA}", count: 6) // NFKC expands past 100.
        XCTAssertThrowsError(try decode(snapshot([row])))
        row = term(); row["meaning"] = ""; row["spoken_forms"] = [String]()
        XCTAssertEqual(try decode(snapshot([row])).terms[0].meaning, "")
    }

    func testAliasNormalizationAndControlRules() throws {
        for forms in [["For IT", "Ｆｏｒ\u{00A0}ＩＴ"], ["Alias", "\u{FEFF}alias\u{FEFF}"],
                      [String(repeating: "x", count: 101)], ["  "], (0..<13).map { "Alias \($0)" }] {
            var row = term(); row["spoken_forms"] = forms
            XCTAssertThrowsError(try decode(snapshot([row])))
        }
        for key in ["canonical_spelling", "meaning", "spoken_forms"] {
            for scalar in ["\u{0000}", "\u{001F}", "\u{007F}", "\u{0085}", "\u{009F}"] {
                var row = term(); row[key] = key == "spoken_forms" ? ["bad" + scalar] as Any : "bad" + scalar
                XCTAssertThrowsError(try decode(snapshot([row])))
            }
        }
        var row = term(); row["canonical_spelling"] = " \u{FEFF} "
        XCTAssertThrowsError(try decode(snapshot([row])))
    }

    func testQuotedOpaqueETagAndExactUTCTimestamps() throws {
        for version in ["7", "W/\"tag\"", "\"\"", "\"bad\"quote\"", "\"bad\nvalue\""] {
            var object = snapshot(); object["version"] = version
            XCTAssertThrowsError(try decode(object))
        }
        for timestamp in ["not-a-date", "2026-02-30T00:00:00.000Z", "2026-11-03T04:02:08Z", "2026-11-03T04:02:08.765+00:00"] {
            var object = snapshot(); object["updated_at"] = timestamp
            XCTAssertThrowsError(try decode(object))
            var row = term(); row["updated_at"] = timestamp
            XCTAssertThrowsError(try decode(snapshot([row])))
        }
    }
}
