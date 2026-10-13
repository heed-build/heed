import Foundation

/// The time the UI and fixtures read. Real time, except when screenshots pin it (`fixed`), so ages, "synced … ago"
/// and dates come out the same on every run.
public enum Clock {
    public nonisolated(unsafe) static var fixed: Date?

    public static var now: Date { fixed ?? Date() }

    /// "2 minutes ago" (`numeric`) or "yesterday" (`named`), relative to `now`.
    public static func relative(_ date: Date, named: Bool = false) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = named ? .named : .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
