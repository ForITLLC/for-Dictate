import Foundation

/// The complete public record shape: deliberately excludes audio URLs, prompts and request metadata.
struct TinycastHistoryEntry: Encodable, Sendable {
    let id: String
    let timestamp: String
    let text: String
    let rawText: String
    let duration: TimeInterval
    let orderingDate: Date
    let orderingMilliseconds: Int64

    private enum CodingKeys: String, CodingKey { case id, timestamp, text, rawText, duration }

    init?(id: UUID, timestamp: Date, rawText: String, enhancedText: String?,
          duration: TimeInterval, status: String?) {
        guard HistorySuccessPolicy.isSuccessful(status: status, rawText: rawText),
            duration.isFinite, duration >= 0,
            let milliseconds = HistorySuccessPolicy.timestampMilliseconds(timestamp),
            let timestampString = TinycastHistorySnapshotBuilder.timestamp(timestamp)
        else { return nil }
        self.id = id.uuidString.lowercased()
        self.timestamp = timestampString
        self.text = HistorySuccessPolicy.preferredText(rawText: rawText, enhancedText: enhancedText)
        self.rawText = rawText
        self.duration = duration
        self.orderingDate = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        self.orderingMilliseconds = milliseconds
    }
}

enum TinycastHistorySnapshotError: Error { case invalidTimestamp, sizeLimitTooSmall, duplicateIdentifier }

/// Retains an encoded prefix within the cap. A bounded escaped-byte preflight prevents a huge
/// source record from allocating a huge temporary encoded JSON value. Callers may stream pages.
struct TinycastHistorySnapshotBuilder {
    static let maximumEncodedBytes = 8_388_608

    private struct Candidate {
        let entry: TinycastHistoryEntry
        let data: Data
    }

    private struct OrderingKey {
        let milliseconds: Int64
        let id: String
        init(_ entry: TinycastHistoryEntry) { milliseconds = entry.orderingMilliseconds; id = entry.id }
    }

    private var candidates: [Candidate] = []
    private var retainedIdentifiers: Set<String> = []
    private var bodyBytes = 0
    private(set) var encodedRecordCount = 0
    private var firstOmitted: OrderingKey?
    private let header = Data("{\"entries\":[".utf8)
    private let trueSuffix: Data
    private let falseSuffix: Data
    private let maximumBytes: Int

    /// Once the timestamp-ordered store scan is older than this, every remaining record
    /// follows a record already omitted by the size cap. Equal timestamps must still be scanned.
    var oldestRequiredTimestamp: Date? {
        firstOmitted.map { Date(timeIntervalSince1970: Double($0.milliseconds) / 1_000) }
    }

    init(updatedAt: Date, maximumBytes: Int = Self.maximumEncodedBytes) throws {
        guard let value = Self.timestamp(updatedAt) else { throw TinycastHistorySnapshotError.invalidTimestamp }
        let encodedDate = try JSONEncoder().encode(value)
        let tail = Data(",\"updatedAt\":".utf8) + encodedDate + Data("}".utf8)
        trueSuffix = Data("],\"schemaVersion\":1,\"truncated\":true".utf8) + tail
        falseSuffix = Data("],\"schemaVersion\":1,\"truncated\":false".utf8) + tail
        self.maximumBytes = min(maximumBytes, Self.maximumEncodedBytes)
        guard self.maximumBytes >= header.count + falseSuffix.count else {
            throw TinycastHistorySnapshotError.sizeLimitTooSmall
        }
    }

    mutating func append(_ entry: TinycastHistoryEntry) throws {
        let key = OrderingKey(entry)
        if let firstOmitted, !Self.precedes(key, firstOmitted) { return }
        guard !retainedIdentifiers.contains(entry.id) else {
            throw TinycastHistorySnapshotError.duplicateIdentifier
        }
        let entryLimit = maximumBytes - header.count - trueSuffix.count
        guard try Self.encodedEntrySize(entry, upTo: entryLimit) != nil else {
            markOmitted(key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry)
        encodedRecordCount += 1
        retainedIdentifiers.insert(entry.id)
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Self.precedes(key, OrderingKey(candidates[middle].entry)) { upper = middle }
            else { lower = middle + 1 }
        }
        candidates.insert(Candidate(entry: entry, data: data), at: lower)
        bodyBytes += data.count + (candidates.count > 1 ? 1 : 0)

        while header.count + bodyBytes + trueSuffix.count > maximumBytes {
            let removedKey = OrderingKey(removeLastCandidate().entry)
            markOmitted(removedKey)
        }
    }

    mutating func encodedSnapshot() -> Data {
        // `false` is one byte longer than `true`. Keep the whole-record prefix when this
        // exact envelope boundary is the byte that would exceed the consumer's read cap.
        if firstOmitted == nil, header.count + bodyBytes + falseSuffix.count > maximumBytes,
            !candidates.isEmpty {
            firstOmitted = OrderingKey(removeLastCandidate().entry)
        }
        var data = header
        for (index, candidate) in candidates.enumerated() {
            if index > 0 { data.append(0x2c) }
            data.append(candidate.data)
        }
        data.append(firstOmitted == nil ? falseSuffix : trueSuffix)
        return data
    }

    private static func precedes(_ lhs: OrderingKey, _ rhs: OrderingKey) -> Bool {
        lhs.milliseconds == rhs.milliseconds ? lhs.id < rhs.id : lhs.milliseconds > rhs.milliseconds
    }

    private mutating func removeLastCandidate() -> Candidate {
        let removed = candidates.removeLast()
        retainedIdentifiers.remove(removed.entry.id)
        bodyBytes -= removed.data.count + (candidates.isEmpty ? 0 : 1)
        return removed
    }

    private mutating func markOmitted(_ key: OrderingKey) {
        if firstOmitted == nil || Self.precedes(key, firstOmitted!) { firstOmitted = key }
        // An oversized earlier row blocks every following row, even when those rows fit.
        while let last = candidates.last, let boundary = firstOmitted,
            !Self.precedes(OrderingKey(last.entry), boundary) {
            _ = removeLastCandidate()
        }
    }

    /// Size the JSON strings by UTF-8 bytes without materializing escaped or lowercased copies.
    /// ASCII escapes match JSONEncoder's output; unescaped Unicode is counted in UTF-8 bytes.
    /// Stop as soon as the complete record cannot fit, including its fixed keys and punctuation.
    static func encodedEntrySize(_ entry: TinycastHistoryEntry, upTo limit: Int) throws -> Int? {
        var count = "{\"duration\":,\"id\":,\"rawText\":,\"text\":,\"timestamp\":}".utf8.count
        count += try JSONEncoder().encode(entry.duration).count
        guard count <= limit else { return nil }
        for value in [entry.id, entry.timestamp, entry.text, entry.rawText] {
            count += 2 // String quotes.
            guard count <= limit else { return nil }
            for byte in value.utf8 {
                switch byte {
                case 0x22, 0x5c, 0x08, 0x0c, 0x0a, 0x0d, 0x09: count += 2
                case 0x00...0x1f: count += 6
                default: count += 1
                }
                if count > limit { return nil }
            }
        }
        return count
    }

    static func timestamp(_ date: Date) -> String? {
        // The v1 consumer accepts real UTC dates in the four-digit ISO calendar range.
        guard let normalized = HistorySuccessPolicy.normalizedTimestamp(date) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: normalized)
    }
}
