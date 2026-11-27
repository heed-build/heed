import Foundation

/// A command line read the way bash reads one, as far as heed needs to know what would run: its segments (split at
/// `;`, `&&`, `||`, `|`, `&` and newlines), the words of each with what could make a word mean more than it says
/// (a `$`, a `~`, a glob, a brace expansion, a backslash), the files it redirects into and from, and whether it hides
/// a command (a substitution, a subshell) or feeds a shell. This is a reader for a policy, not a shell: anything it
/// cannot place it flags, and the policy refuses a flag.
struct BrowseShell {
    struct Word: Equatable {
        /// The word after quotes and escapes are taken off.
        var text: String
        /// A `$` that expands (a variable, `${}`, `$'..'`, `$"..."`), outside single quotes.
        var expands = false
        /// A `~` that starts the word.
        var tilde = false
        /// `*`, `?` or `[..]` outside quotes: the shell turns the word into the files it matches.
        var glob = false
        /// `{a,b}` or `{1..3}` outside quotes.
        var brace = false
        /// A backslash outside quotes.
        var escaped = false
        /// Any quote or escape in it.
        var decorated = false

        /// The word's text may not be what the shell runs or reads.
        var opaque: Bool { expands || tilde || brace }
    }

    struct Segment {
        var words: [Word] = []
        var redirects: [Word] = []
        var inputs: [Word] = []
        var piped = false
    }

    var segments: [Segment] = []
    var substitution = false
    var heredoc = false
    var shellPipe = false
    /// A `(` or `)` outside quotes: a subshell or a group.
    var grouped = false

    static func isAssignment(_ word: Word) -> Bool {
        guard let equals = word.text.firstIndex(of: "="), equals != word.text.startIndex
        else { return false }
        let name = word.text[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func parse(_ text: String) -> BrowseShell {
        var shell = BrowseShell()
        var segment = Segment()
        var word = Word(text: "")
        var bare = ""
        var inWord = false
        var quote: Character?
        var redirect = false
        var input = false
        let chars = Array(text)
        var index = 0

        func startWord() { inWord = true }
        func endWord() {
            guard inWord else { return }
            if bare.contains(where: { $0 == "*" || $0 == "?" }) { word.glob = true }
            if let open = bare.firstIndex(of: "["), bare[open...].contains("]"), bare != "[",
               bare != "[[" { word.glob = true }
            if bare.range(of: #"\{[^{}]*(,|\.\.)[^{}]*\}"#, options: .regularExpression) != nil { word.brace = true }
            if bare.hasPrefix("~") { word.tilde = true }
            if redirect { segment.redirects.append(word) } else if input { segment.inputs.append(word) } else {
                segment.words.append(word)
            }
            redirect = false
            input = false
            word = Word(text: "")
            bare = ""
            inWord = false
        }
        func endSegment(pipe: Bool) {
            endWord()
            if !segment.words.isEmpty || !segment.redirects.isEmpty || !segment.inputs.isEmpty {
                shell.segments.append(segment)
            }
            segment = Segment()
            segment.piped = pipe
        }
        /// `2>`: the number is a file descriptor, not a word.
        func dropFileDescriptorOrEnd() {
            if inWord, word.text.allSatisfy(\.isNumber) {
                word = Word(text: "")
                bare = ""
                inWord = false
            } else {
                endWord()
            }
        }
        func append(_ c: Character, quoted: Bool) {
            word.text.append(c)
            bare.append(quoted ? "Q" : c)
            startWord()
        }

        while index < chars.count {
            let c = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if let open = quote {
                if c == open {
                    quote = nil
                } else if open == "\"", c == "\\", let next {
                    if "$`\"\\\n".contains(next) { append(next, quoted: true) } else {
                        append(c, quoted: true)
                        append(next, quoted: true)
                    }
                    index += 1
                } else {
                    if open == "\"" {
                        if c == "`" { shell.substitution = true }
                        if c == "$" {
                            if next == "(" { shell.substitution = true } else if let next, next.isLetter || next
                                .isNumber || "_{?!$@*#-".contains(next)
                            { word.expands = true }
                        }
                    }
                    append(c, quoted: true)
                }
                index += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                word.decorated = true
                startWord()
            case "\\":
                if let next {
                    if next != "\n" {
                        append(next, quoted: true)
                        word.escaped = true
                        word.decorated = true
                    }
                    index += 1
                }
            case "`":
                shell.substitution = true
            case "$":
                if next == "(" {
                    shell.substitution = true
                } else if next == "'" || next == "\"" {
                    word.expands = true
                    word.decorated = true
                } else if let next, next.isLetter || next.isNumber || "_{?!$@*#-".contains(next) {
                    word.expands = true
                }
                append(c, quoted: false)
            case " ", "\t":
                endWord()
            case "\n", ";":
                endSegment(pipe: false)
            case "#" where !inWord:
                while index < chars.count, chars[index] != "\n" {
                    index += 1
                }
                continue
            case "(", ")":
                shell.grouped = true
                endWord()
            case "&":
                if next == ">" {
                    endWord()
                    redirect = true
                    index += 1
                    if index + 1 < chars.count, chars[index + 1] == ">" { index += 1 }
                } else {
                    endSegment(pipe: false)
                    if next == "&" { index += 1 }
                }
            case "|":
                if next == "|" {
                    endSegment(pipe: false)
                    index += 1
                } else {
                    endSegment(pipe: true)
                    if next == "&" { index += 1 }
                }
            case ">", "<":
                if next == "(" {
                    shell.substitution = true
                } else if c == "<", next == "<" {
                    shell.heredoc = true
                    index += 1
                } else if c == ">", next == "&" {
                    // `2>&1` and `>&-` name no file; `>&file` does.
                    index += 1
                    if index + 1 < chars.count, chars[index + 1].isNumber || chars[index + 1] == "-" {
                        while index + 1 < chars.count,
                              chars[index + 1].isNumber || chars[index + 1] == "-"
                        {
                            index += 1
                        }
                        if inWord, word.text.allSatisfy(\.isNumber) { word = Word(text: ""); bare = ""; inWord = false }
                    } else {
                        dropFileDescriptorOrEnd()
                        redirect = true
                    }
                } else {
                    dropFileDescriptorOrEnd()
                    if c == ">" {
                        if next == ">" || next == "|" { index += 1 }
                        redirect = true
                    } else {
                        input = true
                    }
                }
            default:
                append(c, quoted: false)
            }
            index += 1
        }
        if quote != nil { shell.grouped = true }
        endSegment(pipe: false)
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "source", "eval", "."]
        for segment in shell.segments where segment.piped {
            if let first = segment.words.first, shells.contains((first.text as NSString).lastPathComponent),
               !segment.words.contains(where: { $0.text == "-c" })
            {
                shell.shellPipe = true
            }
        }
        return shell
    }
}
