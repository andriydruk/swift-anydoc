/// Paragraph styles that name a block container. Word, Pandoc and
/// LibreOffice all mark quotations and preformatted text with a built-in
/// paragraph style name rather than dedicated markup, so the name is the
/// only signal a frontend has.

/// The block container a paragraph style designates.
enum BlockStyle: Equatable {
    case quote
    case code
}

/// The container a paragraph style name designates. ODF encodes spaces in
/// internal style names as `_20_`.
func blockStyleFromName(_ name: String) -> BlockStyle? {
    let name = replacingSubstring(name, "_20_", " ")
    switch name.rustTrim().asciiLowercased() {
    // Word, Pandoc, LibreOffice.
    case "quote", "intense quote", "block text", "quotations": return .quote
    case "html preformatted", "source code", "preformatted text": return .code
    default: return nil
    }
}

/// Rust `str::replace`: non-overlapping left-to-right substring replacement.
private func replacingSubstring(_ s: String, _ from: String, _ to: String) -> String {
    let hay = Array(s.utf8)
    let needle = Array(from.utf8)
    let replacement = Array(to.utf8)
    guard !needle.isEmpty else { return s }
    var out: [UInt8] = []
    out.reserveCapacity(hay.count)
    var i = 0
    while i < hay.count {
        if i + needle.count <= hay.count, hay[i..<(i + needle.count)].elementsEqual(needle) {
            out.append(contentsOf: replacement)
            i += needle.count
        } else {
            out.append(hay[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Consecutive paragraphs sharing one styled container, folded into a single
/// block: producers write a multi-paragraph quote, and a code block one line
/// per paragraph, as a run of separately styled paragraphs.
enum StyledRun {
    case empty
    case quote([Block])
    case code([String])

    init() {
        self = .empty
    }

    /// The container currently open.
    private var style: BlockStyle? {
        switch self {
        case .empty: nil
        case .quote: .quote
        case .code: .code
        }
    }

    /// Add one styled paragraph, closing the open container first when the
    /// style changes.
    mutating func push(_ style: BlockStyle, _ inlines: [Inline], _ out: inout [Block]) {
        if self.style != style {
            flush(&out)
            switch style {
            case .quote: self = .quote([])
            case .code: self = .code([])
            }
        }
        switch self {
        // Code is literal text; character styling is presentation the
        // source applied to its syntax, never content.
        case .code(var lines):
            lines.append(inlinesToPlainText(inlines))
            self = .code(lines)
        case .quote(var blocks):
            if !inlinesAreEmpty(inlines) {
                blocks.append(.paragraph(inlines))
            }
            self = .quote(blocks)
        case .empty:
            break
        }
    }

    /// Close the open container, if any.
    mutating func flush(_ out: inout [Block]) {
        let taken = self
        self = .empty
        switch taken {
        case .quote(let inner):
            if !inner.isEmpty {
                out.append(.blockQuote(inner))
            }
        case .code(let lines):
            // Blank lines count only between the code's own lines.
            let first = lines.firstIndex(where: { !$0.isBlank })
            let last = lines.lastIndex(where: { !$0.isBlank })
            if let first, let last {
                out.append(.codeBlock(lang: nil, text: lines[first...last].joined(separator: "\n")))
            }
        case .empty:
            break
        }
    }
}
