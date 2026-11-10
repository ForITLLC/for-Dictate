import Foundation

/// Requests cannot name an arbitrary host or path. Credentials belong only to Support.
struct CompanyDictionaryRequest: Sendable {
    enum Endpoint: Sendable {
        case mint, identity, dictionary, revoke

        var path: String {
            switch self {
            case .mint, .revoke: "/api/app/v1/session"
            case .identity: "/api/app/v1/me"
            case .dictionary: "/api/v1/company-dictionary"
            }
        }

        var method: String {
            switch self {
            case .mint: "POST"
            case .revoke: "DELETE"
            case .identity, .dictionary: "GET"
            }
        }

        var maximumBytes: Int {
            switch self {
            case .dictionary: 16 * 1_024 * 1_024
            case .identity: 256 * 1_024
            case .mint, .revoke: 16 * 1_024
            }
        }
    }

    static let origin = "https://support.forit.io"
    let endpoint: Endpoint
    let credential: String
    var body: Data? = nil
    var etag: String? = nil

    func urlRequest() throws -> URLRequest {
        guard !credential.isEmpty, credential.utf8.count <= 32 * 1_024,
              !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: Self.origin + endpoint.path),
              url.scheme == "https", url.host == "support.forit.io", url.port == nil,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil
        else { throw CompanyDictionaryTransportError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = endpoint.method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            guard endpoint.path == "/api/v1/company-dictionary", Self.isStrongETag(etag)
            else { throw CompanyDictionaryTransportError.invalidRequest }
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let body {
            guard endpoint.method == "POST", body.count <= 4_096 else {
                throw CompanyDictionaryTransportError.invalidRequest
            }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func isStrongETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count >= 3 && bytes.count <= 1_024 && bytes.first == 0x22 && bytes.last == 0x22
            && bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80 }
    }
}

struct CompanyDictionaryHTTPResponse: Sendable {
    let status: Int
    /// Only ETag and Retry-After are retained by the production transport.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum CompanyDictionaryTransportError: Error {
    case invalidRequest, unavailable, invalidResponse, bodyTooLarge, redirectRejected
}

protocol CompanyDictionaryTransport: Sendable {
    func send(_ request: CompanyDictionaryRequest) async throws -> CompanyDictionaryHTTPResponse
}

/// A fresh ephemeral session for each bounded transfer. There is no retry layer,
/// automatic credential/cookie storage, redirect following, or URLCache fallback.
struct SupportCompanyDictionaryTransport: CompanyDictionaryTransport {
    // A controlled URLProtocol can exercise the real session/delegate in
    // hermetic tests. Normal app construction uses the system HTTP protocols.
    private let protocolClasses: @Sendable () -> [AnyClass]

    init(protocolClasses: @escaping @Sendable () -> [AnyClass] = { [] }) {
        self.protocolClasses = protocolClasses
    }

    func send(_ request: CompanyDictionaryRequest) async throws -> CompanyDictionaryHTTPResponse {
        let transfer = CompanyDictionaryTransfer(maximumBytes: request.endpoint.maximumBytes,
                                                 protocolClasses: protocolClasses())
        let urlRequest = try request.urlRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(urlRequest, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return configuration
    }
}

/// URLSession supplies decompressed bytes to this delegate. Enforce the cap as
/// they arrive, before constructing or decoding the complete response.
private final class CompanyDictionaryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let protocolClasses: [AnyClass]
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CompanyDictionaryHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var cancelled = false
    // The remaining fields are touched on the session's serial delegate queue.
    private var response: HTTPURLResponse?
    private var bytes = Data()

    init(maximumBytes: Int, protocolClasses: [AnyClass]) {
        self.maximumBytes = maximumBytes
        self.protocolClasses = protocolClasses
    }

    func start(_ request: URLRequest, continuation: CheckedContinuation<CompanyDictionaryHTTPResponse, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let configuration = SupportCompanyDictionaryTransport.configuration()
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(CompanyDictionaryTransportError.invalidResponse))
            return
        }
        guard response.url == dataTask.originalRequest?.url else {
            completionHandler(.cancel)
            finish(.failure(CompanyDictionaryTransportError.invalidResponse))
            return
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            // Authorization was refused at the headers. Oversized, broken or
            // missing error bodies must never turn this into stale-cache use.
            completionHandler(.cancel)
            finish(.success(.init(status: response.statusCode, headers: [:], body: Data())))
            return
        }
        // Content-Length is an early refusal only; the delivered-byte cap below
        // still applies to compressed/unknown-length responses.
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(CompanyDictionaryTransportError.bodyTooLarge))
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes - bytes.count else {
            finish(.failure(CompanyDictionaryTransportError.bodyTooLarge))
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(CompanyDictionaryTransportError.redirectRejected))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep platform TLS trust validation. Never answer an HTTP credential
        // challenge with another credential or an interactive account prompt.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Preserve an actual HTTP 401 even when Foundation presents it as a
            // credential challenge; it must invalidate cached company access.
            if let response = challenge.failureResponse as? HTTPURLResponse, response.statusCode == 401 {
                finish(.success(.init(status: 401, headers: [:], body: Data())))
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(CompanyDictionaryTransportError.unavailable)) }
            return
        }
        guard let response else {
            finish(.failure(CompanyDictionaryTransportError.invalidResponse))
            return
        }
        var headers: [String: String] = [:]
        for name in ["ETag", "Retry-After"] {
            if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
        }
        finish(.success(.init(status: response.statusCode, headers: headers, body: bytes)))
    }

    private func finish(_ result: Result<CompanyDictionaryHTTPResponse, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
