import Foundation

/// What the keyboard types before dictated text so it does not run into the word already there.
enum InsertionSpacing {
    static func separator(after contextBeforeInput: String?, before text: String) -> String {
        guard let last = contextBeforeInput?.last, let first = text.first else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        if first.isWhitespace || first.isPunctuation { return "" }
        if "([{\"'“‘".contains(last) { return "" }
        return " "
    }
}
