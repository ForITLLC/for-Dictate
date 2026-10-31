import Darwin
import Foundation

/// Cooperating apps must hold this sibling advisory lock across their entire
/// catalog read/compare/atomic-replace operation. Keep the lock file in place so
/// every writer locks the same inode. External editors that ignore this protocol
/// cannot be protected by an advisory lock; reload after their atomic updates.
enum SharedVocabularyCatalogLock {
    static func withExclusiveAccess<T>(at catalogURL: URL, _ body: () throws -> T) throws -> T {
        let directory = catalogURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = catalogURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw SharedVocabularyError.lockUnavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw SharedVocabularyError.catalogBusy }
            throw SharedVocabularyError.lockUnavailable
        }
        defer { _ = Darwin.flock(descriptor, LOCK_UN) }
        return try body()
    }
}
