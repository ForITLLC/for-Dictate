import Darwin
import Foundation
import XCTest
@testable import VoiceInk

final class TinycastHistorySnapshotWriterTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func snapshot(empty: Bool) throws -> Data {
        var builder = try TinycastHistorySnapshotBuilder(updatedAt: Date(timeIntervalSince1970: 1_793_290_000))
        if !empty {
            let entry = try XCTUnwrap(TinycastHistoryEntry(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_793_290_000),
                rawText: "Synthetic record", enhancedText: nil, duration: 1, status: "completed"))
            try builder.append(entry)
        }
        return builder.encodedSnapshot()
    }

    func testNewSnapshotIsPrivateAndReplacedAtomicallyAfterDeletion() throws {
        try withDirectory { root in
            let writer = TinycastHistorySnapshotWriter(baseDirectory: root)
            let first = try snapshot(empty: false)
            try writer.publish(first)
            XCTAssertEqual(try Data(contentsOf: writer.snapshotURL), first)
            let attributes = try FileManager.default.attributesOfItem(atPath: writer.snapshotURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let directories = [root.appendingPathComponent("io.forit.dictate"),
                               root.appendingPathComponent("io.forit.dictate/Integrations"), writer.directory]
            for directory in directories {
                let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o700)
            }
            let empty = try snapshot(empty: true)
            try writer.publish(empty)
            XCTAssertEqual(try Data(contentsOf: writer.snapshotURL), empty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: writer.directory.path), ["history-v1.json"])
        }
    }

    func testWriteFailureInvalidatesOlderSnapshotAndRemovesPartialTemporaryFile() throws {
        enum SyntheticError: Error { case interrupted }
        try withDirectory { root in
            let normal = TinycastHistorySnapshotWriter(baseDirectory: root)
            try normal.publish(snapshot(empty: false))
            let failing = TinycastHistorySnapshotWriter(baseDirectory: root) { descriptor, _ in
                let partial = Data("partial synthetic data".utf8)
                _ = partial.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                throw SyntheticError.interrupted
            }
            XCTAssertThrowsError(try failing.publish(snapshot(empty: true)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: normal.snapshotURL.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: normal.directory.path).isEmpty)
        }
    }

    func testExistingDirectoryPermissionsAreNotChanged() throws {
        try withDirectory { root in
            let appDirectory = root.appendingPathComponent("io.forit.dictate")
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o750])
            let before = try FileManager.default.attributesOfItem(atPath: appDirectory.path)[.posixPermissions] as? NSNumber
            try TinycastHistorySnapshotWriter(baseDirectory: root).publish(snapshot(empty: true))
            let after = try FileManager.default.attributesOfItem(atPath: appDirectory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(before, after)
        }
    }

    func testSymlinkedIntegrationDirectoryIsRefusedWithoutWritingOutsideIt() throws {
        try withDirectory { root in
            let normal = TinycastHistorySnapshotWriter(baseDirectory: root)
            try normal.publish(snapshot(empty: true))
            try FileManager.default.removeItem(at: normal.directory)
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: normal.directory, withDestinationURL: outside)
            XCTAssertThrowsError(try normal.publish(snapshot(empty: false)))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }
}
