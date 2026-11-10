import Foundation

/// Callback ownership is independent of whether a browser operation is still
/// active. A cancelled callback must not fall through to media-file handling.
enum CompanyDictionaryCallbackRoute {
    static func matches(_ url: URL, bundleID: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // Foundation's URL.path can remove a trailing slash. The enrolled
        // callback has one exact path, so compare the encoded path unchanged.
        return components.scheme?.lowercased() == bundleID.lowercased()
            && components.host?.lowercased() == "oauth" && components.percentEncodedPath == "/callback"
            && components.user == nil && components.password == nil && components.port == nil
    }
}
