import Foundation

/// The same clean-up the Mac app gives a transcript: bracketed noise and filler
/// words out, then paragraphs. Both steps are the Mac app's own files.
enum DictationText {
    static func clean(_ transcript: String) -> String {
        let filtered = TranscriptionOutputFilter.filter(transcript)
        guard !filtered.isEmpty else { return "" }
        return ParagraphFormatter.format(filtered)
    }
}
