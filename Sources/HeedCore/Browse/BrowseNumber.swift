import Foundation

/// Counts as the rail and the list header say them: `842`, `1.2K`, `579K`, `143M`. The decimal point is always a
/// point, whatever the locale, and a number is rounded down so a count is never overstated.
public enum BrowseNumber {
    public static func compact(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let n = abs(value)
        guard n >= 1000 else { return "\(sign)\(n)" }
        let (divisor, suffix): (Int, String) = n >= 1_000_000_000 ? (1_000_000_000, "B")
            : n >= 1_000_000 ? (1_000_000, "M") : (1000, "K")
        // One decimal below ten of the unit, none from ten up; a trailing `.0` is dropped.
        if n < divisor * 10 {
            let tenths = n * 10 / divisor
            return tenths % 10 == 0 ? "\(sign)\(tenths / 10)\(suffix)" : "\(sign)\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        return "\(sign)\(n / divisor)\(suffix)"
    }

    /// The exact number with thousands separators, for the tooltip: `579,689`.
    public static func exact(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }
}
