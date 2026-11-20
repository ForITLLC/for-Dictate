import Foundation

/// Support's complete schema-1 response, separate from the local recognition catalog.
/// Decoding validates the server DTO without projecting, persisting or fetching it.
struct CompanyDictionarySnapshot: Decodable, Equatable, Sendable {
    static let supportCompanyID = "f0817001-0001-0001-0001-000000000001"

    let schemaVersion: Int
    let companyID: String
    /// The complete quoted ETag, including its representation/capability suffix.
    let version: String
    let terms: [Term]
    let total: Int
    let updatedAt: String?
    let canEdit: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion, version, terms, total, canEdit
        case companyID = "companyId", updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        companyID = try values.decode(String.self, forKey: .companyID)
        version = try values.decode(String.self, forKey: .version)
        terms = try values.decode([Term].self, forKey: .terms)
        total = try values.decode(Int.self, forKey: .total)
        guard values.contains(.updatedAt) else { throw CompanyDictionaryValidation.invalid(decoder) }
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        canEdit = try values.decode(Bool.self, forKey: .canEdit)
        guard schemaVersion == 1, companyID == Self.supportCompanyID,
              terms.count <= 1_000, total == terms.count,
              Set(terms.map(\.id)).count == terms.count,
              CompanyDictionaryValidation.etag(version),
              updatedAt.map(CompanyDictionaryValidation.timestamp) ?? true,
              terms.isEmpty || updatedAt != nil
        else { throw CompanyDictionaryValidation.invalid(decoder) }
    }

    struct Term: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable { case term, person, product }

        let id: String
        let canonicalSpelling: String
        let spokenForms: [String]
        let meaning: String
        let kind: Kind
        let isActive: Bool
        let revision: Int
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case meaning, kind, revision
            case id = "term_id", canonicalSpelling = "canonical_spelling"
            case spokenForms = "spoken_forms", isActive = "is_active", updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            canonicalSpelling = try values.decode(String.self, forKey: .canonicalSpelling)
            spokenForms = try values.decode([String].self, forKey: .spokenForms)
            meaning = try values.decode(String.self, forKey: .meaning)
            kind = try values.decode(Kind.self, forKey: .kind)
            isActive = try values.decode(Bool.self, forKey: .isActive)
            revision = try values.decode(Int.self, forKey: .revision)
            updatedAt = try values.decode(String.self, forKey: .updatedAt)
            guard CompanyDictionaryValidation.identifier(id), (1...2_147_483_647).contains(revision),
                  CompanyDictionaryValidation.text(canonicalSpelling, limit: 100),
                  CompanyDictionaryValidation.text(meaning, limit: 500, allowEmpty: true),
                  spokenForms.count <= 12,
                  spokenForms.allSatisfy({ CompanyDictionaryValidation.text($0, limit: 100) }),
                  Set(spokenForms.map(CompanyDictionaryValidation.normalized)).count == spokenForms.count,
                  CompanyDictionaryValidation.timestamp(updatedAt)
            else { throw CompanyDictionaryValidation.invalid(decoder) }
        }
    }
}

private enum CompanyDictionaryValidation {
    // ECMAScript WhiteSpace + LineTerminator, matching Support's trim()/\s folding.
    static let whitespace = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
        "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
        "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.components(separatedBy: whitespace)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    static func text(_ value: String, limit: Int, allowEmpty: Bool = false) -> Bool {
        value.utf16.count <= limit && normalized(value).utf16.count <= limit
            && (allowEmpty || !value.trimmingCharacters(in: whitespace).isEmpty)
            && !value.unicodeScalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }
    }

    static func identifier(_ value: String) -> Bool {
        value != "00000000-0000-0000-0000-000000000000"
            && value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                           options: .regularExpression) != nil
    }

    static func etag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3, bytes.first == 0x22, bytes.last == 0x22 else { return false }
        // Preserve opaque quoted HTTP etagc; do not parse it as a numeric revision.
        return bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80 }
    }

    static func timestamp(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",
                          options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Support company dictionary snapshot."))
    }
}
