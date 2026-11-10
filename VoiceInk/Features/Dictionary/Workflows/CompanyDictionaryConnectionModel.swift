import AppKit
import Combine
import ForITCommon
import Foundation

/// The browser interaction belongs to the app; Support establishes the cached identity.
@MainActor
final class CompanyDictionaryConnectionModel: ObservableObject {
    let client: CompanyDictionaryClient
    let browser: BrowserSignIn
    @Published var isSignInPresented = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInMessage: String?

    private let bundleID: String
    private var operationID: UUID?
    private var activeAttempt: UUID?
    private var signInTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        bundleID = Bundle.main.bundleIdentifier ?? "io.forit.dictate"
        let redirect = URL(string: "\(bundleID)://oauth/callback")!
        browser = BrowserSignIn(configuration: .forIT(redirectURI: redirect))
        client = CompanyDictionaryClient { snapshot, expiresAt in
            SharedVocabularyService.shared.setCompanySnapshot(snapshot, validUntil: expiresAt)
        }
        client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.client.refresh() }
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.client.refresh() }
            }.store(in: &subscriptions)
    }

    var profileAccount: ForITProfileAccount? {
        guard let profile = client.profile else { return nil }
        return ForITProfileAccount(id: profile.userID, name: profile.name, detail: profile.email)
    }

    func start() {
        Task { await client.restore() }
    }

    /// Consume our callback even after cancellation; it must never become a media import.
    func handleCallback(_ url: URL) -> Bool {
        guard CompanyDictionaryCallbackRoute.matches(url, bundleID: bundleID) else { return false }
        if isSigningIn, operationID != nil { _ = browser.handle(url) }
        return true
    }

    func presentSignIn() {
        signInMessage = nil
        isSignInPresented = true
    }

    func signIn() {
        guard !isSigningIn else { return }
        let operation = UUID()
        operationID = operation
        isSigningIn = true
        signInMessage = nil
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operation {
                    self.operationID = nil
                    self.activeAttempt = nil
                    self.isSigningIn = false
                    self.signInTask = nil
                }
            }
            guard let attempt = await self.client.beginConnection() else { return }
            guard self.operationID == operation, !Task.isCancelled else {
                await self.client.cancelConnection(attempt: attempt)
                return
            }
            self.activeAttempt = attempt
            do {
                let identity = try await self.browser.signIn { [weak self] url in
                    guard let self, self.operationID == operation, !Task.isCancelled else { return false }
                    return NSWorkspace.shared.open(url)
                }
                // Common cancellation cannot cancel an exchange already in flight.
                // This fence prevents its late result from minting any Support session.
                guard self.operationID == operation, !Task.isCancelled else { return }
                await self.client.finishConnection(idToken: identity.idToken, attempt: attempt)
                guard self.operationID == operation, !Task.isCancelled else { return }
                if self.client.isSignedIn {
                    self.activeAttempt = nil
                    self.isSignInPresented = false
                }
            } catch {
                guard self.operationID == operation else { return }
                await self.client.cancelConnection(attempt: attempt)
                if !(error is CancellationError), (error as? SignInError) != .cancelled {
                    self.signInMessage = String(localized: "Sign-in could not be completed. Try again to start a fresh sign-in.")
                }
            }
        }
    }

    func cancelSignIn() {
        let attempt = activeAttempt
        operationID = nil
        activeAttempt = nil
        signInTask?.cancel()
        signInTask = nil
        browser.cancel()
        isSigningIn = false
        isSignInPresented = false
        if let attempt { Task { await client.cancelConnection(attempt: attempt) } }
    }

    func signOut() {
        cancelSignIn()
        Task { await client.signOut() }
    }
}

