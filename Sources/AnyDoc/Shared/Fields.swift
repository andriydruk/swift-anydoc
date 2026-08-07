/// Word field-instruction parsing (DOC, DOCX, RTF), via a small
/// case-insensitive lexer with known switch arities.

/// Field accumulator: instruction text before the separator, result after.
struct FieldFrame {
    var instr: String = ""
    var inResult: Bool = false
    var inlines: [Inline] = []

    init() {}
}

/// Finish a field: wrap the result in a link when the instruction is a
/// hyperlink, otherwise pass the result content through.
func fieldResult(_ instr: String, _ content: [Inline]) -> [Inline] {
    if let target = hyperlinkTarget(instr), !inlinesAreEmpty(content) {
        return [.link(content: content, target: target)]
    }
    return content
}

private enum FieldToken: Equatable {
    case word(String)
    case fieldSwitch(Unicode.Scalar)
}

/// Tokenize a field instruction: quoted strings (with `\"` and `\\`
/// escapes), backslash switches, bare words.
private func tokenize(_ instr: String) -> [FieldToken] {
    var out: [FieldToken] = []
    let chars = Array(instr.unicodeScalars)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c.isRustWhitespace {
            i += 1
        } else if c == "\"" {
            i += 1
            var word = String.UnicodeScalarView()
            scan: while i < chars.count {
                let c = chars[i]
                i += 1
                switch c {
                case "\"":
                    break scan
                case "\\":
                    if i < chars.count {
                        let esc = chars[i]
                        i += 1
                        if esc == "\"" || esc == "\\" {
                            word.append(esc)
                        } else {
                            word.append("\\")
                            word.append(esc)
                        }
                    } else {
                        break scan
                    }
                default:
                    word.append(c)
                }
            }
            out.append(.word(String(word)))
        } else if c == "\\" {
            i += 1
            if i < chars.count {
                out.append(.fieldSwitch(asciiLowerScalar(chars[i])))
                i += 1
            }
        } else {
            var word = String.UnicodeScalarView()
            while i < chars.count, !chars[i].isRustWhitespace {
                word.append(chars[i])
                i += 1
            }
            out.append(.word(String(word)))
        }
    }
    return out
}

/// Rust `char::to_ascii_lowercase`.
private func asciiLowerScalar(_ c: Unicode.Scalar) -> Unicode.Scalar {
    if c >= "A" && c <= "Z" {
        return Unicode.Scalar(c.value + 0x20) ?? c
    }
    return c
}

/// Switches of the HYPERLINK field that take an argument.
private func hyperlinkSwitchTakesArg(_ s: Unicode.Scalar) -> Bool {
    s == "l" || s == "o" || s == "t"
}

/// Interpret a HYPERLINK field instruction as a link target.
func hyperlinkTarget(_ instr: String) -> LinkTarget? {
    var tokens = tokenize(instr)[...]
    guard case .word(let keyword) = tokens.first, eqIgnoreAsciiCase(keyword, "HYPERLINK") else {
        return nil
    }
    tokens = tokens.dropFirst()
    var url: String? = nil
    var anchor: String? = nil
    while let token = tokens.first {
        tokens = tokens.dropFirst()
        switch token {
        case .word(let w):
            if url == nil, !w.isBlank {
                url = w.rustTrim()
            }
        case .fieldSwitch(let s):
            // A switch's argument is the next token only when it is a
            // word; a following switch means the argument was omitted.
            var arg: String? = nil
            if hyperlinkSwitchTakesArg(s), case .word(let w) = tokens.first {
                tokens = tokens.dropFirst()
                arg = w
            }
            if s == "l", let a = arg, !a.isBlank {
                anchor = a.rustTrim()
            }
        }
    }
    switch (url, anchor) {
    case (.some(let url), .some(let frag)): return classify("\(url)#\(frag)")
    case (.some(let url), nil): return classify(url)
    case (nil, .some(let frag)): return .anchor(frag)
    case (nil, nil): return nil
    }
}

/// Classify an OPC relationship target as a link target. External-mode
/// targets are parsed like hyperlink field targets (scheme detection);
/// internal-mode targets stay package-relative.
func classifyRelTarget(external: Bool, target: String) -> LinkTarget {
    external ? classify(target) : .relative(target)
}

private func classify(_ url: String) -> LinkTarget {
    if url.hasPrefix("#") {
        return .anchor(String(url.dropFirst()))
    }
    if isAbsoluteUri(url) {
        return .external(url)
    }
    return .relative(url)
}
