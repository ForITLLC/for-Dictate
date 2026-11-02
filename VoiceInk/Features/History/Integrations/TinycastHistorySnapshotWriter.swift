import Darwin
import Foundation

enum TinycastHistoryWriteError: Error { case invalidDirectory, oversizedSnapshot, writeFailed, invalidationFailed }

/// Creates only the integration's new directories/files privately. Existing permissions and
/// ACLs are never modified. Rename publishes either the complete previous or complete new file.
struct TinycastHistorySnapshotWriter {
    let baseDirectory: URL
    private let writeContents: (Int32, Data) throws -> Void

    init(baseDirectory: URL, writeContents: ((Int32, Data) throws -> Void)? = nil) {
        self.baseDirectory = baseDirectory
        self.writeContents = writeContents ?? Self.writeAll
    }

    var directory: URL {
        baseDirectory.appendingPathComponent("io.forit.dictate", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
            .appendingPathComponent("Tinycast", isDirectory: true)
    }

    var snapshotURL: URL { directory.appendingPathComponent("history-v1.json") }

    func publish(_ data: Data) throws {
        try prepareDirectory()
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            Darwin.unlink(temporary.path)
        }
        do {
            guard data.count <= TinycastHistorySnapshotBuilder.maximumEncodedBytes else {
                throw TinycastHistoryWriteError.oversizedSnapshot
            }
            descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else { throw TinycastHistoryWriteError.writeFailed }
            try writeContents(descriptor, data)
            guard Darwin.fsync(descriptor) == 0 else { throw TinycastHistoryWriteError.writeFailed }
            guard Darwin.rename(temporary.path, snapshotURL.path) == 0 else {
                throw TinycastHistoryWriteError.writeFailed
            }
        } catch {
            // A failed refresh must not leave an older successful export masquerading as current.
            // If the filesystem also refuses removal, propagate that distinct unavailable state.
            try invalidate()
            throw error
        }
    }

    func invalidate() throws {
        // Refuse to follow a replaced app-owned directory into an unrelated location.
        try verifyDirectoryChain()
        if Darwin.unlink(snapshotURL.path) != 0, errno != ENOENT {
            throw TinycastHistoryWriteError.invalidationFailed
        }
    }

    private func prepareDirectory() throws {
        var url = baseDirectory
        for component in ["io.forit.dictate", "Integrations", "Tinycast"] {
            url.appendPathComponent(component, isDirectory: true)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw TinycastHistoryWriteError.invalidDirectory
                }
            } catch let error as NSError where Self.isMissingPath(error) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            }
        }
        try verifyDirectoryChain()
    }

    private func verifyDirectoryChain() throws {
        var url = baseDirectory
        for component in ["io.forit.dictate", "Integrations", "Tinycast"] {
            url.appendPathComponent(component, isDirectory: true)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw TinycastHistoryWriteError.invalidDirectory
                }
            } catch let error as NSError where Self.isMissingPath(error) {
                return // There cannot be a snapshot below a missing parent directory.
            }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TinycastHistoryWriteError.writeFailed }
                offset += count
            }
        }
    }

    private static func isMissingPath(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
