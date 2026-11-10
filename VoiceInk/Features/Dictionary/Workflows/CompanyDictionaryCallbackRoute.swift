import Foundation

/// Callback ownership is independent of whether a browser operation is still
/// active. A cancelled callback must not fall through to media-file handling.
enum CompanyDictionaryCallbackRoute {
    static func matches(_ url: URL, bundleID: String) -> Bool {
        url.scheme?.lowercased() == bundleID.lowercased()
            && url.host?.lowercased() == "oauth" && url.path == "/callback"
            && url.user == nil && url.password == nil && url.port == nil
    }
}
