import Foundation

/// Step 5, How careful: what has to pass before a part merges. Three levels, each a setting of the quality machinery a
/// goal already has (its bars and reviewers, evaluations, the pilot's PR reviewers and merge rules); nothing here is a
/// check of its own.
public enum CareLevel: String, Hashable, Sendable, Codable, CaseIterable {
    /// CI and one Copilot review.
    case quick
    /// CI, a code and a test reviewer on cheap models, and you on the last part.
    case standard
    /// Standard, strangers walking the DX, UX and docs, and you on every part.
    case thorough

    public var title: String {
        switch self {
        case .quick: "Quick"
        case .standard: "Standard"
        case .thorough: "Thorough"
        }
    }

    /// 1, 2, 3: the key that picks it.
    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

    /// The card's SF Symbol.
    public var symbol: String {
        switch self {
        case .quick: "bolt"
        case .standard: "checkmark.shield"
        case .thorough: "star"
        }
    }

    /// What has to pass, in a line.
    public var line: String {
        switch self {
        case .quick: "CI and one Copilot review"
        case .standard: "CI, code + test review by cheap models, you on the last part"
        case .thorough: "Standard + strangers walk DX, UX and docs; you on every part"
        }
    }

    /// Who it suits.
    public var suits: String {
        switch self {
        case .quick: "prototypes, internal"
        case .standard: "most work"
        case .thorough: "public APIs, products"
        }
    }

    /// What checks a part, as the card's glyphs: CI always; a reviewer (Copilot, or heed's); you; a stranger's walk.
    public var checks: [CareCheck] {
        switch self {
        case .quick: [.ci, .reviewer]
        case .standard: [.ci, .reviewer, .you]
        case .thorough: [.ci, .reviewer, .you, .stranger]
        }
    }

    /// Which parts wait for you before they merge.
    public var you: CareYou {
        switch self {
        case .quick: .none
        case .standard: .lastPart
        case .thorough: .everyPart
        }
    }

    /// `1`…`3`, or a level's name.
    public init?(word: String) {
        let key = word.lowercased().trimmingCharacters(in: .whitespaces)
        if let level = Self(rawValue: key) {
            self = level
        } else if let number = Int(key), (1 ... 3).contains(number) {
            self = Self.allCases[number - 1]
        } else {
            return nil
        }
    }
}

/// One kind of check, as a glyph on a level's card and in the legend under them.
public enum CareCheck: String, Hashable, Sendable, CaseIterable {
    case ci, reviewer, you, stranger

    public var symbol: String {
        switch self {
        case .ci: "checkmark"
        case .reviewer: "eye"
        case .you: "person.2"
        case .stranger: "questionmark"
        }
    }

    public var title: String {
        switch self {
        case .ci: "CI"
        case .reviewer: "reviewer"
        case .you: "you"
        case .stranger: "stranger walk"
        }
    }
}

/// Which parts' PRs wait for you: none, the last to merge, or every one.
public enum CareYou: String, Hashable, Sendable, Codable {
    case none, lastPart, everyPart
}

/// A level as the machinery it sets: the goal's bars (pins: a lens kept at its bar, or taken off with 0), which of its
/// reviewers run on cheap models, the walks evaluations make, who the pilot asks to review each PR (and trusts), which
/// parts wait for you, and what the reviews cost.
public struct CarePlan: Hashable, Sendable {
    public var level: CareLevel
    /// The goal's pins: every lens, at its bar or 0 (off). `GoalOps.pin` spawns the reviewers and evaluators for what
    /// is on.
    public var pins: [GoalLens: Double]
    /// Reviewer kinds that run on the cheap model.
    public var cheap: Set<ReviewerKind>
    /// The walks evaluations make (Thorough).
    public var walks: [EvaluationLens]
    /// The pilot's reviewers for each PR (`[pilot] reviewers`): Copilot for Quick.
    public var pilotReviewers: [String]
    /// Their logins, whose review counts as one (`trusted_reviewers`).
    public var trustedReviewers: [String]
    public var you: CareYou
    /// Parts under review show on the board (the `rev` state): Thorough, where a part's review is its own step.
    public var reviewParts: Bool

    /// The lenses a level keeps, beyond the code and test review every level past Quick has: security and performance
    /// when the profile says so (a cheap reviewer still), and for Thorough the walks the profile calls for (docs
    /// always, UX when people use it, DX when other code depends on it).
    public static func of(_ level: CareLevel, profile: GoalProfile?, table: GoalBarTable = .defaults) -> CarePlan {
        let profile = profile ?? .unknown
        let bars = profile.bars(table)
        var keep: [GoalLens] = []
        if level != .quick {
            keep = [.code, .tests]
            if profile.securitySensitive { keep.append(.security) }
            if profile.perfSensitive { keep.append(.perf) }
        }
        var walks: [EvaluationLens] = []
        if level == .thorough {
            keep.append(.docs)
            walks.append(.docsWalk)
            if profile.userFacing {
                keep.append(.ux)
                walks.append(.uxScreens)
            }
            if profile.stakes == .publicAPI {
                keep.append(.dx)
                walks.append(.dxFirstRun)
            }
        }
        var pins: [GoalLens: Double] = [:]
        for lens in GoalLens.allCases {
            pins[lens] = keep.contains(lens) ? max(bars[lens] ?? 0, 7) : 0
        }
        let cheap = Set(keep.compactMap { lens -> ReviewerKind? in
            let kind = ReviewerKind.of(lens)
            return kind.lens == lens ? kind : nil
        })
        return CarePlan(
            level: level, pins: pins, cheap: cheap, walks: walks,
            pilotReviewers: level == .quick ? ["copilot"] : [],
            trustedReviewers: level == .quick ? ["copilot-pull-request-reviewer"] : [], you: level.you,
            reviewParts: level == .thorough
        )
    }

    /// The lenses it keeps on, in order.
    public var lenses: [GoalLens] { pins.filter { $0.value > 0 }.keys.sorted() }

    /// What a part's reviews cost, in dollars: a Copilot review is near enough free; a cheap model's review about
    /// fifteen cents a lens; a walk about a dollar and a half, once for the goal.
    public static let copilotReview = 0.05
    public static let cheapReview = 0.175
    public static let walk = 1.5

    /// The reviews for `parts` parts, in dollars: what the card's foot shows.
    public func dollars(parts: Int) -> Double {
        let parts = Double(max(parts, 1))
        let reviews = lenses.count(where: { ![GoalLens.docs, .ux, .dx].contains($0) })
        let perPart = level == .quick ? Self.copilotReview : Double(reviews) * Self.cheapReview
        return perPart * parts + Double(walks.count) * Self.walk
    }

    /// Whether the part `id` of `draft` waits for you before it merges: every part (Thorough), the last to end in the
    /// schedule (Standard), none (Quick).
    public func waitsForYou(_ id: String, in draft: SplitDraft) -> Bool {
        switch you {
        case .none: false
        case .everyPart: true
        case .lastPart: Self.lastPart(draft) == id
        }
    }

    /// The part that ends last in the schedule (ties: the later in plan order).
    public static func lastPart(_ draft: SplitDraft) -> String? {
        let schedule = SplitSchedule.make(draft.parts)
        let order = draft.active.map(\.id)
        return schedule.slots.values.max { lhs, rhs in
            (lhs.end, order.firstIndex(of: lhs.id) ?? 0) < (rhs.end, order.firstIndex(of: rhs.id) ?? 0)
        }?.id
    }

    /// `$0.20 in reviews`.
    public static func dollarsText(_ value: Double) -> String {
        value >= 3 ? "$\(Int(value.rounded()))" : String(format: "$%.2f", value)
    }
}

/// The level heed suggests for a goal, and why, from its profile (`GoalProfile`) and how big the split is.
public struct CareSuggestion: Hashable, Sendable {
    public var level: CareLevel
    public var reason: String

    public init(level: CareLevel, reason: String) {
        self.level = level
        self.reason = reason
    }

    /// Other code depends on it, or people use it and it is a big change: Thorough. A spike, or internal work in a
    /// few parts: Quick. Everything else: Standard. `profile` nil: heed has not looked yet, and says so.
    public static func of(profile: GoalProfile?, parts: Int, repos: [String] = []) -> CareSuggestion {
        let where_ = repos.isEmpty ? "it" : repos.prefix(2).joined(separator: " and ")
        guard let profile else {
            return CareSuggestion(
                level: .standard,
                reason: "heed has not worked out what is riding on this goal yet, so the level most work takes"
            )
        }
        switch profile.stakes {
        case .publicAPI:
            return CareSuggestion(
                level: .thorough,
                reason: "other code depends on \(where_): a stranger should get through its first run and docs"
            )
        case .product where profile.userFacing && parts > 4:
            return CareSuggestion(
                level: .thorough, reason: "people use what this changes, across \(parts) parts: walk the screens"
            )
        case .spike:
            return CareSuggestion(level: .quick, reason: "it is a spike: it is there to find out, not to keep")
        case .internal where parts <= 3 && !profile.securitySensitive:
            return CareSuggestion(level: .quick, reason: "internal work in \(parts) small part\(parts == 1 ? "" : "s")")
        case .product:
            return CareSuggestion(
                level: .standard,
                reason: profile.userFacing ? "people use it, but the change is small" : "a product change"
                    + (profile.securitySensitive ? " that touches security: its reviewer runs too" : "")
            )
        case .internal:
            return CareSuggestion(
                level: .standard,
                reason: "internal work in \(parts) parts"
                    + (profile.securitySensitive ? " that touches security: its reviewer runs too" : "")
            )
        }
    }
}
