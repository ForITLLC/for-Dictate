import AppKit
import Combine
import ForITCommon
import Foundation
import SwiftUI

// This file is staged only into the gated fixture executable, never the app.
// A mistaken production convenience initializer aborts before touching Keychain.
struct CompanyDictionaryKeychainStore: CompanyDictionaryCredentialStore {
    init(bundleID: String) { fatalError("Fixture forbids production credential adapter construction") }
    func read() -> CompanyDictionaryCredentialRead { fatalError("Fixture forbids Keychain reads") }
    func save(_ data: Data) -> Bool { fatalError("Fixture forbids Keychain writes") }
    func delete() -> Bool { fatalError("Fixture forbids Keychain deletion") }
}

private enum FixtureFailure: Error { case invalidInput, assertion(String), actionUnavailable(String) }

@MainActor
private struct FixtureHost: View {
    @ObservedObject var connection: CompanyDictionaryConnectionModel
    let vocabulary: SharedVocabularyService

    var body: some View {
        NavigationStack {
            CompanyDictionaryView(vocabulary: vocabulary)
                .environmentObject(connection)
                .navigationTitle("Company Dictionary")
                .forITProfileMenu(account: connection.profileAccount, settings: {
                    Text("Synthetic settings destination; host preferences are not opened.")
                })
        }
    }
}

private final class NoNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private actor MemoryStore: CompanyDictionaryStore {
    private var value: CompanyDictionaryRestoration
    private var order: UInt64 = 0
    init(_ value: CompanyDictionaryRestoration) { self.value = value }
    var hasCredential: Bool { value.credential != nil }
    func restore() async throws -> CompanyDictionaryRestoration { value }
    func reset(to sessionID: UUID, order: UInt64) async throws {
        guard order > self.order else { throw CompanyDictionaryStoreError.staleSession }
        self.order = order
        value = .init(credential: nil, snapshot: nil, checkedAt: nil, accessDenied: false)
    }
    func saveCredential(_ credential: CompanyDictionaryCredential) async throws {
        value = .init(credential: credential, snapshot: nil, checkedAt: nil, accessDenied: false)
    }
    func bindProfile(_ profile: CompanyDictionaryProfile, sessionID: UUID) async throws {
        guard var credential = value.credential, credential.sessionID == sessionID else {
            throw CompanyDictionaryStoreError.staleSession
        }
        credential.profile = profile
        value = .init(credential: credential, snapshot: value.snapshot, checkedAt: value.checkedAt, accessDenied: false)
    }
    func saveSnapshot(_ body: Data, snapshot: CompanyDictionarySnapshot, checkedAt: Date, sessionID: UUID) async throws {
        guard value.credential?.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
        value = .init(credential: value.credential, snapshot: snapshot, checkedAt: checkedAt, accessDenied: false)
    }
    func markChecked(_ date: Date, version: String, sessionID: UUID) async throws {
        guard value.credential?.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
        value = .init(credential: value.credential, snapshot: value.snapshot, checkedAt: date, accessDenied: false)
    }
    func denyAccess(sessionID: UUID) async throws {
        guard value.credential?.sessionID == sessionID else { throw CompanyDictionaryStoreError.staleSession }
        value = .init(credential: value.credential, snapshot: nil, checkedAt: value.checkedAt, accessDenied: true)
    }
}

private actor MemoryTransport: CompanyDictionaryTransport {
    let mode: String
    let body: Data
    private var pending: CheckedContinuation<CompanyDictionaryHTTPResponse, Error>?
    private var counts: [String: Int] = [:]
    init(mode: String, body: Data) { self.mode = mode; self.body = body }
    var ledger: [String: Int] { counts }
    func send(_ request: CompanyDictionaryRequest) async throws -> CompanyDictionaryHTTPResponse {
        let label: String
        switch request.endpoint {
        case .mint: label = "mint"
        case .identity: label = "identity"
        case .dictionary: label = "dictionary"
        case .revoke: label = "revoke"
        }
        counts[label, default: 0] += 1 // Never retain credentials, bodies or URLs.
        switch request.endpoint {
        case .mint: throw FixtureFailure.assertion("Unexpected mint in UI-only fixture")
        case .identity:
            let data = try JSONSerialization.data(withJSONObject: [
                "userId": FixtureData.userID, "name": "Synthetic account", "email": FixtureData.email,
                "workspace": ["mode": "staff"],
            ])
            return .init(status: 200, headers: [:], body: data)
        case .revoke: return .init(status: 204, headers: [:], body: Data())
        case .dictionary:
            if mode == "loading" {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            if mode == "stale" || mode == "error" {
                return .init(status: 503, headers: [:], body: Data())
            }
            return .init(status: 200, headers: ["ETag": FixtureData.version], body: body)
        }
    }
}

private enum FixtureData {
    static let userID = "10000000-0000-0000-0000-000000000001"
    static let email = "synthetic.long.account.name@example.invalid"
    static let version = "\"synthetic-ui-read-active\""
    static func body(empty: Bool, long: Bool, now: Date) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let words = empty ? [] : (long ? [String(repeating: "名", count: 100), "Northbridge", "Alexandra Reyes"] :
            ["Alexandra Reyes", "Northbridge", "ForIT example"])
        let rows = words.enumerated().map { index, word -> [String: Any] in
            ["term_id": String(format: "20000000-0000-0000-0000-%012d", index + 1),
             "canonical_spelling": word, "spoken_forms": index == 1 ? ["Delta call"] :
                (long ? (1...12).map { "Alias \($0) " + String(repeating: "spoken name ", count: 7) } : ["Example alias \(index)"]),
             "meaning": long ? String(repeating: "Long explanatory meaning. ", count: 19) : "Synthetic example only",
             "kind": index == 0 ? "person" : "product", "is_active": true,
             "revision": 1, "updated_at": timestamp]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "companyId": CompanyDictionarySnapshot.supportCompanyID,
            "version": version, "terms": rows, "total": rows.count,
            "updated_at": empty ? NSNull() as Any : timestamp, "canEdit": false,
        ])
    }
}

@MainActor
private struct AXNode {
    let element: NSObject
    let window: Int
    let role: String
    let label: String
    let identifier: String
    let inDialog: Bool
    var frame: NSRect? {
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let boxed = element.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return boxed.rectValue
    }
    var record: [String: Any] {
        var value: [String: Any] = ["window": window, "role": role, "label": String(label.prefix(512)),
                                    "identifier": identifier, "inDialog": inDialog]
        if let frame {
            value["framePoints"] = [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height)]
        } else { value["framePointsUnavailable"] = true }
        return value
    }
}

/// Only the fixture process's objects are inspected; there is no system-wide AX
/// connection, desktop capture, global event injection or permission request.
@MainActor
private enum OwnUI {
    static func object(_ element: NSObject, _ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
    static func nodes() -> [AXNode] {
        var result: [AXNode] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ element: NSObject, window: Int, depth: Int, dialog: Bool) {
            guard depth < 30, result.count < 4_000, visited.insert(ObjectIdentifier(element)).inserted else { return }
            let role = object(element, "accessibilityRole") as? String ?? ""
            let isDialog = dialog || ["AXSheet", "AXDialog", "AXAlert"].contains(role)
            result.append(.init(element: element, window: window, role: role,
                                label: object(element, "accessibilityLabel") as? String ?? "",
                                identifier: object(element, "accessibilityIdentifier") as? String ?? "",
                                inDialog: isDialog))
            if let children = object(element, "accessibilityChildren") as? [AnyObject] {
                for child in children {
                    if let child = child as? NSObject { visit(child, window: window, depth: depth + 1, dialog: isDialog) }
                }
            }
        }
        for window in NSApp.windows where window.isVisible {
            visit(window, window: window.windowNumber, depth: 0, dialog: window.sheetParent != nil)
        }
        return result
    }
    static func press(_ node: AXNode) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.element.responds(to: selector), let implementation = node.element.method(for: selector) else {
            throw FixtureFailure.actionUnavailable(node.identifier.isEmpty ? node.label : node.identifier)
        }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(implementation, to: Action.self)
        guard action(node.element, selector) else { throw FixtureFailure.actionUnavailable(node.label) }
    }
    static func press(identifier: String) throws {
        guard let node = nodes().first(where: { $0.identifier == identifier }) else {
            throw FixtureFailure.actionUnavailable(identifier)
        }
        try press(node)
    }
    static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        guard let window = NSApp.keyWindow, NSApp.windows.contains(where: { $0 === window }) else {
            throw FixtureFailure.actionUnavailable("fixture key window")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { throw FixtureFailure.invalidInput }
            NSApp.sendEvent(event)
        }
    }
    static func search(_ text: String) throws {
        guard let field = nodes().first(where: { $0.identifier == "dictate.companyDictionary.search" }) else {
            throw FixtureFailure.actionUnavailable("search")
        }
        let selector = NSSelectorFromString("setAccessibilityFocused:")
        guard field.element.responds(to: selector), let implementation = field.element.method(for: selector) else {
            throw FixtureFailure.actionUnavailable("search focus")
        }
        typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Focus.self)(field.element, selector, true)
        try key("a", code: 0, modifiers: .command)
        for character in text { try key(String(character), code: 0) }
    }
    static func click(_ node: AXNode, in window: NSWindow) throws {
        guard node.window == window.windowNumber, !node.inDialog,
              NSApp.keyWindow === window, window.isVisible,
              let frame = node.frame, !frame.isEmpty, window.frame.contains(frame) else {
            throw FixtureFailure.actionUnavailable("Own-window click on " + node.label)
        }
        try queueClick(frame: frame, in: window)
    }

    static func clickSignOutConfirmation(of parent: NSWindow, findButton: () -> AXNode?) async throws {
        var target: (window: NSWindow, frame: NSRect)?
        try await wait("the real Sign out alert to attach to the dictionary window", details: {
            let attachment = parent.attachedSheet
            let visible = NSApp.windows.filter(\.isVisible).prefix(8).map {
                "\($0.windowNumber): frame \($0.frame), sheet parent \($0.sheetParent?.windowNumber ?? 0)"
            }.joined(separator: "; ")
            return "parent \(parent.windowNumber), attachment \(attachment?.windowNumber ?? 0), own visible windows [\(visible)]"
        }) {
            guard let sheet = parent.attachedSheet, sheet.sheetParent === parent,
                  sheet.isVisible, NSApp.windows.contains(where: { $0 === sheet }),
                  let button = findButton(), button.role == "AXButton", button.label == "Sign out",
                  button.inDialog || button.window == sheet.windowNumber,
                  let frame = button.frame, !frame.isEmpty, sheet.frame.contains(frame) else {
                return false
            }
            target = (sheet, frame)
            return true
        }
        guard let target else { throw FixtureFailure.actionUnavailable("Attached Sign out confirmation") }
        try queueClick(frame: target.frame, in: target.window)
    }

    private static func queueClick(frame: NSRect, in window: NSWindow) throws {
        let screenPoint = NSRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
        let point = window.convertFromScreen(screenPoint).origin
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: pressure)
        }
        guard let down = event(.leftMouseDown, pressure: 1),
              let up = event(.leftMouseUp, pressure: 0) else { throw FixtureFailure.invalidInput }
        // Queue locally in dispatch order. AppKit control tracking may consume the up
        // event before the mouse-down handler returns.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
    }

    static func signOutRow(in window: NSWindow) async throws -> AXNode {
        func rowAndViewport() -> (AXNode, NSRect, NSRect)? {
            let ownNodes = nodes().filter { $0.window == window.windowNumber && !$0.inDialog }
            let scrollAreas = ownNodes.filter { $0.role == "AXScrollArea" }
            guard scrollAreas.count == 1, let viewport = scrollAreas.first?.frame,
                  let row = ownNodes.first(where: { $0.role == "AXButton" && $0.label == "Sign out" }),
                  let frame = row.frame, !frame.isEmpty else { return nil }
            return (row, frame, viewport)
        }
        guard let (_, frame, viewport) = rowAndViewport() else {
            throw FixtureFailure.actionUnavailable("Shared Sign out row or dictionary scroll area")
        }
        if !viewport.contains(frame) {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap { scrollViews(in: $0) }
            }
            let documents = window.contentView.map { scrollViews(in: $0) }?.compactMap(\.documentView) ?? []
            guard documents.count == 1, let document = documents.first else {
                throw FixtureFailure.actionUnavailable("Dictionary form scroll document")
            }
            let rect = document.convert(window.convertFromScreen(frame), from: nil)
            _ = document.scrollToVisible(rect)
        }
        var visibleRow: AXNode?
        try await wait("Sign out row visible inside the dictionary form") {
            guard let (row, frame, viewport) = rowAndViewport(), viewport.contains(frame) else { return false }
            visibleRow = row
            return true
        }
        guard let visibleRow else { throw FixtureFailure.actionUnavailable("Visible Sign out row") }
        return visibleRow
    }

    static func wait(_ transition: String, details: (() -> String)? = nil,
                     _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                let detail = details.map { ": " + $0() } ?? ""
                throw FixtureFailure.assertion("UI transition timed out while waiting for " + transition + detail)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var connection: CompanyDictionaryConnectionModel?
    private var vocabulary: SharedVocabularyService?
    private var window: NSWindow?
    private var openedBrowserRequests = 0
    private var interactions: [[String: String]] = []
    private var snapshotTask: Task<Void, Never>?
    private var ownedOutput: URL?
    private var signOutStep: String?

    private func prepareSurface(parent: NSWindow, size: CGSize, appearance: NSAppearance,
                                dark: Bool, phase: String) async throws -> NSWindow {
        let target = parent.sheets.last(where: \.isVisible) ?? parent
        guard target.level == .normal, NSApp.windows.contains(where: { $0 === target }) else {
            throw FixtureFailure.assertion("Actual own window/sheet is not a supported ordinary surface")
        }
        target.appearance = appearance
        target.setContentSize(size)
        target.makeKeyAndOrderFront(nil)
        var lastResize = ContinuousClock.now
        var resizeRequests = 1
        var matchingSince: ContinuousClock.Instant?
        try await OwnUI.wait(phase, details: {
            let actualSize = target.contentView?.frame.size
            let actualTheme = target.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "none"
            return "window \(target.windowNumber), parent \(parent.windowNumber), "
                + "sheet \(target.sheetParent != nil), visible \(target.isVisible), key \(target.isKeyWindow), "
                + "content \(String(describing: actualSize)), requested \(size), resize requests \(resizeRequests), "
                + "appearance \(actualTheme), requested \(appearance.name.rawValue)"
        }) {
            let now = ContinuousClock.now
            let actualSize = target.contentView?.frame.size
            if actualSize != size {
                matchingSince = nil
                // SwiftUI can resize the attached sheet after the browser state changes.
                // Reapply only while the bounded wait is active and the size differs.
                if lastResize.duration(to: now) >= .milliseconds(100) {
                    target.setContentSize(size)
                    lastResize = now
                    resizeRequests += 1
                }
                return false
            }
            guard target.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == (dark ? .darkAqua : .aqua) else {
                matchingSince = nil
                return false
            }
            if let matchingSince {
                return matchingSince.duration(to: now) >= .milliseconds(100)
            }
            matchingSince = now
            return false
        }
        return target
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch {
                writeFailure(error)
                exit(1)
            }
        }
    }

    private func run() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 11,
              Bundle.main.bundleIdentifier == "io.forit.dictate.ui-fixture",
              let outputText = ProcessInfo.processInfo.environment["FORIT_COMPANY_UI_OUTPUT"],
              outputText.hasPrefix("/"),
              let captureText = ProcessInfo.processInfo.environment["FORIT_COMPANY_UI_CAPTURE"],
              captureText.hasPrefix("/") else { throw FixtureFailure.invalidInput }
        let keys: Set<String> = ["-forit-fixture", "-forit-shot", "-forit-appearance", "-forit-window", "-forit-settle"]
        var options: [String: String] = [:]
        for index in stride(from: 1, to: args.count, by: 2) {
            guard keys.contains(args[index]), options[args[index]] == nil else { throw FixtureFailure.invalidInput }
            options[args[index]] = args[index + 1]
        }
        guard let fixture = options["-forit-fixture"], let look = options["-forit-appearance"],
              ["light", "dark"].contains(look), let sizeText = options["-forit-window"],
              ["900x600", "1600x1000"].contains(sizeText), options["-forit-shot"] == "screen.png",
              options["-forit-settle"] == "3" else { throw FixtureFailure.invalidInput }
        let output = URL(fileURLWithPath: outputText, isDirectory: true)
        guard output.path == outputText,
              output.resolvingSymlinksInPath().path == outputText,
              try output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw FixtureFailure.assertion("Fixture output must be an existing canonical cell directory")
        }
        ownedOutput = output
        let capture = output.appendingPathComponent("native", isDirectory: true)
        guard capture.path == captureText,
              capture.resolvingSymlinksInPath().path == captureText,
              try capture.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw FixtureFailure.assertion("Native capture must be the owned cell's canonical native directory")
        }
        let dimensions = sizeText.split(separator: "x").compactMap { Double($0) }
        let requestedSize = CGSize(width: dimensions[0], height: dimensions[1])
        guard let appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) else {
            throw FixtureFailure.invalidInput
        }
        NSApp.appearance = appearance // Before constructing views or exercising controls.
        let allowed = ["signedout", "empty", "full", "stale", "error", "loading", "search", "longnames",
                       "signin", "browser-wait", "keyboard-close", "close", "cancel", "signout"]
        guard allowed.contains(fixture) else { throw FixtureFailure.invalidInput }
        let now = Date()
        let body = try FixtureData.body(empty: fixture == "empty", long: fixture == "longnames", now: now)
        let dto = try JSONDecoder().decode(CompanyDictionarySnapshot.self, from: body)
        let signedout = ["signedout", "signin", "browser-wait", "keyboard-close", "close", "cancel"].contains(fixture)
        let profile = CompanyDictionaryProfile(userID: FixtureData.userID, name: "Synthetic account", email: FixtureData.email)
        let credential: CompanyDictionaryCredential? = signedout ? nil : .init(
            sessionID: UUID(), key: "fsak_" + String(repeating: "x", count: 43),
            expiresAt: now.addingTimeInterval(3_600), profile: profile)
        let store = MemoryStore(.init(credential: credential, snapshot: fixture == "stale" ? dto : nil,
                                     checkedAt: fixture == "stale" ? now.addingTimeInterval(-3_600) : nil,
                                     accessDenied: false))
        let transport = MemoryTransport(mode: fixture, body: body)
        let cache = SharedVocabularyCache()
        let files = SharedVocabularyFiles(catalogURL: output.appendingPathComponent("isolated/catalog.json"),
                                          preferencesURL: output.appendingPathComponent("isolated/preferences.json"))
        let vocabulary = SharedVocabularyService(files: files, cache: cache)
        self.vocabulary = vocabulary
        let client = CompanyDictionaryClient(transport: transport, store: store, now: { now },
                                             maintenanceEnabled: false) { [weak vocabulary] value, expiry in
            vocabulary?.setCompanySnapshot(value, validUntil: expiry)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkProtocol.self]
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        let browser = BrowserSignIn(configuration: .init(clientId: "synthetic-ui-client",
            authority: URL(string: "https://auth.example.invalid/oauth2")!,
            redirectURI: URL(string: "io.forit.dictate.ui-fixture://oauth/callback")!, scopes: ["openid"]),
            session: URLSession(configuration: config))
        let connection = CompanyDictionaryConnectionModel(client: client, browser: browser,
            bundleID: "io.forit.dictate.ui-fixture", observeLifecycle: false) { [weak self] url in
                guard url.host == "auth.example.invalid" else { return false }
                self?.openedBrowserRequests += 1 // No URL/state/nonce is retained.
                return true // No browser is opened.
            }
        self.connection = connection
        if fixture == "loading" {
            snapshotTask = Task { await client.restore() }
            try await OwnUI.wait("synthetic loading state") { client.isBusy }
        } else { await client.restore() }
        let surface = FixtureHost(connection: connection, vocabulary: vocabulary)
        let hosting = NSHostingView(rootView: surface)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: requestedSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ForIT Dictate — Company Dictionary (synthetic)"
        window.appearance = appearance
        window.contentView = hosting
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        _ = try await prepareSurface(parent: window, size: requestedSize, appearance: appearance,
                                     dark: look == "dark", phase: "initial dictionary window geometry and appearance")

        if fixture == "search" {
            try OwnUI.search("Delta call")
            try await OwnUI.wait("keyboard search results") {
                let nodes = OwnUI.nodes()
                return nodes.contains { $0.identifier == "dictate.companyDictionary.term.20000000-0000-0000-0000-000000000002" }
                    && !nodes.contains { $0.identifier == "dictate.companyDictionary.term.20000000-0000-0000-0000-000000000001" }
            }
            interactions.append(["name": "keyboard alias search", "status": "observed"])
        }
        if ["signin", "browser-wait", "keyboard-close", "close", "cancel"].contains(fixture) {
            try OwnUI.press(identifier: "dictate.companyDictionary.connect")
            try await OwnUI.wait("sign-in sheet Close control") {
                connection.isSignInPresented && OwnUI.nodes().contains {
                    $0.identifier == "dictate.companyDictionary.closeSignIn"
                }
            }
            _ = try await prepareSurface(parent: window, size: requestedSize, appearance: appearance,
                                         dark: look == "dark", phase: "opened sign-in sheet geometry and appearance")
            if ["browser-wait", "cancel"].contains(fixture) {
                try OwnUI.press(identifier: "signin.microsoft")
                try await OwnUI.wait("synthetic browser wait") { browser.isWaitingForBrowser }
            }
            if fixture == "keyboard-close" {
                try OwnUI.key("\u{1B}", code: 53)
                try await OwnUI.wait("sign-in sheet dismissal after Escape") {
                    !connection.isSignInPresented && !connection.isSigningIn
                }
                interactions.append(["name": "Escape closes sign-in", "status": "observed"])
            } else if fixture == "close" {
                try OwnUI.press(identifier: "dictate.companyDictionary.closeSignIn")
                try await OwnUI.wait("sign-in sheet dismissal after Close") {
                    !connection.isSignInPresented && !connection.isSigningIn
                }
                interactions.append(["name": "Close closes sign-in", "status": "observed"])
            } else if fixture == "cancel" {
                guard let cancel = OwnUI.nodes().first(where: { $0.label == "Cancel" && $0.role == "AXButton" }) else {
                    throw FixtureFailure.actionUnavailable("Common browser Cancel")
                }
                try OwnUI.press(cancel)
                try await OwnUI.wait("browser cancellation") { !browser.isWaitingForBrowser && !connection.isSigningIn }
                guard connection.isSignInPresented else { throw FixtureFailure.assertion("Common Cancel unexpectedly closed the sheet") }
                interactions.append(["name": "Common Cancel ends browser wait, sheet remains", "status": "observed"])
            }
        }
        if fixture == "signout" {
            func confirmation() -> AXNode? {
                OwnUI.nodes().first {
                    $0.label == "Sign out" && $0.role == "AXButton" && ($0.inDialog || $0.window != window.windowNumber)
                }
            }
            signOutStep = "open first confirmation using the visible row"
            let signOut = try await OwnUI.signOutRow(in: window)
            try OwnUI.click(signOut, in: window)
            try await OwnUI.wait("first sign-out confirmation") { confirmation() != nil }
            signOutStep = "dismiss the first confirmation"
            try OwnUI.key("\u{1B}", code: 53)
            var dismissedSince: ContinuousClock.Instant?
            try await OwnUI.wait("sign-out cancellation and focus returned to the dictionary") {
                guard confirmation() == nil, window.attachedSheet == nil, NSApp.keyWindow === window else {
                    dismissedSince = nil
                    return false
                }
                let now = ContinuousClock.now
                if let dismissedSince { return dismissedSince.duration(to: now) >= .milliseconds(150) }
                dismissedSince = now
                return false
            }
            guard client.isSignedIn else { throw FixtureFailure.assertion("Sign-out Cancel changed the session") }
            interactions.append(["name": "shared sign-out confirmation Cancel preserves session", "status": "observed"])
            signOutStep = "reopen confirmation using the visible row"
            let signOutAgain = try await OwnUI.signOutRow(in: window)
            try OwnUI.click(signOutAgain, in: window)
            try await OwnUI.wait("second sign-out confirmation") { confirmation() != nil }
            let captured = cache.snapshot
            guard captured.companyCoverage.includedTermCount > 0 else {
                throw FixtureFailure.assertion("Sign-out fixture had no company contribution to revoke")
            }
            signOutStep = "click the confirmation button inside its fixture window"
            try await OwnUI.clickSignOutConfirmation(of: window, findButton: confirmation)
            try await OwnUI.wait("sign-out completion") { !client.isSignedIn && !client.isBusy }
            guard !(await store.hasCredential), captured.companyCoverage == .none else {
                throw FixtureFailure.assertion("Shared sign-out did not remove synthetic credential/company hints")
            }
            interactions.append(["name": "shared sign-out confirms and clears fixture session/lease", "status": "observed"])
        }
        let ledger = await transport.ledger
        guard NoNetworkProtocol.count == 0, ledger["mint", default: 0] == 0 else {
            throw FixtureFailure.assertion("Unexpected URLSession request or session mint")
        }
        let capturedSurface = try await prepareSurface(parent: window, size: requestedSize,
                                                       appearance: appearance, dark: look == "dark",
                                                       phase: "final capture window geometry and appearance")
        let evidence: [String: Any] = [
            "schema": "forit.dictate.company-ui-fixture.v1", "fixture": fixture,
            "sourceCommit": ProcessInfo.processInfo.environment["FORIT_SOURCE_COMMIT"] ?? "",
            "commonRevision": "8263a8da050265bb1736bdd601efd253fda03030", "pid": ProcessInfo.processInfo.processIdentifier,
            "windowNumber": capturedSurface.windowNumber, "parentWindowNumber": window.windowNumber,
            "surfaceIsAttachedSheet": capturedSurface.sheetParent != nil, "productionView": "CompanyDictionaryView",
            "requestedWindow": sizeText, "appearance": look,
            "contentWidthPoints": Double(capturedSurface.contentView?.frame.width ?? 0),
            "contentHeightPoints": Double(capturedSurface.contentView?.frame.height ?? 0),
            "nativeCaptureDirectory": capture.path,
            "syntheticOnly": true, "realBrowserOpened": false, "browserOpenerCalls": openedBrowserRequests,
            "browserNetworkRequests": NoNetworkProtocol.count, "syntheticTransportCounts": ledger,
            "hostKeychainAdapter": "fail-closed fixture replacement; production adapter not compiled",
            "defaultsDomain": "io.forit.dictate.ui-fixture", "lifecycleObservers": false, "maintenanceEnabled": false,
            "modelState": ["isSignedIn": client.isSignedIn, "needsSignIn": client.needsSignIn,
                           "isBusy": client.isBusy, "isStale": client.isStale,
                           "termCount": client.snapshot?.terms.count ?? 0, "statusText": client.statusText],
            "interactions": interactions, "hierarchy": OwnUI.nodes().map(\.record),
            "capture": "pending shared own-window-server receipt",
            "unexercised": ["Ben-Mac acceptance", "actual Support/browser authentication", "recognizer use/performance",
                             "whole-app scene/openWindow reuse", "profile Settings destination", "VoiceOver operation", "full Tab order"],
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("fixture-result.json"), options: .atomic)
        let fixtures = Dictionary(uniqueKeysWithValues: allowed.map { ($0, ForITStandaloneMacHarness.SurfaceKind.ordinaryWindow) })
        guard try ForITStandaloneMacHarness.runIfRequested(allowedFixtures: fixtures, outputDirectory: capture,
            makeSurface: { _ in .ordinaryWindow(capturedSurface) }) else {
            throw FixtureFailure.assertion("Published Debug harness did not handle the finite request")
        }
    }

    private func writeFailure(_ error: Error) {
        fputs("Company UI fixture failed; inspect retained fixture-failure.json when available.\n", stderr)
        guard let ownedOutput else { return }
        var value: [String: Any] = ["schema": "forit.dictate.company-ui-fixture-failure.v1",
                                   "status": "FAIL", "error": String(describing: error),
                                   "hierarchy": OwnUI.nodes().map(\.record),
                                   "browserOpenerCalls": openedBrowserRequests,
                                   "browserNetworkRequests": NoNetworkProtocol.count]
        if let signOutStep { value["signOutStep"] = signOutStep }
        if let connection {
            value["state"] = [
                "isSignInPresented": connection.isSignInPresented,
                "isSigningIn": connection.isSigningIn,
                "isWaitingForBrowser": connection.browser.isWaitingForBrowser,
                "isSignedIn": connection.client.isSignedIn,
                "isBusy": connection.client.isBusy,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: ownedOutput.appendingPathComponent("fixture-failure.json"), options: .atomic)
        }
    }
}

@main
@MainActor
private enum CompanyDictionaryUIFixtureMain {
    static func main() {
        guard Bundle.main.bundleIdentifier == "io.forit.dictate.ui-fixture" else { exit(64) }
        // Volatile process preferences only; production io.forit.dictate is never opened.
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["en"], "AppleLocale": "en_US"], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
