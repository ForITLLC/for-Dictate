import Foundation
import OSLog
import SwiftData

/// One app-lifetime owner, independent of window visibility and the recording pipeline.
@MainActor
final class TinycastHistoryExporter {
    static let shared = TinycastHistoryExporter()

    private var observedContainer: ModelContainer?
    private var observer: NSObjectProtocol?
    private var workerTask: Task<TinycastHistorySnapshotWorker, Never>?
    private var refreshTask: Task<Void, Never>?
    private let baseDirectory: URL
    private let debounceInterval: Duration
    private let logger = Logger(subsystem: "io.forit.dictate", category: "TinycastHistory")

    init(baseDirectory: URL? = nil, debounceInterval: Duration = .milliseconds(500)) {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.debounceInterval = debounceInterval
    }

    func start(container: ModelContainer) {
        guard observedContainer !== container else { return }
        refreshTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observedContainer = container
        let observedIdentity = ObjectIdentifier(container)
        workerTask = Task.detached(priority: .utility) {
            TinycastHistorySnapshotWorker(modelContainer: container)
        }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            [weak self] notification in
            // The notification is delivered on the saving context's executor. Read its container
            // here, pass only identity to the main actor, and accept every context in this container.
            guard let context = notification.object as? ModelContext,
                ObjectIdentifier(context.container) == observedIdentity
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observedContainer.map({ ObjectIdentifier($0) }) == observedIdentity else { return }
                self.scheduleRefresh()
            }
        }
        // Export existing history even when the app starts as a menu-bar-only app.
        scheduleRefresh()
    }

    /// Tests and explicit lifecycle owners can await in-flight file work before removing their
    /// owned store. Production retains the shared owner for the app's lifetime.
    func stop() async {
        let pendingRefresh = refreshTask
        let pendingWorker = workerTask
        pendingRefresh?.cancel()
        refreshTask = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedContainer = nil
        workerTask?.cancel()
        workerTask = nil
        await pendingRefresh?.value
        if let pendingWorker {
            let worker = await pendingWorker.value
            await worker.waitForIdle()
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard let workerTask else { return }
        let interval = debounceInterval
        let baseDirectory = self.baseDirectory
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            let worker = await workerTask.value
            guard !Task.isCancelled else { return }
            let result = await worker.refresh(baseDirectory: baseDirectory)
            guard !Task.isCancelled else { return }
            if case .unavailable = result {
                // Do not log transcript text, paths, prompts, model errors or underlying filesystem errors.
                self?.logger.warning("Tinycast history is unavailable; no successful refresh is claimed.")
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

private enum TinycastHistoryRefreshResult: Sendable { case published, unavailable, superseded }

/// Constructed on a utility task so fetching/encoding/disk I/O never runs on the recording actor.
@ModelActor
private actor TinycastHistorySnapshotWorker {
    /// Actor serialization waits for a synchronous refresh already doing disk I/O to finish.
    func waitForIdle() {}

    func refresh(baseDirectory: URL) -> TinycastHistoryRefreshResult {
        let writer = TinycastHistorySnapshotWriter(baseDirectory: baseDirectory)
        do {
            // A new context sees committed edits/deletions from every saving context, rather
            // than re-exporting cached models or another context's unsaved recording state.
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            var builder = try TinycastHistorySnapshotBuilder(updatedAt: Date())
            let completed = TranscriptionStatus.completed.rawValue
            var descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate { $0.transcriptionStatus == nil || $0.transcriptionStatus == completed },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            descriptor.includePendingChanges = false
            descriptor.fetchLimit = 16
            descriptor.fetchOffset = 0
            var finished = false
            while !finished {
                try Task.checkCancellation()
                let page = try context.fetch(descriptor)
                if page.isEmpty { break }
                for transcription in page {
                    if let boundary = builder.oldestRequiredTimestamp,
                        transcription.timestamp < boundary.addingTimeInterval(-0.001) {
                        finished = true
                        break
                    }
                    if let entry = TinycastHistoryEntry(
                        id: transcription.id, timestamp: transcription.timestamp, rawText: transcription.text,
                        enhancedText: transcription.enhancedText, duration: transcription.duration,
                        status: transcription.transcriptionStatus) {
                        try builder.append(entry)
                    }
                }
                descriptor.fetchOffset += page.count
                if page.count < 16 { break }
            }
            let snapshot = builder.encodedSnapshot()
            try Task.checkCancellation()
            try writer.publish(snapshot)
            return .published
        } catch is CancellationError {
            return .superseded // The next committed-save refresh supersedes this work.
        } catch {
            // A fetch or encoding error also invalidates the old snapshot. A permission failure
            // can prevent removal too; neither case is ever reported as publication success.
            try? writer.invalidate()
            return .unavailable
        }
    }
}
