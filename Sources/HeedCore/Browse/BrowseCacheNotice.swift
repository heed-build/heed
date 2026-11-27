import Foundation

/// What the list says when `browse.sqlite` cannot be opened: Browse still works, from memory, and says so for as long as
/// that is true.
public enum BrowseCacheNotice {
    /// A person's words for what went wrong.
    public static func reason(for error: Error) -> String {
        if let error = error as? SQLiteError { return error.message }
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? "\(error)" : text
    }

    /// The notice itself.
    public static func text(reason: String) -> String {
        "Browse's cache could not be opened: \(reason.trimmingCharacters(in: CharacterSet(charactersIn: " .")))."
            + " Working without it."
    }
}
