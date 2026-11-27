import Foundation

extension BrowsePolicy {
    /// The options one command takes, as heed lets an agent use them: what is not here is refused, spelled any way
    /// (an abbreviated `--open-files-in-p`, a bundle `-fu`, an attached `-Rother`), because a flag heed has not read
    /// may be the one that runs a command or points at another repo.
    struct Options {
        enum Value {
            /// Free text: a message, a pattern, a revision.
            case text
            /// A file to read.
            case read
        }

        /// Single-letter flags that take no value, as one string.
        var flags = ""
        /// Single-letter options that take a value (the rest of the bundle, or the next word).
        var shortValues: [Character: Value] = [:]
        /// `--name` with no value.
        var longs: Set<String> = []
        /// `--name=value` or `--name value`.
        var longValues: [String: Value] = [:]
        /// `--name` and `--name=value`, the value optional and never a separate word.
        var longOptional: Set<String> = []
        /// A `-5` or `-20`: a count.
        var digits = true

        struct Parsed {
            var positionals: [String] = []
            /// Every value an option took, with what it is.
            var values: [(name: String, value: String, kind: Value)] = []
            var seen: Set<String> = []
            var refusal: String?
        }

        /// Reads `args` against the table. `--` ends the options.
        func parse(_ args: [String], command: String) -> Parsed {
            var out = Parsed()
            var index = 0
            var optionsEnded = false
            func fail(_ word: String) {
                out.refusal = out.refusal ?? "\(command) \(word) is not an option heed lets a run use"
            }
            while index < args.count {
                let word = args[index]
                index += 1
                if optionsEnded || !word.hasPrefix("-") || word == "-" {
                    out.positionals.append(word)
                    continue
                }
                if word == "--" {
                    optionsEnded = true
                    continue
                }
                if word.hasPrefix("--") {
                    let body = word.dropFirst(2)
                    let name: String
                    var attached: String?
                    if let equals = body.firstIndex(of: "=") {
                        name = String(body[..<equals])
                        attached = String(body[body.index(after: equals)...])
                    } else {
                        name = String(body)
                    }
                    out.seen.insert(name)
                    if let kind = longValues[name] {
                        if let attached {
                            out.values.append((name, attached, kind))
                        } else if index < args.count {
                            out.values.append((name, args[index], kind))
                            index += 1
                        } else {
                            fail(word)
                        }
                    } else if longOptional.contains(name) {
                        if let attached { out.values.append((name, attached, .text)) }
                    } else if longs.contains(name), attached == nil {
                        continue
                    } else {
                        fail(word)
                    }
                    continue
                }
                // A bundle of short options.
                let chars = Array(word.dropFirst())
                if digits, chars.allSatisfy(\.isNumber) { continue }
                var position = 0
                while position < chars.count {
                    let flag = chars[position]
                    out.seen.insert(String(flag))
                    if let kind = shortValues[flag] {
                        var value = String(chars[(position + 1)...])
                        if value.hasPrefix("="), value.count > 1 { value.removeFirst() }
                        if value.isEmpty {
                            guard index < args.count else { fail(word); break }
                            value = args[index]
                            index += 1
                        }
                        out.values.append((String(flag), value, kind))
                        break
                    } else if flags.contains(flag) {
                        position += 1
                    } else {
                        fail("-\(flag)")
                        break
                    }
                }
            }
            return out
        }
    }

    /// The paths in what an option parse found: positionals and the values of file options, judged as files.
    static func checkParsed(
        _ parsed: Options.Parsed, _ context: Context, cwd: String, forWriting: Bool = false,
        positionalsAreText: Bool = false
    ) -> Verdict {
        if let refusal = parsed.refusal { return .no(refusal) }
        for (_, value, kind) in parsed.values where kind == .read {
            let check = checkPath(value, in: context, cwd: cwd, forWriting: false)
            if !check.allowed { return check }
        }
        for word in parsed.positionals {
            if positionalsAreText, !looksLikePath(word) { continue }
            let check = checkPath(word, in: context, cwd: cwd, forWriting: forWriting)
            if !check.allowed { return check }
        }
        return .yes
    }
}
