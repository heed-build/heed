import Foundation

/// What a finished turn leaves behind. An agent that ends its turn with a plain-text question ("Should I also update
/// the docs?") is waiting on you as much as one in a question dialog, but its hooks only say the turn is done. Heed
/// reads the turn's last words and, when they ask you something, shows the session as asking (guessed: it is read
/// from text, so it gets the dotted ring).
public enum TurnEnd {
    /// The reason a session shows when its turn ended on a question.
    public static let question = "asked a question"

    /// What a turn that ended with `lastWords` reports: asking when they ask you something, else done.
    public static func kind(lastWords: String?) -> HookMessage.Kind {
        guard let lastWords, asksYou(lastWords) else { return .state(.done, reason: nil) }
        return .guess(.asking, reason: question)
    }

    /// The most of the end a question is read from: the last two lines, or a line asking above options.
    static let reach = 300

    /// Whether the closing words of an agent's turn ask you something. Only the end counts: trailing code blocks are
    /// dropped, then the last two lines (at most the last 300 characters) are read. A question mark at the end, a
    /// question to you in those lines, or a phrase that waits on you ("should I", "want me to", "please confirm")
    /// counts; the generic closers agents sign off with ("let me know if you need anything else") do not.
    ///
    /// Lines are read from the end and normalized only when read. A line ending a question ("Which do you prefer:"
    /// above options) is read by its last 300 characters too, and sign-offs are found sentence by sentence, so no
    /// pattern rescans a long line from every position (this runs in the agent's Stop hook).
    public static func asksYou(_ text: String) -> Bool {
        var fromEnd = linesFromEnd(withoutTrailingCode(text))
        var read: [String] = []
        // Options listed after the question ("Which do you prefer?" then 1., 2., 3.): the question is what counts.
        var options = 0
        var lead: String?
        while let line = fromEnd.next() {
            read.append(line)
            guard matches(line, optionLine, anchored: true) else {
                lead = line
                break
            }
            options += 1
        }
        if options > 0, let lead {
            if lead.hasSuffix("?") { return true }
            let end = String(lead.suffix(reach))
            if lead.hasSuffix(":"), matches(end, leadAsks) || phrases.contains(where: { matches(end, $0) }) {
                return true
            }
        }
        // The last two lines that say something once the sign-offs are gone, oldest first.
        var last: [String] = []
        func keep(_ line: String) {
            let line = withoutClosers(line)
            if line.contains(where: { $0.isLetter || $0.isNumber }) { last.insert(line, at: 0) }
        }
        for line in read where last.count < 2 {
            keep(line)
        }
        while last.count < 2, let line = fromEnd.next() {
            keep(line)
        }
        guard !last.isEmpty else { return false }
        var tail = last.joined(separator: "\n")
        if tail.count > reach { tail = String(tail.suffix(reach)) }
        if matches(tail, endsWithQuestion) { return true }
        if questions(in: tail).contains(where: { matches($0, addressed) }) { return true }
        return phrases.contains { matches(tail, $0) }
    }

    // MARK: Pieces

    /// Drops fenced code blocks at the end (a question followed by the diff it is about still ends on the question).
    static func withoutTrailingCode(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("```") || text.hasSuffix("~~~") {
            let fence = String(text.suffix(3))
            let body = text.dropLast(3)
            guard let open = body.range(of: fence, options: .backwards) else { break }
            text = String(body[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The lines of `text` that are not empty once normalized and trimmed, the last first: the lines of
    /// `normalized(text)`, each normalized only when it is read. Normalizing works within a line break, so each piece
    /// between breaks is normalized alone; a break whose piece ends in `\r` once normalized (`\r\n`, or `\r**\n` with
    /// the emphasis gone) is one character with it and does not end a line.
    static func linesFromEnd(_ text: String) -> LinesFromEnd {
        LinesFromEnd(text)
    }

    struct LinesFromEnd: IteratorProtocol {
        private var pieces: ReversedCollection<[Substring.UnicodeScalarView]>.Iterator
        private var ahead: String?

        init(_ text: String) {
            pieces = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).reversed()
                .makeIterator()
        }

        mutating func next() -> String? {
            while var line = ahead ?? nextPiece() {
                ahead = nil
                while let before = nextPiece() {
                    guard before.unicodeScalars.last == "\r" else {
                        ahead = before
                        break
                    }
                    line = before + "\n" + line
                }
                line = line.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { return line }
            }
            return nil
        }

        private mutating func nextPiece() -> String? {
            pieces.next().map { TurnEnd.normalized(String(String.UnicodeScalarView($0))) }
        }
    }

    /// Lowercased, with straight quotes, inline code reduced to a word (so `optional?` is not a question) and
    /// markdown emphasis gone.
    static func normalized(_ text: String) -> String {
        var text = text.lowercased()
        for (curly, straight) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            text = text.replacingOccurrences(of: curly, with: straight)
        }
        text = replacing(inlineCode, in: text, with: "code")
        return replacing(emphasis, in: text, with: "")
    }

    /// The question sentences in `text`: each runs from the previous sentence end to a `?` that ends a sentence (not
    /// one inside a URL).
    static func questions(in text: String) -> [String] {
        guard let questionSentence else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return questionSentence.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// `line` without the sentences that sign off: a sentence (the text up to `.`, `!`, `?` or a line break, with the
    /// `.`, `!` and `?` that end it) goes when it holds one of the `closers`. A line break (a `\r\n` line has one) is
    /// kept.
    static func withoutClosers(_ line: String) -> String {
        var kept = String.UnicodeScalarView()
        var rest = line.unicodeScalars[...]
        while let first = rest.first {
            if first == "\n" {
                kept.append(first)
                rest = rest.dropFirst()
                continue
            }
            let words = rest.prefix { !sentenceEnds.contains($0) && $0 != "\n" }
            let ends = rest[words.endIndex...].prefix { sentenceEnds.contains($0) }
            let sentence = String(String.UnicodeScalarView(words))
            if !closers.contains(where: { matches(sentence, $0) }) { kept.append(contentsOf: rest[..<ends.endIndex]) }
            rest = rest[ends.endIndex...]
        }
        return String(kept).trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ text: String, _ regex: NSRegularExpression?, anchored: Bool = false) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: anchored ? [.anchored] : [], range: range) != nil
    }

    private static func replacing(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static let inlineCode = compiled(#"`[^`\n]*`"#)
    private static let emphasis = compiled(#"\*\*|__|(?<![\w])[*_]|[*_](?![\w])"#)
    private static let questionSentence = compiled(#"[^.!?\n]*\?(?=[\s)"'\]]|$)"#)
    private static let leadAsks = compiled(#"\b(which|what|whether)\b.*\byou\b"#)
    private static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?"]

    /// A `?` at the very end, optionally inside closing brackets, quotes or emphasis.
    static let endsWithQuestion = compiled(#"\?[\s)\]"'»]*$"#)

    /// A question sentence that speaks to you, or about what the agent should do: rhetorical questions in a summary
    /// ("Why did it fail? The cache was stale.") have neither.
    static let addressed = compiled(#"\b(you|your|i|me|we|us)\b"#)

    /// `1. Option`, `b) Option`, `- Option`.
    static let optionLine = compiled(#"^([0-9]+[.)]|[a-h][.)]|[-•])\s"#)

    /// Phrases that wait on you even without a question mark.
    static let phrases = [
        #"\b(should|shall|can|may) i\b"#,
        #"\bwould you (like|prefer|rather)\b"#,
        #"\bdo you (want|prefer|need)\b"#,
        #"\b(want|like) me to\b"#,
        #"\bwhich (option|approach|one|way|of these|direction)\b.*\b(prefer|want|choose|pick|go with)\b"#,
        #"\blet me know (if|whether|which|what|how) you\b"#,
        #"\b(please|can you|could you) (confirm|clarify|choose|pick|decide)\b"#,
        #"\bawaiting your (approval|go-ahead|go ahead|input|confirmation|decision|answer|feedback)\b"#,
        #"\bwaiting (for|on) your (approval|go-ahead|go ahead|input|confirmation|decision|answer)\b"#,
        #"\bbefore i (proceed|continue|go ahead|start|make)\b"#,
        #"\bready to proceed\b"#,
        #"\bhow would you like (me )?to\b"#,
        #"\byour call\b"#,
    ].map(compiled)

    /// Generic sign-offs, whose sentences are removed before reading: they end many finished turns without waiting on
    /// anything. None holds a `.`, `!` or `?`, so each is found within one sentence.
    static let closers = [
        #"\b(anything else|any other questions|any (further |more |other )?questions|anything further)\b"#,
        #"\b(hope (this|that|it) helps|happy to help|glad (i could|to) help|feel free to (ask|reach out|let me know))\b"#,
        #"\blet me know if (you )?(need|have|want|run into|hit|see)( any)? (anything|any|further|more|other|questions|issues|problems|help|changes|tweaks|adjustments)\b"#,
        #"\bwhat (would you like|do you want)( me)? to (do|work on|tackle) next\b"#,
        #"\bwhat('s| is) next\b"#,
    ].map(compiled)
}
