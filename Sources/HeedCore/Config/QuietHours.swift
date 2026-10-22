import Foundation

/// `[attention] quiet = "22:00-07:00"`: hours in which Heed posts no notifications. The span may cross midnight; the
/// start is in it, the end is not.
public struct QuietHours: Equatable, Sendable, CustomStringConvertible {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int

    public init?(start: Int, end: Int) {
        guard (0 ..< 1440).contains(start), (0 ..< 1440).contains(end), start != end else { return nil }
        self.start = start
        self.end = end
    }

    /// `HH:MM-HH:MM`, 24-hour.
    public init?(parsing text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let start = Self.minutes(parts[0]), let end = Self.minutes(parts[1]) else { return nil }
        self.init(start: start, end: end)
    }

    private static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let hours = Int(parts[0]),
              let minutes = Int(parts[1]), (0 ..< 24).contains(hours), (0 ..< 60).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }

    /// Whether `date`, on the local clock (`calendar`), falls in these hours.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (start ..< end).contains(minute) : minute >= start || minute < end
    }

    public var description: String {
        func text(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        return "\(text(start))-\(text(end))"
    }
}

/// `[attention]`: what may ask for your attention, and when not. Only `quiet` so far; it applies to every notification.
public struct AttentionSettings: Equatable, Sendable {
    public var quiet: QuietHours?

    public init(quiet: QuietHours? = nil) {
        self.quiet = quiet
    }
}
