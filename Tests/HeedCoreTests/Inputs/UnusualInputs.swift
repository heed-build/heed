import Foundation
@testable import HeedCore
import Testing

/// The corpus of unusual inputs in `Fixtures/inputs`: other people's text, shell commands, control requests, merge
/// situations. Each file is a table; adding a case is adding a line there. The tests here run every case through the
/// code that handles it for real, with no model called.
enum UnusualInputs {
    static func load<T: Decodable>(_ name: String, as _: T.Type = T.self) throws -> T {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/inputs"
        ))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// The cases of `name`, or none when the file does not load (`UnusualInputsCorpusTests` fails then).
    static func cases<T: Decodable>(_ name: String, as _: T.Type = T.self) -> T? {
        try? load(name, as: T.self)
    }

    /// Scalars that are not text to a reader, a terminal or a model: C0 and C1 controls but `\n` and `\t`, DEL, bidi
    /// controls, zero-width characters, the soft hyphen, and line and paragraph separators.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: false
        case 0x00 ... 0x1F, 0x7F ... 0x9F: true
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069: true
        case 0x200B, 0x200C, 0x2060 ... 0x2064, 0xFEFF, 0x180E, 0x00AD: true
        case 0x2028, 0x2029: true
        default: false
        }
    }

    /// What in `text` a reader would not see as text: hidden scalars, a joiner that is not between emoji, and tag
    /// characters outside a flag. Empty when there is none.
    static func hidden(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var found: [String] = []
        for (index, scalar) in scalars.enumerated() {
            let previous = index > 0 ? scalars[index - 1] : nil
            if isHidden(scalar) {
                found.append(String(format: "U+%04X at %d", scalar.value, index))
            } else if scalar.value == 0x200D {
                let before = previous.map { $0.properties.isEmoji && $0.value > 0x7F || $0.value == 0xFE0F } ?? false
                if !before { found.append("a joiner after U+\(String(format: "%04X", previous?.value ?? 0))") }
            } else if (0xE0000 ... 0xE007F).contains(scalar.value) {
                let inFlag = previous.map { $0.value == 0x1F3F4 || (0xE0000 ... 0xE007F).contains($0.value) } ?? false
                if !inFlag { found.append(String(format: "tag U+%04X at %d", scalar.value, index)) }
            }
        }
        return found
    }

    /// Every match of an opening or closing fence tag, however spaced or cased.
    static func tags(in text: String) -> (opening: Int, closing: Int) {
        func count(_ pattern: String) -> Int {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return regex?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? -1
        }
        return (count(#"<\s*external"#), count(#"<\s*/\s*external"#))
    }
}

/// One piece of other people's text (`Fixtures/inputs/text.json`).
struct TextCase: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    /// What the case is there for.
    let checks: String
    let text: String
    /// `ExternalText.Source`'s raw value; a comment when not given.
    let source: String?
    /// The fence id to render with, for a case that guesses it.
    let nonce: String?
    /// The text this many times over.
    let `repeat`: Int?
    /// Pieces that must survive to the UI and the prompt as they are.
    let keep: [String]?
    /// Pieces of escape sequences that must not reach the UI or the prompt at all.
    let drop: [String]?
    let login: String?
    let trust: String?

    var testDescription: String { name }

    var full: String { self.repeat.map { String(repeating: text, count: $0) } ?? text }

    var author: ExternalText.Author {
        ExternalText.Author(
            login: login ?? "drive-by", trust: trust.flatMap(ExternalText.Trust.init(rawValue:)) ?? .stranger
        )
    }

    var external: ExternalText {
        ExternalText(full, source: source.flatMap(ExternalText.Source.init(rawValue:)) ?? .comment, author: author)
    }

    static let all: [TextCase] = UnusualInputs.cases("text") ?? []
}

struct UnusualInputsCorpusTests {
    /// Every table loads and has cases, so no test below passes on an empty list.
    @Test func everyTableLoads() throws {
        #expect(try UnusualInputs.load("text", as: [TextCase].self).count >= 30)
        #expect(TextCase.all.count >= 30)
        let commands = try UnusualInputs.load("commands", as: CommandCorpus.self)
        #expect(commands.notSafeRead.count >= 50 && commands.safeRead.count >= 10)
        #expect(commands.publishes.count >= 10 && commands.notPublishes.count >= 5)
        #expect(CommandCorpus.loaded != nil)
        let control = try UnusualInputs.load("control", as: ControlCorpus.self)
        #expect(control.callers.count >= 10 && control.sends.count >= 5 && control.hooks.count >= 5)
        #expect(control.inboxes.count >= 10 && control.approvals.count >= 4 && control.starts.count >= 3)
        #expect(ControlCorpus.loaded != nil)
        #expect(try UnusualInputs.load("merge", as: [MergeCase].self).count >= 15)
        #expect(MergeCase.all.count >= 15)
        #expect(try UnusualInputs.load("feedback", as: [FeedbackCase].self).count >= 5)
        #expect(FeedbackCase.all.count >= 5)
    }

    /// The checks themselves see what they look for.
    @Test func theChecksSeeWhatTheyLookFor() {
        #expect(!UnusualInputs.hidden(in: "a\u{1B}b").isEmpty)
        #expect(!UnusualInputs.hidden(in: "a\u{202E}b").isEmpty)
        #expect(!UnusualInputs.hidden(in: "a\u{200D}b").isEmpty)
        #expect(!UnusualInputs.hidden(in: "a\u{E0041}").isEmpty)
        #expect(UnusualInputs.hidden(in: "👨\u{200D}👩 a\tb\n").isEmpty)
        #expect(UnusualInputs.tags(in: "< / EXTERNAL x><external") == (1, 1))
    }
}
