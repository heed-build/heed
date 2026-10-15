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

    /// Whether the closing words of an agent's turn ask you something. Only the end counts: trailing code blocks are
    /// dropped, then the last two lines (at most the last 300 characters) are read. A question mark at the end, a
    /// question to you in those lines, or a phrase that waits on you ("should I", "want me to", "please confirm")
    /// counts; the generic closers agents sign off with ("let me know if you need anything else") do not.
    public static func asksYou(_ text: String) -> Bool {
        var lines = normalized(withoutTrailingCode(text))
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Options listed after the question ("Which do you prefer?" then 1., 2., 3.): the question is what counts.
        let options = lines.reversed().prefix { matches($0, optionLine) }.count
        if options > 0, options < lines.count {
            let lead = lines[lines.count - options - 1]
            if lead.hasSuffix("?") { return true }
            if lead.hasSuffix(":"), matches(lead, #"\b(which|what|whether)\b.*\byou\b"#) || phrases.contains(where: {
                matches(lead, $0)
            }) { return true }
        }
        lines = lines.map { removing(closers, from: $0) }.filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !lines.isEmpty else { return false }
        var tail = lines.suffix(2).joined(separator: "\n")
        if tail.count > 300 { tail = String(tail.suffix(300)) }
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

    /// Lowercased, with straight quotes, inline code reduced to a word (so `optional?` is not a question) and
    /// markdown emphasis gone.
    static func normalized(_ text: String) -> String {
        var text = text.lowercased()
        for (curly, straight) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            text = text.replacingOccurrences(of: curly, with: straight)
        }
        text = text.replacingOccurrences(of: #"`[^`\n]*`"#, with: "code", options: .regularExpression)
        return text.replacingOccurrences(
            of: #"\*\*|__|(?<![\w])[*_]|[*_](?![\w])"#,
            with: "",
            options: .regularExpression
        )
    }

    /// The question sentences in `text`: each runs from the previous sentence end to a `?` that ends a sentence (not
    /// one inside a URL).
    static func questions(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?\n]*\?(?=[\s)"'\]]|$)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func removing(_ patterns: [String], from line: String) -> String {
        patterns.reduce(line) { $0.replacingOccurrences(of: $1, with: "", options: .regularExpression) }
            .trimmingCharacters(in: .whitespaces)
    }

    /// A `?` at the very end, optionally inside closing brackets, quotes or emphasis.
    static let endsWithQuestion = #"\?[\s)\]"'»]*$"#

    /// A question sentence that speaks to you, or about what the agent should do: rhetorical questions in a summary
    /// ("Why did it fail? The cache was stale.") have neither.
    static let addressed = #"\b(you|your|i|me|we|us)\b"#

    /// `1. Option`, `b) Option`, `- Option`.
    static let optionLine = #"^([0-9]+[.)]|[a-h][.)]|[-•])\s"#

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
    ]

    /// Generic sign-offs, removed before reading: they end many finished turns without waiting on anything.
    static let closers = [
        #"[^.!?\n]*\b(anything else|any other questions|any (further |more |other )?questions|anything further)\b[^.!?\n]*[.!?]*"#,
        #"[^.!?\n]*\b(hope (this|that|it) helps|happy to help|glad (i could|to) help|feel free to (ask|reach out|let me know))\b[^.!?\n]*[.!?]*"#,
        #"[^.!?\n]*\blet me know if (you )?(need|have|want|run into|hit|see)( any)? (anything|any|further|more|other|questions|issues|problems|help|changes|tweaks|adjustments)\b[^.!?\n]*[.!?]*"#,
        #"[^.!?\n]*\bwhat (would you like|do you want)( me)? to (do|work on|tackle) next\b[^.!?\n]*[.!?]*"#,
        #"[^.!?\n]*\bwhat('s| is) next\b[^.!?\n]*[.!?]*"#,
    ]
}
