import Foundation

/// Text someone else wrote: a review comment, a PR's title or body, an issue, a check's summary, a CI log line. It
/// keeps where it came from and who wrote it, and only leaves in a form fit for where it goes: `display` for the UI,
/// `fenced` for a prompt (an agent's or a model's). The raw string stays inside; `unsafeRaw` is the one way to the
/// bytes, for the few places that need them as written (a reply quoting GitHub back to GitHub, a file a tool reads),
/// and `ExternalTextTests` keeps it to the files listed there.
///
/// Deliberately not `CustomStringConvertible` or `ExpressibleByStringLiteral`, so it never turns into a `String` by
/// interpolation or by accident.
public struct ExternalText: Hashable, Sendable {
    /// Where it came from: named in the fence, so the model knows what it reads.
    public enum Source: String, Hashable, Sendable, Codable, CaseIterable {
        case comment, review, thread, pullTitle = "pull title", pullBody = "pull body", issueTitle = "issue title"
        case issueBody = "issue body", checkSummary = "check summary", ciLog = "ci log"
        case commitMessage = "commit message", branchName = "branch name", repoFile = "repo file", diff
        /// Your own note on a hunk, typed in heed.
        case note
    }

    /// How far heed trusts who wrote it, from GitHub's author association and the author's type.
    public enum Trust: String, Hashable, Sendable, Codable, CaseIterable {
        /// The repo's owner, or you.
        case owner
        /// A collaborator on the repo (`COLLABORATOR`): someone it gave write access to.
        case collaborator
        /// A member of the organisation that owns the repo (`MEMBER`). Membership alone says nothing about write
        /// access: Autopilot counts a member as someone who can write only once `gh` says their permission on the
        /// repo is write, maintain or admin (`PullTrust`).
        case member
        /// A GitHub App or a `[bot]` account.
        case bot
        /// Anyone else: `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `NONE`, or not known.
        case stranger

        /// Owner and collaborators, who can write to the repo by their association alone: their review comments go
        /// to an agent on their own; the rest wait for you (a member's too, until heed has checked their permission).
        public var isCollaborator: Bool { self == .owner || self == .collaborator }

        /// GitHub's `authorAssociation`, and whether the author is a bot (`__typename` `Bot`, or a `[bot]` login).
        public static func from(association: String?, isBot: Bool) -> Trust {
            if isBot { return .bot }
            switch association?.uppercased() {
            case "OWNER": return .owner
            case "COLLABORATOR": return .collaborator
            case "MEMBER": return .member
            default: return .stranger
            }
        }
    }

    public struct Author: Hashable, Sendable, Codable {
        /// The GitHub login (an app's slug for a check), nil when not known.
        public var login: String?
        public var trust: Trust

        public init(login: String?, trust: Trust) {
            self.login = login
            self.trust = trust
        }

        /// You, in heed.
        public static let you = Author(login: nil, trust: .owner)

        /// Someone heed knows nothing about.
        public static let unknown = Author(login: nil, trust: .stranger)

        /// An author as GitHub's GraphQL gives one: `{ login __typename }`, with the node's `authorAssociation`.
        public static func github(_ author: [String: Any]?, association: String?) -> Author {
            let login = author?["login"] as? String
            let isBot = author?["__typename"] as? String == "Bot" || (login?.hasSuffix("[bot]") ?? false)
            return Author(login: login, trust: .from(association: association, isBot: isBot))
        }

        /// `@login`, or `someone` when not known.
        public var handle: String { login.map { "@" + $0 } ?? "someone" }
    }

    private let raw: String
    public let source: Source
    public let author: Author
    /// For the UI: control characters, ANSI and OSC escapes, bidi overrides and zero-width characters stripped, and
    /// every line break (`\r\n`, `\r`, U+2028) a `\n`. Stripped once, here: views read it on every redraw. It shares
    /// `raw`'s storage when stripping changed nothing.
    public let display: String

    public init(_ text: String, source: Source, author: Author) {
        raw = text
        self.source = source
        self.author = author
        let stripped = Self.strip(text)
        display = stripped.unicodeScalars.elementsEqual(text.unicodeScalars) ? text : stripped
    }

    /// Equal by what was written, where and by whom, as before `display` was kept: it follows from `raw`.
    public static func == (lhs: ExternalText, rhs: ExternalText) -> Bool {
        lhs.raw == rhs.raw && lhs.source == rhs.source && lhs.author == rhs.author
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(raw)
        hasher.combine(source)
        hasher.combine(author)
    }

    /// Nothing, from nobody: for a missing title or body.
    public static func empty(_ source: Source) -> ExternalText { ExternalText("", source: source, author: .unknown) }

    /// For a prompt: stripped as `display`, then fenced so its content cannot end the fence (see `Prompt`).
    public var fenced: Prompt { Prompt(self) }

    /// The bytes as written, for the places that need them unchanged. Allowed only in the files `ExternalTextTests`
    /// lists.
    public var unsafeRaw: String { raw }

    public var isEmpty: Bool { display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The same text by the same author, trusted as `trust`: your own comment, known by your login.
    func trusted(_ trust: Trust) -> ExternalText {
        ExternalText(raw, source: source, author: Author(login: author.login, trust: trust))
    }

    /// The same text, cut: provenance kept.
    public func prefix(_ count: Int) -> ExternalText {
        ExternalText(String(display.prefix(count)), source: source, author: author)
    }

    /// The same text, its end kept.
    public func suffix(_ count: Int) -> ExternalText {
        ExternalText(String(display.suffix(count)), source: source, author: author)
    }

    /// The first line, cut to `limit` characters with `…` when longer.
    public func firstLine(limit: Int = .max) -> ExternalText {
        let first = display.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let short = first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
        return ExternalText(short, source: source, author: author)
    }

    /// On one line: every line break a space.
    public var oneLine: ExternalText {
        ExternalText(display.replacingOccurrences(of: "\n", with: " "), source: source, author: author)
    }

    /// The lines, each its own text.
    public var lines: [ExternalText] {
        display.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ExternalText(String($0), source: source, author: author) }
    }

    /// Whether the displayed text contains `other` (case-insensitive), for search and filters.
    public func contains(_ other: String) -> Bool { display.localizedCaseInsensitiveContains(other) }

    // MARK: Stripping

    /// `text` without what a terminal, a model or a reader would take as something other than text: ANSI CSI, OSC,
    /// DCS and other escape sequences, C0 and C1 control characters but `\n` and `\t`, bidi embeddings, overrides and
    /// isolates, zero-width characters (a zero-width joiner stays inside an emoji), invisible tag characters (kept in
    /// a flag), and soft hyphens. Line breaks become `\n`.
    public static func strip(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var inFlag = false
        func at(_ offset: Int) -> UInt32? { index + offset < scalars.count ? scalars[index + offset].value : nil }
        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            switch value {
            case 0x0D: // \r and \r\n
                out.append("\n")
                index += at(1) == 0x0A ? 2 : 1
                inFlag = false
                continue
            case 0x2028, 0x2029, 0x85:
                out.append("\n")
            case 0x1B:
                index = skipEscape(scalars, from: index)
                inFlag = false
                continue
            case 0x9B: // C1 CSI
                index = skipCSI(scalars, from: index + 1)
                continue
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F: // C1 DCS, SOS, OSC, PM, APC
                index = skipString(scalars, from: index + 1)
                continue
            case 0x09, 0x0A:
                out.append(scalar)
            case 0x00 ... 0x1F, 0x7F, 0x80 ... 0x9F:
                break
            case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
                break
            case 0x200B, 0x200C, 0x2060 ... 0x2064, 0xFEFF, 0x180E, 0x00AD:
                break
            case 0x200D:
                // A joiner between emoji (a family, a profession) is part of the picture; anywhere else it hides. The
                // emoji may end in its presentation selector, U+FE0F (the rainbow flag, a heart on fire).
                let emoji = out.last?.value == 0xFE0F ? out.dropLast().last : out.last
                if let emoji, emoji.properties.isEmoji, emoji.value > 0x7F { out.append(scalar) }
            case 0xE0000 ... 0xE007F:
                // Tag characters only spell a subdivision flag (England's) after a black flag.
                if inFlag { out.append(scalar) }
                if value == 0xE007F { inFlag = false }
                index += 1
                continue
            default:
                out.append(scalar)
            }
            inFlag = value == 0x1F3F4
            index += 1
        }
        return String(out)
    }

    /// Past an escape sequence that starts with ESC at `start`.
    private static func skipEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        let next = start + 1
        guard next < scalars.count else { return next }
        switch scalars[next].value {
        case 0x5B: return skipCSI(scalars, from: next + 1) // [
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: return skipString(scalars, from: next + 1) // ] P X ^ _
        default:
            // ESC, intermediates (0x20–0x2F), then one final character.
            var index = next
            while index < scalars.count, (0x20 ... 0x2F).contains(scalars[index].value) {
                index += 1
            }
            return index < scalars.count && (0x30 ... 0x7E).contains(scalars[index].value) ? index + 1 : index
        }
    }

    /// Past a CSI's parameters and intermediates to its final character.
    private static func skipCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if (0x40 ... 0x7E).contains(value) { return index + 1 }
            guard (0x20 ... 0x3F).contains(value) else { return index }
            index += 1
        }
        return index
    }

    /// Past an OSC's (or DCS's) string to its terminator: BEL, ESC \ or ST.
    private static func skipString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            switch scalars[index].value {
            case 0x07, 0x9C: return index + 1
            case 0x1B: return index + 1 < scalars.count && scalars[index + 1].value == 0x5C ? index + 2 : index + 1
            default: index += 1
            }
        }
        return index
    }
}

/// `String(describing:)` and `dump` show where it is from, never the text.
extension ExternalText: CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["source": source, "author": author]) }
}

extension ExternalText: Codable {
    private enum CodingKeys: String, CodingKey { case text, source, author }

    /// Caches written while this was a plain string still load: from someone heed knows nothing about.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self.init(text, source: .comment, author: .unknown)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            container.decode(String.self, forKey: .text), source: container.decode(Source.self, forKey: .source),
            author: container.decode(Author.self, forKey: .author)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .text)
        try container.encode(source, forKey: .source)
        try container.encode(author, forKey: .author)
    }
}
