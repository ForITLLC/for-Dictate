import Foundation

/// What the keyboard and the app tell each other.
///
/// iOS gives a keyboard extension no microphone, so the app records and the two
/// meet in the shared app group: the keyboard leaves a request, the app keeps a
/// state the keyboard can read, and the finished text waits as one result until
/// the keyboard takes it. Nothing here is kept: a result is removed when it is
/// taken, and one nobody took is removed once it is stale.
enum DictationHandoff {
    static let appGroup = "group.io.forit.dictate"
    static let scheme = "io.forit.dictate"
    static let host = "dictate"

    /// A request the app has not picked up by now is abandoned.
    static let requestLifetime: TimeInterval = 30
    /// A result older than this is never typed: the person has moved on.
    static let resultLifetime: TimeInterval = 90

    /// Darwin notification names. They carry no payload; each one means "read the files".
    enum Signal: String, CaseIterable {
        /// Keyboard to app: start the request in the app group.
        case start = "io.forit.dictate.handoff.start"
        /// Keyboard to app: stop recording and transcribe.
        case stop = "io.forit.dictate.handoff.stop"
        /// Keyboard to app: stop recording and throw the audio away.
        case cancel = "io.forit.dictate.handoff.cancel"
        /// App to keyboard: the state or the result changed.
        case changed = "io.forit.dictate.handoff.changed"
    }

    /// `io.forit.dictate://dictate?request=<uuid>`, which the keyboard opens when the app is not already listening.
    static func openURL(for request: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "request", value: request.uuidString)]
        // A scheme, a host and one query item always form a URL.
        return components.url!
    }

    static func requestID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "request" })?.value
        else { return nil }
        return UUID(uuidString: value)
    }
}

struct DictationRequest: Codable, Equatable {
    let id: UUID
    let createdAt: Date
}

struct DictationState: Codable, Equatable {
    enum Phase: String, Codable {
        /// The microphone is off. The keyboard must open the app to dictate.
        case idle
        /// The microphone is on and nothing is being kept. The keyboard can start a dictation without opening the app.
        case ready
        case recording
        case transcribing
    }

    var phase: Phase
    /// The request being recorded or transcribed.
    var requestID: UUID?
    var updatedAt: Date
    /// When the app turns the microphone off if nobody dictates again.
    var readyUntil: Date?

    /// Whether the keyboard may ask for a dictation without opening the app.
    func acceptsRequests(at now: Date) -> Bool {
        guard phase == .ready, let readyUntil else { return false }
        return readyUntil > now
    }
}

struct DictationResult: Codable, Equatable {
    let requestID: UUID
    /// The text to type. Empty when nothing was heard or `failure` is set.
    let text: String
    /// Why there is no text, in words the keyboard can show.
    let failure: String?
    let createdAt: Date
}

/// The three files in the app group. Each is written whole and atomically.
struct DictationHandoffStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The shared store, or nil when the app group is unavailable (in the keyboard, without Full Access).
    static func shared(fileManager: FileManager = .default) -> DictationHandoffStore? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: DictationHandoff.appGroup) else {
            return nil
        }
        return DictationHandoffStore(directory: container.appendingPathComponent("Handoff", isDirectory: true))
    }

    private var requestURL: URL { directory.appendingPathComponent("request.json") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var resultURL: URL { directory.appendingPathComponent("result.json") }

    // MARK: Request (the keyboard writes, the app reads)

    func write(_ request: DictationRequest) throws {
        try save(request, to: requestURL)
    }

    /// The waiting request, or nil when there is none or it is stale.
    func request(now: Date = Date()) -> DictationRequest? {
        guard let request: DictationRequest = load(requestURL) else { return nil }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= -5, age <= DictationHandoff.requestLifetime else { return nil }
        return request
    }

    func clearRequest() {
        try? FileManager.default.removeItem(at: requestURL)
    }

    // MARK: State (the app writes, the keyboard reads)

    func write(_ state: DictationState) throws {
        try save(state, to: stateURL)
    }

    func state() -> DictationState? {
        load(stateURL)
    }

    // MARK: Result (the app writes, the keyboard takes)

    func write(_ result: DictationResult) throws {
        try save(result, to: resultURL)
    }

    /// The result for `id`, removed as it is returned. A stale result is removed and not returned;
    /// a result for another request is left for its own keyboard session.
    func takeResult(for id: UUID, now: Date = Date()) -> DictationResult? {
        guard let result: DictationResult = load(resultURL) else { return nil }
        if isStale(result, now: now) {
            try? FileManager.default.removeItem(at: resultURL)
            return nil
        }
        guard result.requestID == id else { return nil }
        try? FileManager.default.removeItem(at: resultURL)
        return result
    }

    /// Removes a result nobody took in time. Dictated text does not stay on disk.
    func removeStaleResult(now: Date = Date()) {
        guard let result: DictationResult = load(resultURL), isStale(result, now: now) else { return }
        try? FileManager.default.removeItem(at: resultURL)
    }

    private func isStale(_ result: DictationResult, now: Date) -> Bool {
        let age = now.timeIntervalSince(result.createdAt)
        return age < -5 || age > DictationHandoff.resultLifetime
    }

    // MARK: Files

    private func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func load<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
