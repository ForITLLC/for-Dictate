import Foundation

/// This adapter uses the app's existing login-Keychain service. Its setters do
/// not establish iCloud/ThisDeviceOnly/Data Protection semantics. The immutable
/// adapter is called only by FileCompanyDictionaryStore's serialized actor.
struct CompanyDictionaryKeychainStore: CompanyDictionaryCredentialStore {
    let account: String

    init(bundleID: String) { account = "support-company-session-v1." + bundleID }

    func read() -> CompanyDictionaryCredentialRead {
        switch KeychainService.shared.readData(forKey: account, syncable: false) {
        case .value(let data): .value(data)
        case .notFound: .notFound
        case .unavailable: .unavailable
        }
    }

    func save(_ data: Data) -> Bool {
        KeychainService.shared.save(data: data, forKey: account, syncable: false)
    }

    func delete() -> Bool { KeychainService.shared.delete(forKey: account, syncable: false) }
}
