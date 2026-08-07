/// Context-sensitive minimal escaping: document text is escaped only where a
/// character could actually parse as Markdown syntax in its context.

/// Where an inline run is being rendered; controls which characters can be
/// syntax there.
enum InlineContext: Equatable {
    case block
    case heading
    case tableCell
}

/// Fine-grained escaping context beyond `InlineContext`: where the run sits
/// relative to its surroundings.
struct EscapeOpts {
    /// The run begins at the start of an output line, where block syntax
    /// (headings, list markers, setext underlines) could form.
    var atLineStart = false
    /// The run is wrapped in emphasis delimiters, so delimiter characters
    /// inside it always need escaping.
    var styled = false
    /// The character following the run is unknown or active markup; pairable
    /// delimiters must assume the worst.
    var trailingActive = false
    /// Inside a link label / image alt, where an unmatched `]` (or `[`)
    /// would terminate the label early.
    var inLabel = false
}

/// Escape Markdown syntax in document text.
func escapeText(_ text: String, _ ctx: InlineContext, _ opts: EscapeOpts) -> String {
    let chars = Array(text.unicodeScalars)
    // Last position of each pairable delimiter; a lone one is inert.
    var last: [Int?] = [nil, nil, nil, nil, nil] // * _ ~ ` ]
    for (j, c) in chars.enumerated() {
        switch c {
        case "*": last[0] = j
        case "_": last[1] = j
        case "~": last[2] = j
        case "`": last[3] = j
        case "]": last[4] = j
        default: break
        }
    }
    var out = String.UnicodeScalarView()
    out.reserveCapacity(chars.count + 8)
    var lineHasContent = !(opts.atLineStart && ctx == .block)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\n" {
            out.append("\n")
            if ctx == .block {
                lineHasContent = false
            }
            i += 1
            continue
        }
        let startOfLine = !lineHasContent
        if !c.isRustWhitespace {
            lineHasContent = true
        }
        let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
        // At the run's end the next character is unknown; trailingActive
        // assumes the worst.
        let nextNonspace = next.map { !$0.isRustWhitespace } ?? opts.trailingActive
        func paired(_ slot: Int) -> Bool {
            opts.trailingActive || last[slot].map { $0 > i } ?? false
        }
        var escape: Bool
        switch c {
        case "\\": escape = true
        case "]" where opts.inLabel: escape = true
        case "`": escape = opts.styled || paired(3)
        case "*": escape = opts.styled || startOfLine || (nextNonspace && paired(0))
        case "_":
            let prevAlnum = i > 0 && chars[i - 1].isRustAlphanumeric
            let nextAlnum = next?.isRustAlphanumeric ?? false
            escape = opts.styled || (nextNonspace && !(prevAlnum && nextAlnum) && paired(1))
        case "~": escape = opts.styled || (nextNonspace && paired(2))
        case "[": escape = opts.inLabel || paired(4)
        case "<":
            escape = next.map { $0.isAsciiAlphabetic || $0 == "/" || $0 == "!" || $0 == "?" } ?? false
        case "!": escape = next == nil && opts.trailingActive
        case "|" where ctx == .tableCell: escape = true
        case "&" where entityAhead(chars[i...]):
            out.append(contentsOf: "&amp;".unicodeScalars)
            i += 1
            continue
        case "#" where startOfLine:
            var j = i
            while j < chars.count, chars[j] == "#" { j += 1 }
            escape = j >= chars.count || chars[j].isRustWhitespace
        case "-" where startOfLine:
            escape = !nextNonspace || lineIsOnly(chars[i...], "-")
        case "+" where startOfLine: escape = !nextNonspace
        case ">" where startOfLine: escape = true
        case "=" where startOfLine: escape = lineIsOnly(chars[i...], "=")
        case "0"..."9" where startOfLine:
            var j = i
            while j < chars.count, chars[j].isAsciiDigit { j += 1 }
            if j < chars.count, chars[j] == "." || chars[j] == ")",
                j + 1 >= chars.count || chars[j + 1].isRustWhitespace
            {
                out.append(contentsOf: chars[i..<j])
                out.append("\\")
                out.append(chars[j])
                i = j + 1
                continue
            }
            escape = false
        default: escape = false
        }
        if escape {
            out.append("\\")
        }
        out.append(c)
        i += 1
    }
    return String(out)
}

/// True when the rest of the current line is just `c`, spaces, and tabs
/// (a setext underline or thematic break).
private func lineIsOnly(_ chars: ArraySlice<Unicode.Scalar>, _ c: Unicode.Scalar) -> Bool {
    chars.prefix(while: { $0 != "\n" }).allSatisfy { $0 == c || $0 == " " || $0 == "\t" }
}

private func entityAhead(_ chars: ArraySlice<Unicode.Scalar>) -> Bool {
    var i = chars.startIndex + 1
    if i < chars.endIndex, chars[i] == "#" {
        return true
    }
    var seen = 0
    while i < chars.endIndex, chars[i].isAsciiAlphanumeric {
        i += 1
        seen += 1
    }
    return seen > 0 && i < chars.endIndex && chars[i] == ";"
}

/// Format a link destination, angle-bracketing when needed.
func formatUrl(_ url: String) -> String {
    let hex = Array("0123456789ABCDEF".unicodeScalars)
    var escaped = String.UnicodeScalarView()
    escaped.reserveCapacity(url.unicodeScalars.count)
    for c in url.unicodeScalars {
        switch c {
        case "<": escaped.append(contentsOf: "%3C".unicodeScalars)
        case ">": escaped.append(contentsOf: "%3E".unicodeScalars)
        // Raw pipes split GFM table cells.
        case "|": escaped.append(contentsOf: "%7C".unicodeScalars)
        // Encode controls so they cannot split the Markdown output.
        case let c where c.isRustControl:
            for byte in String(c).utf8 {
                escaped.append("%")
                escaped.append(hex[Int(byte >> 4)])
                escaped.append(hex[Int(byte & 0x0F)])
            }
        case let c: escaped.append(c)
        }
    }
    let text = String(escaped)
    if text.unicodeScalars.contains(where: { $0.isRustWhitespace || $0 == "(" || $0 == ")" }) {
        return "<\(text)>"
    }
    return text
}

func escapeUrlAsText(_ url: String, _ ctx: InlineContext) -> String {
    let cleaned = String(String.UnicodeScalarView(url.unicodeScalars.map { c in
        c.isRustControl ? " " : c
    }))
    return escapeText(cleaned, ctx, EscapeOpts(trailingActive: true, inLabel: true))
}

/// Shortest backtick fence longer than any backtick run in `text`.
func backtickFence(_ text: String, min minLength: Int) -> String {
    var longest = 0
    var run = 0
    for c in text.unicodeScalars {
        if c == "`" {
            run += 1
            longest = max(longest, run)
        } else {
            run = 0
        }
    }
    return String(repeating: "`", count: max(longest + 1, minLength))
}
