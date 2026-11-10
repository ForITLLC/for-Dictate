import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class CompanyDictionaryClientTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let userID = "00000000-0000-0000-0000-000000000007"

    private func dictionary(_ terms: [String] = ["SyntheticName"], version: String = "\"v1-read-active\"",
                            canEdit: Bool = false) throws -> CompanyDictionaryHTTPResponse {
        let rows = terms.enumerated().map { index, term in
            ["term_id": String(format: "00000000-0000-0000-0000-%012d", index + 1),
             "canonical_spelling": term, "spoken_forms": ["synthetic alias"], "meaning": "Synthetic fixture only",
             "kind": "term", "is_active": true, "revision": 1,
             "updated_at": "2026-11-03T04:02:08.765Z"] as [String: Any]
        }
        let body = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "companyId": CompanyDictionarySnapshot.supportCompanyID, "version": version,
            "terms": rows, "total": rows.count, "updated_at": "2026-11-03T04:02:08.765Z", "canEdit": canEdit])
        return .init(status: 200, headers: ["ETag": version], body: body)
    }

    private func mint(_ character: Character = "a", expiry: Date? = nil) throws -> CompanyDictionaryHTTPResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = try JSONSerialization.data(withJSONObject: ["key": "fsak_" + String(repeating: String(character), count: 43),
            "expiresAt": formatter.string(from: expiry ?? date.addingTimeInterval(3_600))])
        return .init(status: 201, headers: [:], body: body)
    }

    private func identity(_ user: String? = nil) throws -> CompanyDictionaryHTTPResponse {
        .init(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: [
            "userId": user ?? userID, "name": "Synthetic account", "email": "synthetic@example.invalid",
            "workspace": ["mode": "staff"]]))
    }

    private func client(_ transport: SyntheticCompanyTransport, store: SyntheticCompanyStore,
                        clock: SyntheticCompanyClock? = nil,
                        publish: @escaping @MainActor (CompanyDictionarySnapshot?, Date?) -> Void = { _, _ in }) -> CompanyDictionaryClient {
        let fixedDate = date
        return .init(transport: transport, store: store, now: { clock?.now ?? fixedDate },
                     maintenanceEnabled: false, onPublication: publish)
    }

    private func connect(_ client: CompanyDictionaryClient) async throws -> UUID {
        let candidate = await client.beginConnection()
        let attempt = try XCTUnwrap(candidate)
        await client.finishConnection(idToken: "synthetic-id-token", attempt: attempt)
        return attempt
    }

    func testSuccessfulConnectionMintsOnceAndPublishesServerBoundSnapshot() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary())])
        let store = SyntheticCompanyStore()
        var publications: [CompanyDictionarySnapshot?] = []
        let subject = client(transport, store: store) { value, _ in publications.append(value) }
        let attempt = try await connect(subject)
        await subject.finishConnection(idToken: "synthetic-id-token", attempt: attempt)
        XCTAssertTrue(subject.isSignedIn)
        XCTAssertFalse(subject.needsSignIn)
        XCTAssertEqual(subject.profile?.userID, userID)
        XCTAssertEqual(publications.last.flatMap { $0 }?.terms.first?.canonicalSpelling, "SyntheticName")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.endpoint.method), ["POST", "GET", "GET"])
        XCTAssertEqual(requests.filter { $0.endpoint.method == "POST" }.count, 1)
    }

    func testUncertainMintIsNotReplayedByFinishingAttemptAgain() async throws {
        let transport = SyntheticCompanyTransport([.failure])
        let subject = client(transport, store: SyntheticCompanyStore())
        let attempt = try await connect(subject)
        await subject.finishConnection(idToken: "synthetic-id-token", attempt: attempt)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertTrue(subject.needsSignIn)
        XCTAssertNotNil(subject.message)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testKnownKeyWithMalformedExpiryIsRevokedWithoutTokenReplay() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["key": "fsak_" + String(repeating: "a", count: 43), "expiresAt": 17])
        let transport = SyntheticCompanyTransport([.response(.init(status: 201, headers: [:], body: body)),
            .response(.init(status: 204, headers: [:], body: Data()))])
        let subject = client(transport, store: SyntheticCompanyStore())
        let attempt = try await connect(subject)
        await subject.finishConnection(idToken: "synthetic-id-token", attempt: attempt)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertNil(subject.snapshot)
        let methods = await transport.requests.map(\.endpoint.method)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func testSavedProvisionalSessionRetriesIdentityWithoutMintingAgain() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .failure,
            .response(try identity()), .response(try dictionary())])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        XCTAssertTrue(subject.isSignedIn)
        XCTAssertNil(subject.profile)
        await subject.refresh(force: true)
        XCTAssertEqual(subject.profile?.userID, userID)
        XCTAssertNotNil(subject.snapshot)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.endpoint.method == "POST" }.count, 1)
        XCTAssertEqual(requests.map(\.endpoint.path), ["/api/app/v1/session", "/api/app/v1/me", "/api/app/v1/me", "/api/v1/company-dictionary"])
    }

    func testServerIdentityWithControlSuffixIsNotBound() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity(userID + "\n"))])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        XCTAssertNil(subject.profile)
        XCTAssertNil(subject.snapshot)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.endpoint.path == "/api/v1/company-dictionary" })
    }

    func testCredentialSaveFailureRevokesKnownNewKeyWithoutActivatingSession() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(.init(status: 204, headers: [:], body: Data()))])
        let store = SyntheticCompanyStore()
        await store.setCredentialFailure(true)
        let subject = client(transport, store: store)
        _ = try await connect(subject)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertNil(subject.snapshot)
        let methods = await transport.requests.map(\.endpoint.method)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func testCancelAfterMintWasSentFencesLateKeyAndRevokesIt() async throws {
        let transport = SyntheticCompanyTransport([.blocked, .response(.init(status: 204, headers: [:], body: Data()))])
        let subject = client(transport, store: SyntheticCompanyStore())
        let candidate = await subject.beginConnection()
        let attempt = try XCTUnwrap(candidate)
        let mintTask = Task { await subject.finishConnection(idToken: "synthetic-id-token", attempt: attempt) }
        var blocked = false
        for _ in 0..<1_000 {
            if await transport.isBlocked { blocked = true; break }
            await Task.yield()
        }
        guard blocked else { mintTask.cancel(); XCTFail("Synthetic mint did not reach its controlled barrier."); return }
        mintTask.cancel()
        await subject.cancelConnection(attempt: attempt)
        await transport.release(try mint())
        await mintTask.value
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertNil(subject.snapshot)
        let methods = await transport.requests.map(\.endpoint.method)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func testCanceledCallerCannotPublishLateMintBeforeExplicitCancelCallback() async throws {
        let transport = SyntheticCompanyTransport([.blocked, .response(.init(status: 204, headers: [:], body: Data()))])
        let subject = client(transport, store: SyntheticCompanyStore())
        let value = await subject.beginConnection()
        let attempt = try XCTUnwrap(value)
        let mintTask = Task { await subject.finishConnection(idToken: "synthetic-id-token", attempt: attempt) }
        var blocked = false
        for _ in 0..<1_000 {
            if await transport.isBlocked { blocked = true; break }
            await Task.yield()
        }
        guard blocked else { mintTask.cancel(); XCTFail("Synthetic mint did not reach its controlled barrier."); return }
        mintTask.cancel()
        await transport.release(try mint())
        await mintTask.value
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertNil(subject.snapshot)
        let methods = await transport.requests.map(\.endpoint.method)
        XCTAssertEqual(methods, ["POST", "DELETE"])
    }

    func test401ClearsCurrentSessionAndRequiresFreshSignIn() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(.init(status: 401, headers: [:], body: Data()))])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        await subject.refresh(force: true)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertTrue(subject.needsSignIn)
        XCTAssertNil(subject.snapshot)
        XCTAssertNil(subject.profile)
    }

    func testCompleteEmptyReplacementIsPublishedWhenOfflinePersistenceFails() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(try dictionary([], version: "\"v2-read-active\""))])
        let store = SyntheticCompanyStore()
        let subject = client(transport, store: store)
        _ = try await connect(subject)
        await store.setSnapshotFailure(true)
        await subject.refresh(force: true)
        XCTAssertEqual(subject.snapshot?.terms.count, 0)
        XCTAssertEqual(subject.snapshot?.version, "\"v2-read-active\"")
        XCTAssertFalse(subject.isStale)
        XCTAssertTrue(subject.message?.contains("offline") == true)
    }

    func test304WithoutMatchingValidatorRetriesOnceUnconditionally() async throws {
        let bad304 = CompanyDictionaryHTTPResponse(status: 304, headers: ["ETag": "\"wrong\""], body: Data())
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(bad304),
            .response(try dictionary())])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        XCTAssertNotNil(subject.snapshot)
        let dictionaryRequests = await transport.requests.filter { $0.endpoint.path == "/api/v1/company-dictionary" }
        XCTAssertEqual(dictionaryRequests.count, 2)
        XCTAssertTrue(dictionaryRequests.allSatisfy { $0.etag == nil })
    }

    func testMalformedCapabilityAndTransientFailureKeepOnlyPreviouslyBoundSnapshot() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(try dictionary(["UnauthorizedNewTerm"], version: "\"v2-edit-active\"", canEdit: true)),
            .response(.init(status: 503, headers: ["Retry-After": "3600"], body: Data()))])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        await subject.refresh(force: true)
        XCTAssertEqual(subject.snapshot?.terms.first?.canonicalSpelling, "SyntheticName")
        XCTAssertTrue(subject.isStale)
        await subject.refresh(force: true)
        XCTAssertEqual(subject.snapshot?.terms.first?.canonicalSpelling, "SyntheticName")
        let before = await transport.requests.count
        await subject.refresh()
        await subject.refresh(force: true)
        let after = await transport.requests.count
        XCTAssertEqual(before, after, "Support's Retry-After applies to ordinary and deliberate checks.")
    }

    func test403DropsPublicationKeepsCredentialAndRequiresExplicitRetry() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(.init(status: 403, headers: [:], body: Data())), .response(try dictionary([], version: "\"v2-read-active\""))])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        await subject.refresh(force: true)
        XCTAssertNil(subject.snapshot)
        XCTAssertTrue(subject.isSignedIn)
        XCTAssertEqual(subject.profile?.userID, userID)
        let before = await transport.requests.count
        await subject.refresh()
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
        await subject.refresh(force: true)
        XCTAssertEqual(subject.snapshot?.terms.count, 0)
    }

    func testLate401CannotSignOutNewAccount() async throws {
        try await exerciseLateResponse(.init(status: 401, headers: [:], body: Data()),
                                       nextUser: "00000000-0000-0000-0000-000000000008")
    }

    func testLate200CannotCrossSameUserNewSession() async throws {
        try await exerciseLateResponse(try dictionary(["RetiredSessionTerm"], version: "\"late-read-active\""), nextUser: userID)
    }

    private func exerciseLateResponse(_ lateResponse: CompanyDictionaryHTTPResponse, nextUser: String) async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .blocked, .response(.init(status: 204, headers: [:], body: Data())),
            .response(try mint("b")), .response(try identity(nextUser)),
            .response(try dictionary(["CurrentSessionTerm"], version: "\"current-read-active\""))])
        let subject = client(transport, store: SyntheticCompanyStore())
        _ = try await connect(subject)
        let oldRefresh = Task { await subject.refresh(force: true) }
        var blocked = false
        for _ in 0..<1_000 {
            if await transport.isBlocked { blocked = true; break }
            await Task.yield()
        }
        guard blocked else { oldRefresh.cancel(); XCTFail("Synthetic request did not reach its controlled barrier."); return }
        _ = try await connect(subject)
        await transport.release(lateResponse)
        await oldRefresh.value
        XCTAssertTrue(subject.isSignedIn)
        XCTAssertEqual(subject.profile?.userID, nextUser)
        XCTAssertEqual(subject.snapshot?.terms.first?.canonicalSpelling, "CurrentSessionTerm")
    }

    func testExpiryExcludesCompanyWithoutAnyRefreshRequest() async throws {
        let clock = SyntheticCompanyClock(date)
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary())])
        var published: CompanyDictionarySnapshot?
        let subject = client(transport, store: SyntheticCompanyStore(), clock: clock) { snapshot, _ in published = snapshot }
        _ = try await connect(subject)
        let before = await transport.requests.count
        clock.advance(3_601)
        await subject.enforceExpiry()
        XCTAssertNil(published)
        XCTAssertNil(subject.snapshot)
        XCTAssertFalse(subject.isSignedIn)
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
    }

    func testFailedDurableSignoutNeverKeepsInProcessContributionOrClaimsSuccess() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(.init(status: 204, headers: [:], body: Data()))])
        let store = SyntheticCompanyStore()
        var published: CompanyDictionarySnapshot?
        let subject = client(transport, store: store) { snapshot, _ in published = snapshot }
        _ = try await connect(subject)
        await store.setResetFailure(true)
        await subject.signOut()
        XCTAssertNil(published)
        XCTAssertNil(subject.snapshot)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertTrue(subject.message?.contains("durable sign-out") == true)
    }

    func test401DoesNotHideDurableInvalidationFailureBehindGenericSignInMessage() async throws {
        let transport = SyntheticCompanyTransport([.response(try mint()), .response(try identity()), .response(try dictionary()),
            .response(.init(status: 401, headers: [:], body: Data()))])
        let store = SyntheticCompanyStore()
        let subject = client(transport, store: store)
        _ = try await connect(subject)
        await store.setResetFailure(true)
        await subject.refresh(force: true)
        XCTAssertNil(subject.snapshot)
        XCTAssertFalse(subject.isSignedIn)
        XCTAssertTrue(subject.message?.contains("durable sign-out") == true)
    }

    func testRequestAndConfigurationKeepSupportCredentialOnCookieFreeUncachedRoute() throws {
        let request = try CompanyDictionaryRequest(endpoint: .dictionary, credential: "synthetic-key", etag: "\"opaque\"").urlRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://support.forit.io/api/v1/company-dictionary")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertThrowsError(try CompanyDictionaryRequest(endpoint: .dictionary, credential: "bad\ncredential").urlRequest())
        XCTAssertThrowsError(try CompanyDictionaryRequest(endpoint: .dictionary, credential: "synthetic-key", etag: "W/\"weak\"").urlRequest())
        let configuration = SupportCompanyDictionaryTransport.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testRealTransportRetains401And403DespiteOversizedErrorLength() async throws {
        defer { SyntheticSupportURLProtocol.clear() }
        let transport = SupportCompanyDictionaryTransport(protocolClasses: { [SyntheticSupportURLProtocol.self] })
        for status in [401, 403] {
            SyntheticSupportURLProtocol.prepare(.response(status, ["Content-Length": "99999999"], []))
            let response = try await transport.send(.init(endpoint: .identity, credential: "synthetic-key"))
            XCTAssertEqual(response.status, status)
            XCTAssertTrue(response.body.isEmpty)
            XCTAssertEqual(SyntheticSupportURLProtocol.observedURLs.count, 1)
        }
    }

    func testRealTransportBoundsDeliveredChunksWithoutContentLength() async throws {
        defer { SyntheticSupportURLProtocol.clear() }
        let limit = CompanyDictionaryRequest.Endpoint.identity.maximumBytes
        let first = Data(repeating: 0x20, count: limit)
        SyntheticSupportURLProtocol.prepare(.response(200, [:], [first, Data([0x20])]))
        let transport = SupportCompanyDictionaryTransport(protocolClasses: { [SyntheticSupportURLProtocol.self] })
        do {
            _ = try await transport.send(.init(endpoint: .identity, credential: "synthetic-key"))
            XCTFail("The delivered-byte limit must stop a response with no declared length.")
        } catch CompanyDictionaryTransportError.bodyTooLarge { }
    }

    func testRealTransportRejectsRedirectBeforeSecondRequest() async throws {
        defer { SyntheticSupportURLProtocol.clear() }
        let target = try XCTUnwrap(URL(string: "https://example.invalid/must-not-receive-credential"))
        SyntheticSupportURLProtocol.prepare(.redirect(target))
        let transport = SupportCompanyDictionaryTransport(protocolClasses: { [SyntheticSupportURLProtocol.self] })
        do {
            _ = try await transport.send(.init(endpoint: .identity, credential: "synthetic-key"))
            XCTFail("Support redirects must be refused.")
        } catch CompanyDictionaryTransportError.redirectRejected { }
        XCTAssertEqual(SyntheticSupportURLProtocol.observedURLs.map(\.host), ["support.forit.io"])
    }
}

private actor SyntheticCompanyTransport: CompanyDictionaryTransport {
    enum Step: Sendable { case response(CompanyDictionaryHTTPResponse), failure, blocked }
    private var steps: [Step]
    private(set) var requests: [CompanyDictionaryRequest] = []
    private var pending: CheckedContinuation<CompanyDictionaryHTTPResponse, Error>?
    var isBlocked: Bool { pending != nil }
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: CompanyDictionaryRequest) async throws -> CompanyDictionaryHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw CompanyDictionaryTransportError.unavailable }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .failure: throw CompanyDictionaryTransportError.unavailable
        case .blocked: return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func release(_ response: CompanyDictionaryHTTPResponse) {
        pending?.resume(returning: response)
        pending = nil
    }
}

private actor SyntheticCompanyStore: CompanyDictionaryStore {
    private var sessionID: UUID?
    private var credential: CompanyDictionaryCredential?
    private var value: CompanyDictionarySnapshot?
    private var credentialFailure = false
    private var snapshotFailure = false
    private var resetFailure = false
    private var latestResetOrder: UInt64 = 0
    func setCredentialFailure(_ value: Bool) { credentialFailure = value }
    func setSnapshotFailure(_ value: Bool) { snapshotFailure = value }
    func setResetFailure(_ value: Bool) { resetFailure = value }
    func restore() -> CompanyDictionaryRestoration { .init(credential: credential, snapshot: value, checkedAt: nil, accessDenied: false) }
    func reset(to id: UUID, order: UInt64) throws {
        guard order > latestResetOrder else { throw CompanyDictionaryStoreError.staleSession }
        latestResetOrder = order
        sessionID = id
        credential = nil
        value = nil
        if resetFailure { throw CompanyDictionaryStoreError.durableInvalidationFailed }
    }
    func saveCredential(_ candidate: CompanyDictionaryCredential) throws {
        guard !credentialFailure, candidate.sessionID == sessionID else { throw CompanyDictionaryStoreError.persistenceFailed }
        credential = candidate
    }
    func bindProfile(_ profile: CompanyDictionaryProfile, sessionID: UUID) throws {
        guard self.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
        credential?.profile = profile
    }
    func saveSnapshot(_ body: Data, snapshot: CompanyDictionarySnapshot, checkedAt: Date, sessionID: UUID) throws {
        guard !snapshotFailure, self.sessionID == sessionID else { throw CompanyDictionaryStoreError.persistenceFailed }
        value = snapshot
    }
    func markChecked(_ date: Date, version: String, sessionID: UUID) throws {
        guard self.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
    }
    func denyAccess(sessionID: UUID) throws {
        guard self.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
        value = nil
    }
}

private final class SyntheticCompanyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

/// Every request is intercepted, including a hypothetical redirected request;
/// these integration tests never fall through to a real network protocol.
private final class SyntheticSupportURLProtocol: URLProtocol, @unchecked Sendable {
    enum Plan: Sendable {
        case response(Int, [String: String], [Data])
        case redirect(URL)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plan: Plan?
    nonisolated(unsafe) private static var urls: [URL] = []
    private let stateLock = NSLock()
    private var stopped = false

    static var observedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    static func prepare(_ value: Plan) { lock.lock(); defer { lock.unlock() }; plan = value; urls = [] }
    static func clear() { lock.lock(); defer { lock.unlock() }; plan = nil; urls = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let plan = Self.plan
        if let url = request.url { Self.urls.append(url) }
        Self.lock.unlock()
        guard let url = request.url, let plan else {
            client?.urlProtocol(self, didFailWithError: CompanyDictionaryTransportError.invalidRequest)
            return
        }
        switch plan {
        case .response(let status, let headers, let chunks):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: CompanyDictionaryTransportError.invalidResponse)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                stateLock.lock()
                let stopped = self.stopped
                stateLock.unlock()
                guard !stopped else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            guard let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": target.absoluteString]) else {
                client?.urlProtocol(self, didFailWithError: CompanyDictionaryTransportError.invalidResponse)
                return
            }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
    }

    override func stopLoading() { stateLock.lock(); defer { stateLock.unlock() }; stopped = true }
}
