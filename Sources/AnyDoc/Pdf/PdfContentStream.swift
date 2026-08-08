/// Content-stream tokenizing (ISO 32000-1 §7.8.2).
///
/// A content stream is postfix: operands first, then the operator that
/// consumes them. The operand syntax is the object syntax minus indirect
/// references, so the object lexer does the work; this adds the operator
/// keywords and the inline-image escape hatch.

/// One operation: its operands, then the operator that consumed them.
struct PdfOperation {
    var `operator`: String
    var operands: [PdfObject]
}

/// Split a decoded content stream into operations.
///
/// Malformed input is skipped rather than fatal: a content stream is drawn
/// as far as it parses, and a viewer that stopped at the first bad token
/// would lose the rest of the page.
func pdfParseContentStream(_ content: [UInt8]) -> [PdfOperation] {
    var operations: [PdfOperation] = []
    var operands: [PdfObject] = []
    var lexer = PdfLexer(content)

    while true {
        lexer.skipSpace()
        guard !lexer.atEnd else { break }
        let start = lexer.pos
        let byte = content[lexer.pos]

        // An operand begins with one of the object-syntax lead bytes; note
        // that content streams have no indirect references, so a bare number
        // is always a number.
        if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[")
            || byte == UInt8(ascii: "<")
        {
            if let object = lexer.parseObject() {
                operands.append(object)
                continue
            }
            // Unparseable operand: drop it and resynchronize.
            lexer.pos = start + 1
            operands.removeAll(keepingCapacity: true)
            continue
        }
        if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        {
            if let number = lexer.parseNumberToken() {
                operands.append(number)
                continue
            }
            lexer.pos = start + 1
            continue
        }
        if byte == UInt8(ascii: "]") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: ">")
            || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "{")
        {
            // A stray closing delimiter: skip it.
            lexer.pos = start + 1
            continue
        }

        guard let keyword = lexer.parseKeyword() else {
            lexer.pos = start + 1
            continue
        }
        let name = String(decoding: keyword, as: UTF8.self)
        switch name {
        case "true":
            operands.append(.boolean(true))
        case "false":
            operands.append(.boolean(false))
        case "null":
            operands.append(.null)
        case "BI":
            // An inline image's binary data is not object syntax; skip to
            // `EI` so the operators after it still parse.
            lexer.pos = skipInlineImage(content, from: lexer.pos)
            operands.removeAll(keepingCapacity: true)
        default:
            operations.append(PdfOperation(operator: name, operands: operands))
            operands = []
        }
    }
    return operations
}

/// Skip an inline image (`BI ... ID <binary> EI`), returning the offset just
/// past the `EI`. The binary payload can contain anything, so the end is
/// found by scanning for a whitespace-delimited `EI`.
private func skipInlineImage(_ content: [UInt8], from: Int) -> Int {
    var i = from
    // Find `ID`, after which the data begins.
    while i + 1 < content.count {
        if content[i] == UInt8(ascii: "I"), content[i + 1] == UInt8(ascii: "D") {
            i += 2
            // Exactly one whitespace byte separates ID from the data.
            if i < content.count, PdfLexer.isWhitespace(content[i]) { i += 1 }
            break
        }
        i += 1
    }
    while i + 1 < content.count {
        if content[i] == UInt8(ascii: "E"), content[i + 1] == UInt8(ascii: "I") {
            let beforeOk = i == 0 || PdfLexer.isWhitespace(content[i - 1])
            let afterOk = i + 2 >= content.count || !PdfLexer.isRegular(content[i + 2])
            if beforeOk && afterOk { return i + 2 }
        }
        i += 1
    }
    return content.count
}
