import Combine
import Foundation

/// Dictate owns this optional Support session. Browser acquisition stays with
/// Common and the app's presentation coordinator; no browser or provider is
/// opened by restore/refresh. Publication never depends on a recording request.
@MainActor
final class CompanyDictionaryClient: ObservableObject {
    @Published private(set) var snapshot: CompanyDictionarySnapshot?
    @Published private(set) var profile: CompanyDictionaryProfile?
    @Published private(set) var isBusy = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var needsSignIn = true
    @Published private(set) var isStale = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var revocationWarning: String?

    var statusText: String {
        let primary: String
        if let message { primary = message }
        else if isBusy { primary = String(localized: "Checking company dictionary…") }
        else if let snapshot { primary = String(localized: "\(snapshot.total) company terms available") }
        else if isSignedIn { primary = String(localized: "Company dictionary has not been loaded.") }
        else { primary = String(localized: "Sign in to use your company dictionary.") }
        if let revocationWarning, revocationWarning != primary { return primary + "\n" + revocationWarning }
        return primary
    }

    private let transport: any CompanyDictionaryTransport
    private let store: any CompanyDictionaryStore
    private let now: @Sendable () -> Date
    private let onPublication: @MainActor (CompanyDictionarySnapshot?, Date?) -> Void
    private let maintenanceEnabled: Bool
    private var credential: CompanyDictionaryCredential?
    private var sessionID = UUID()
    private var storageTransitionOrder: UInt64 = 0
    private var activeAttempt: UUID?
    private var restored = false
    private var accessDenied = false
    private var refreshTask: (id: UUID, task: Task<Void, Never>)?
    private var expiryTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var nextAttemptAt: Date?
    private var serverRetryAt: Date?
    private var failureCount = 0
    private var restorationWork: RestorationWork?

    /// Shared only by overlapping startup/retirement calls. It retains no key
    /// after these calls finish; the bounded revocation task returns only Bool.
    @MainActor
    private final class RestorationWork {
        let task: Task<CompanyDictionaryRestoration, Error>
        var retiring = false
        var revocation: (sessionID: UUID, task: Task<Bool, Never>)?
        init(task: Task<CompanyDictionaryRestoration, Error>) { self.task = task }
    }

    convenience init(onPublication: @escaping @MainActor (CompanyDictionarySnapshot?, Date?) -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.forit.dictate"
        self.init(transport: SupportCompanyDictionaryTransport(),
                  store: FileCompanyDictionaryStore(directory: FileCompanyDictionaryStore.standardDirectory(bundleID: bundleID),
                                                    credentials: CompanyDictionaryKeychainStore(bundleID: bundleID)),
                  onPublication: onPublication)
    }

    init(transport: any CompanyDictionaryTransport, store: any CompanyDictionaryStore,
         now: @escaping @Sendable () -> Date = { Date() }, maintenanceEnabled: Bool = true,
         onPublication: @escaping @MainActor (CompanyDictionarySnapshot?, Date?) -> Void) {
        self.transport = transport
        self.store = store
        self.now = now
        self.maintenanceEnabled = maintenanceEnabled
        self.onPublication = onPublication
    }

    deinit {
        refreshTask?.task.cancel()
        expiryTask?.cancel()
        maintenanceTask?.cancel()
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        let operation = sessionID
        let store = store
        let work = RestorationWork(task: Task { try await store.restore() })
        restorationWork = work
        defer {
            if restorationWork === work && !work.retiring { restorationWork = nil }
        }
        do {
            let result = try await work.task.value
            guard sessionID == operation else { return }
            guard let candidate = result.credential else { return }
            guard CompanyDictionaryCredential.validKey(candidate.key), candidate.expiresAt > now() else {
                let next = UUID()
                let durable = await retireCurrentSession(nextID: next, revoke: false)
                guard sessionID == next else { return }
                if durable { message = String(localized: "Your sign-in ended. Sign in again to use company terms.") }
                return
            }
            sessionID = candidate.sessionID
            credential = candidate
            profile = candidate.profile
            isSignedIn = true
            needsSignIn = false
            accessDenied = result.accessDenied
            checkedAt = result.checkedAt
            if !accessDenied, candidate.profile != nil, let cached = result.snapshot {
                snapshot = cached
                isStale = true
                onPublication(cached, candidate.expiresAt)
            }
            scheduleTimers()
            if accessDenied {
                message = String(localized: "This account can't read the company dictionary. Try checking again or sign out.")
            } else {
                await refresh(force: true)
            }
        } catch {
            guard sessionID == operation else { return }
            // Keep disk/Keychain material on unavailable storage. Nothing is
            // published until the known lifecycle and credential can be read.
            message = String(localized: "Company sign-in storage could not be read. Your personal and local vocabulary are still available.")
            restored = false
        }
    }

    /// Called before opening Common's browser flow. Changing accounts is a real
    /// local sign-out first; cancel does not bring the previous account back.
    func beginConnection() async -> UUID? {
        restored = true
        let attempt = UUID()
        guard await retireCurrentSession(nextID: attempt, revoke: true), sessionID == attempt else { return nil }
        activeAttempt = attempt
        isBusy = true
        message = nil
        return attempt
    }

    func cancelConnection(attempt: UUID) async {
        // activeAttempt is consumed before mint starts. Cancellation must still
        // fence that in-flight mint (and revoke a key if it already arrived).
        guard sessionID == attempt else { return }
        _ = await retireCurrentSession(nextID: UUID(), revoke: true)
    }

    func finishConnection(idToken: String, attempt: UUID) async {
        guard activeAttempt == attempt, sessionID == attempt else { return }
        guard !Task.isCancelled else { await cancelConnection(attempt: attempt); return }
        // Consume the attempt before sending: this token is never automatically
        // retried, even if cancellation or an uncertain response follows.
        activeAttempt = nil
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let body = try JSONSerialization.data(withJSONObject: ["platform": "macos", "appVersion": String(version.prefix(40))])
            let response = try await transport.send(.init(endpoint: .mint, credential: idToken, body: body))
            guard response.body.count <= CompanyDictionaryRequest.Endpoint.mint.maximumBytes,
                  response.status == 201,
                  let mint = try? JSONDecoder().decode(Mint.self, from: response.body),
                  CompanyDictionaryCredential.validKey(mint.key)
            else {
                guard sessionID == attempt else { return }
                if Task.isCancelled { await cancelConnection(attempt: attempt); return }
                isBusy = false
                message = String(localized: "Company sign-in did not finish. Start a fresh sign-in to try again.")
                return
            }
            guard let value = mint.expiresAt, let expiry = Self.parseDate(value), expiry > now(),
                  expiry.timeIntervalSince(now()) <= 31 * 24 * 60 * 60 else {
                // A known returned key is still ours to revoke even when its
                // expiry metadata is missing/malformed. Never replay the token.
                _ = await revoke(.init(sessionID: attempt, key: mint.key, expiresAt: .distantPast, profile: nil))
                guard sessionID == attempt else { return }
                if Task.isCancelled { await cancelConnection(attempt: attempt); return }
                isBusy = false
                message = String(localized: "Company sign-in returned an invalid expiry. Start a fresh sign-in to try again.")
                return
            }
            let candidate = CompanyDictionaryCredential(sessionID: attempt, key: mint.key, expiresAt: expiry, profile: nil)
            guard sessionID == attempt, !Task.isCancelled else {
                await abandonMint(candidate, attempt: attempt)
                return
            }
            do { try await store.saveCredential(candidate) }
            catch {
                if sessionID != attempt || Task.isCancelled {
                    await abandonMint(candidate, attempt: attempt)
                    return
                }
                _ = await revoke(candidate)
                guard sessionID == attempt else { return }
                if Task.isCancelled {
                    _ = await retireCurrentSession(nextID: UUID(), revoke: false)
                    return
                }
                isBusy = false
                message = String(localized: "Company sign-in could not be saved on this Mac. Start a fresh sign-in after storage is available.")
                return
            }
            guard sessionID == attempt, !Task.isCancelled else {
                await abandonMint(candidate, attempt: attempt)
                return
            }
            credential = candidate
            isSignedIn = true
            needsSignIn = false
            isBusy = false
            scheduleTimers()
            await refresh(force: true)
        } catch {
            guard sessionID == attempt else { return }
            if Task.isCancelled { await cancelConnection(attempt: attempt); return }
            isBusy = false
            message = String(localized: "Company sign-in could not be confirmed. Start a fresh sign-in; the previous sign-in will not be sent again.")
        }
    }

    func signOut() async { _ = await retireCurrentSession(nextID: UUID(), revoke: true) }

    func refresh(force: Bool = false) async {
        guard let current = credential else {
            // Retry a temporarily locked/unavailable startup store on a normal
            // foreground/check event, without opening another browser flow.
            if !restored && !isBusy { await restore() }
            return
        }
        if current.expiresAt <= now() { await enforceExpiry(); return }
        if accessDenied && !force { return }
        if let pending = refreshTask { await pending.task.value; return }
        // A deliberate check bypasses our age/exponential throttle, not a
        // Retry-After explicitly supplied by Support.
        if let serverRetryAt, now() < serverRetryAt {
            message = String(localized: "Support asked us to wait before checking the company dictionary again.")
            return
        }
        if !force {
            if let nextAttemptAt, now() < nextAttemptAt { return }
            if failureCount == 0, let checkedAt, now().timeIntervalSince(checkedAt) < 15 * 60 { return }
        }
        let operation = sessionID
        let flight = UUID()
        isBusy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh(sessionID: operation)
        }
        refreshTask = (flight, task)
        await task.value
        guard refreshTask?.id == flight else { return }
        refreshTask = nil
        if sessionID == operation { isBusy = false }
    }

    /// An expiry task invokes this independently of network refresh. App wake
    /// also calls refresh, and the resolver guards captured snapshot consumption.
    func enforceExpiry() async {
        guard let credential, credential.expiresAt <= now() else { return }
        let next = UUID()
        let durable = await retireCurrentSession(nextID: next, revoke: false)
        guard sessionID == next else { return }
        if durable { message = String(localized: "Your sign-in ended. Sign in again to use company terms.") }
    }

    private func performRefresh(sessionID operation: UUID) async {
        guard let current = currentCredential(operation) else { return }
        do {
            if current.profile == nil {
                let identityResponse = try await transport.send(.init(endpoint: .identity, credential: current.key))
                guard currentCredential(operation) != nil else { return }
                if await handleDenial(identityResponse, operation: operation) { return }
                guard identityResponse.status == 200,
                      identityResponse.body.count <= CompanyDictionaryRequest.Endpoint.identity.maximumBytes,
                      let identity = try? JSONDecoder().decode(Identity.self, from: identityResponse.body),
                      identity.workspace.mode == "staff"
                else { recordFailure(operation: operation, response: identityResponse); return }
                let profile = CompanyDictionaryProfile(userID: identity.userId.lowercased(),
                                                       name: identity.name ?? identity.email ?? "ForIT account",
                                                       email: identity.email ?? "")
                guard FileCompanyDictionaryStore.validProfile(profile) else {
                    recordFailure(operation: operation)
                    return
                }
                try await store.bindProfile(profile, sessionID: operation)
                guard currentCredential(operation) != nil else { return }
                self.profile = profile
                credential?.profile = profile
            }

            var validator = snapshot?.version
            for pass in 0..<2 {
                guard let bound = currentCredential(operation), bound.profile != nil else { return }
                let response = try await transport.send(.init(endpoint: .dictionary, credential: bound.key, etag: validator))
                guard currentCredential(operation) != nil else { return }
                if await handleDenial(response, operation: operation) { return }
                if response.status == 304 {
                    if let cached = snapshot, let validator, cached.version == validator,
                       response.header("ETag") == validator, !accessDenied {
                        let date = now()
                        checkedAt = date
                        isStale = false
                        failureCount = 0
                        nextAttemptAt = nil
                        serverRetryAt = nil
                        message = nil
                        do { try await store.markChecked(date, version: validator, sessionID: operation) }
                        catch {
                            guard currentCredential(operation) != nil else { return }
                            message = String(localized: "Company terms were checked, but the offline check time could not be saved.")
                        }
                        return
                    }
                    if pass == 0 { validator = nil; continue }
                    recordFailure(operation: operation)
                    return
                }
                guard response.status == 200 else {
                    recordFailure(operation: operation, response: response)
                    return
                }
                guard response.body.count <= CompanyDictionaryRequest.Endpoint.dictionary.maximumBytes else {
                    recordFailure(operation: operation)
                    return
                }
                let candidate: CompanyDictionarySnapshot
                do {
                    // A complete legal snapshot can be several megabytes. Keep
                    // its decoding/field validation off the UI executor too.
                    candidate = try await Task.detached(priority: .utility) {
                        try FileCompanyDictionaryStore.decodeReadSnapshot(response.body)
                    }.value
                } catch {
                    guard currentCredential(operation) != nil else { return }
                    recordFailure(operation: operation)
                    return
                }
                guard currentCredential(operation) != nil else { return }
                guard response.header("ETag") == candidate.version,
                      CompanyDictionaryRequest.isStrongETag(candidate.version) else {
                    recordFailure(operation: operation)
                    return
                }
                let date = now()
                // Publish a complete validated replacement immediately, including
                // empty results; persistence failure never keeps retired terms in
                // this process's recognition cache.
                snapshot = candidate
                checkedAt = date
                isStale = false
                accessDenied = false
                failureCount = 0
                nextAttemptAt = nil
                serverRetryAt = nil
                message = nil
                onPublication(candidate, bound.expiresAt)
                do {
                    try await store.saveSnapshot(response.body, snapshot: candidate, checkedAt: date, sessionID: operation)
                } catch {
                    guard currentCredential(operation) != nil else { return }
                    if case CompanyDictionaryStoreError.durableInvalidationFailed = error {
                        message = String(localized: "Using the latest company terms for this run. The older offline copy could not be disabled; storage needs repair before offline use is reliable.")
                    } else {
                        message = String(localized: "Using the latest company terms for this run. The offline copy could not be saved.")
                    }
                }
                return
            }
        } catch {
            guard currentCredential(operation) != nil else { return }
            recordFailure(operation: operation)
        }
    }

    private func handleDenial(_ response: CompanyDictionaryHTTPResponse, operation: UUID) async -> Bool {
        guard currentCredential(operation) != nil else { return true }
        if response.status == 401 {
            let next = UUID()
            let durable = await retireCurrentSession(nextID: next, revoke: false)
            guard sessionID == next else { return true }
            if durable { message = String(localized: "Your sign-in ended. Sign in again to use company terms.") }
            return true
        }
        if response.status == 403 {
            accessDenied = true
            snapshot = nil
            checkedAt = nil
            isStale = false
            failureCount = 0
            nextAttemptAt = nil
            serverRetryAt = nil
            onPublication(nil, nil)
            message = String(localized: "This account can't read the company dictionary. Try checking again or sign out.")
            do { try await store.denyAccess(sessionID: operation) }
            catch {
                guard currentCredential(operation) != nil else { return true }
                message = String(localized: "Company access was refused. The offline copy could not be fully removed; storage needs repair.")
            }
            return true
        }
        return false
    }

    private func currentCredential(_ operation: UUID) -> CompanyDictionaryCredential? {
        guard sessionID == operation, let credential, credential.sessionID == operation,
              credential.expiresAt > now() else { return nil }
        return credential
    }

    @discardableResult
    private func retireCurrentSession(nextID: UUID, revoke shouldRevoke: Bool) async -> Bool {
        var previous = credential
        let pendingRestoration = restorationWork
        pendingRestoration?.retiring = true
        storageTransitionOrder += 1
        let transition = storageTransitionOrder
        restored = true
        sessionID = nextID
        activeAttempt = nil
        credential = nil
        snapshot = nil
        profile = nil
        checkedAt = nil
        accessDenied = false
        isStale = false
        isSignedIn = false
        needsSignIn = true
        failureCount = 0
        nextAttemptAt = nil
        serverRetryAt = nil
        refreshTask?.task.cancel()
        refreshTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        isBusy = true
        // This happens before any Keychain, filesystem or remote operation.
        onPublication(nil, nil)
        // The startup read may already hold the old key without having returned
        // it to the UI executor. Await only after local exclusion, and before
        // deletion, so it can be revoked instead of silently orphaned.
        var unknownPreviousSession = false
        if let pendingRestoration {
            do {
                let result = try await pendingRestoration.task.value
                if previous == nil { previous = result.credential }
            } catch {
                unknownPreviousSession = previous == nil
            }
        }
        var durable = true
        do { try await store.reset(to: nextID, order: transition) }
        catch { durable = false }
        let revoked: Bool
        if shouldRevoke, let previous, previous.expiresAt > now() {
            if let pendingRestoration {
                // Two retirements can await the same startup read. They share
                // exactly one cleanup attempt for the returned old session.
                if pendingRestoration.revocation == nil {
                    pendingRestoration.revocation = (previous.sessionID, startRevocation(previous))
                }
                if let shared = pendingRestoration.revocation, shared.sessionID == previous.sessionID {
                    revoked = await shared.task.value
                } else { revoked = await revoke(previous) }
            } else { revoked = await revoke(previous) }
        } else { revoked = !(shouldRevoke && unknownPreviousSession) }
        if restorationWork === pendingRestoration { restorationWork = nil }
        guard sessionID == nextID else { return false }
        isBusy = false
        if !revoked {
            // Retain this secret-free warning across a replacement sign-in: a
            // successful new session says nothing about revoking the old one.
            revocationWarning = String(localized: "Server revocation of the previous sign-in could not be confirmed; it ends by its server expiry.")
        }
        if !durable {
            message = String(localized: "Company terms are off for this run, but sign-out could not be saved completely. Storage needs repair before durable sign-out can be confirmed.")
        } else if !revoked {
            message = revocationWarning
        } else { message = nil }
        return durable
    }

    private func revoke(_ candidate: CompanyDictionaryCredential) async -> Bool {
        await startRevocation(candidate).value
    }

    private func startRevocation(_ candidate: CompanyDictionaryCredential) -> Task<Bool, Never> {
        let transport = transport
        let request = CompanyDictionaryRequest(endpoint: .revoke, credential: candidate.key)
        // A late successful mint can arrive after its browser task was cancelled.
        // Give this one bounded cleanup attempt its own cancellation scope; no
        // durable queue, token replay or automatic mint is created.
        return Task.detached(priority: .utility) {
            do { return try await transport.send(request).status == 204 }
            catch { return false }
        }
    }

    private func abandonMint(_ candidate: CompanyDictionaryCredential, attempt: UUID) async {
        if sessionID == attempt { _ = await retireCurrentSession(nextID: UUID(), revoke: false) }
        _ = await revoke(candidate)
    }

    private func recordFailure(operation: UUID, response: CompanyDictionaryHTTPResponse? = nil) {
        guard currentCredential(operation) != nil else { return }
        isStale = snapshot != nil
        failureCount = min(failureCount + 1, 8)
        let delay = min(6 * 60 * 60, 5 * 60 * pow(2, Double(failureCount - 1)))
        let retryAfter = response?.header("Retry-After").flatMap { Self.retryDelay($0, relativeTo: now()) } ?? 0
        serverRetryAt = retryAfter > 0 ? now().addingTimeInterval(retryAfter) : nil
        nextAttemptAt = now().addingTimeInterval(max(delay, retryAfter))
        if response?.status == 400 { nextAttemptAt = .distantFuture }
        message = snapshot == nil
            ? String(localized: "The company dictionary is unavailable. Your personal and local vocabulary are still available.")
            : String(localized: "The company dictionary could not be checked. Using the last valid copy until this sign-in expires.")
    }

    private func scheduleTimers() {
        expiryTask?.cancel()
        maintenanceTask?.cancel()
        guard let current = credential else { return }
        let clock = now
        let operation = current.sessionID
        let expiry = current.expiresAt
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = expiry.timeIntervalSince(clock())
                if remaining <= 0 {
                    guard self?.sessionID == operation else { return }
                    await self?.enforceExpiry()
                    return
                }
                do { try await Task.sleep(for: .seconds(min(remaining, 60 * 60))) }
                catch { return }
            }
        }
        guard maintenanceEnabled else { return }
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30 * 60)) }
                catch { return }
                guard let self, self.sessionID == operation, self.credential != nil else { return }
                if self.accessDenied { continue }
                if self.failureCount > 0 || self.checkedAt.map({ clock().timeIntervalSince($0) >= 6 * 60 * 60 }) ?? true {
                    await self.refresh()
                }
            }
        }
    }

    private struct Mint: Decodable {
        let key: String
        let expiresAt: String?
        private enum CodingKeys: String, CodingKey { case key, expiresAt }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            key = try values.decode(String.self, forKey: .key)
            expiresAt = try? values.decode(String.self, forKey: .expiresAt)
        }
    }
    private struct Identity: Decodable {
        struct Workspace: Decodable { let mode: String }
        let userId: String
        let name: String?
        let email: String?
        let workspace: Workspace
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func retryDelay(_ value: String, relativeTo now: Date) -> TimeInterval? {
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return min(seconds, 24 * 60 * 60) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(24 * 60 * 60, max(0, date.timeIntervalSince(now)))
    }
}
