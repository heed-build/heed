import Foundation

/// What `/` matches: every word of the query must appear (case-insensitively) in one of a row's fields, so
/// `atlas fix` finds a atlas session on fix/anchors.
public enum FilterQuery {
    public static func matches(_ query: String, _ fields: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fields.map { $0.lowercased() }
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }

    /// The query with its last word removed (`<C-w>`).
    public static func droppingLastWord(_ query: String) -> String {
        var text = query
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        while let last = text.last, !last.isWhitespace {
            text.removeLast()
        }
        return text
    }
}
