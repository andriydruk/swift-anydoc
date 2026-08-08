/// Shared text normalization.

/// Drop control characters and layout-only invisibles, convert NBSP to a
/// regular space, strip soft hyphens. Line breaks become single spaces; a
/// CRLF pair is one break. U+200C (ZWNJ) and U+200D (ZWJ) are **preserved**:
/// they carry meaning in Arabic/Indic shaping and emoji sequences.
func cleanText(_ text: some StringProtocol) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        i += 1
        switch c {
        case "\u{a0}": out.append(" ")
        case "\u{ad}", "\u{200b}", "\u{feff}": break
        case "\t": out.append("\t")
        case "\r":
            if i < scalars.count, scalars[i] == "\n" { i += 1 }
            out.append(" ")
        case "\n": out.append(" ")
        case let c where c.isRustControl: break
        case let c: out.append(c)
        }
    }
    return String(out)
}

/// XML whitespace, the S production of XML 1.0: the only characters an
/// `xml:space` contract governs. Everything else, a no-break space included,
/// is character data.
func isXmlSpace(_ c: Unicode.Scalar) -> Bool {
    c == " " || c == "\t" || c == "\r" || c == "\n"
}

/// Strip XML whitespace from both ends — what an unmarked `xml:space`
/// contract discards, in OOXML text runs and spreadsheet strings alike.
func trimXmlSpace(_ s: String) -> Substring {
    var view = s[...]
    while let first = view.unicodeScalars.first, isXmlSpace(first) {
        view = view[view.unicodeScalars.index(after: view.unicodeScalars.startIndex)...]
    }
    while let last = view.unicodeScalars.last, isXmlSpace(last) {
        view = view[..<view.unicodeScalars.index(before: view.unicodeScalars.endIndex)]
    }
    return view
}

/// Collapse whitespace runs to single spaces.
func collapseWhitespace(_ text: some StringProtocol) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    var prevSpace = false
    for c in text.unicodeScalars {
        if c.isRustWhitespace {
            if !prevSpace { out.append(" ") }
            prevSpace = true
        } else {
            out.append(c)
            prevSpace = false
        }
    }
    return String(out)
}
