/// The text-showing subset of the content-stream interpreter
/// (ISO 32000-1 §9.4), producing positioned text runs.
///
/// This wave covers the state machine and the text-space arithmetic: the
/// graphics stack, the text and line matrices, and the operators that move
/// or show text. What it does **not** yet do is measure glyphs — the font
/// width tables are a later wave — so a run's *starting* position is exact
/// while its advance within the run is not. Downstream layout must not rely
/// on run widths until those land.

/// One shown string with the position it started at, in device space.
struct PdfTextRun {
    var text: String
    /// Origin in device space, y increasing upward as PDF defines it.
    var x: Float
    var y: Float
    /// Effective font size, scaled by the text and current transform.
    var fontSize: Float
    /// The resource name of the font in effect (`/F1`), for later lookup.
    var fontName: String
    /// Text rendering mode; 3 is invisible, used for OCR overlays.
    var renderingMode: Int
}

/// A 2-D affine transform as PDF writes it: [a b c d e f].
typealias PdfMatrix = (a: Float, b: Float, c: Float, d: Float, e: Float, f: Float)

private let identityMatrix: PdfMatrix = (1, 0, 0, 1, 0, 0)

/// `lhs × rhs`, in PDF's row-vector convention.
func pdfMultiply(_ lhs: PdfMatrix, _ rhs: PdfMatrix) -> PdfMatrix {
    (
        a: lhs.a * rhs.a + lhs.b * rhs.c,
        b: lhs.a * rhs.b + lhs.b * rhs.d,
        c: lhs.c * rhs.a + lhs.d * rhs.c,
        d: lhs.c * rhs.b + lhs.d * rhs.d,
        e: lhs.e * rhs.a + lhs.f * rhs.c + rhs.e,
        f: lhs.e * rhs.b + lhs.f * rhs.d + rhs.f
    )
}

/// The graphics state saved by `q` and restored by `Q`.
private struct PdfSavedState {
    var ctm: PdfMatrix
    var fontName: String
    var fontSize: Float
    var charSpacing: Float
    var wordSpacing: Float
    var horizontalScale: Float
    var leading: Float
    var rise: Float
    var renderingMode: Int
}

/// Walk a page's operations and emit its text runs in content order.
///
/// `decode` maps a shown string's bytes to text using the font in effect;
/// it is the caller's hook into the font tables.
func pdfExtractTextRuns(
    _ operations: [PdfOperation],
    initialCtm: PdfMatrix = identityMatrix,
    decode: (String, [UInt8]) -> String
) -> [PdfTextRun] {
    var runs: [PdfTextRun] = []
    var stack: [PdfSavedState] = []
    var ctm = initialCtm
    var textMatrix = identityMatrix
    var lineMatrix = identityMatrix
    var inText = false

    var fontName = ""
    var fontSize: Float = 0
    var charSpacing: Float = 0
    var wordSpacing: Float = 0
    var horizontalScale: Float = 100
    var leading: Float = 0
    var rise: Float = 0
    var renderingMode = 0

    func number(_ operands: [PdfObject], _ index: Int, default fallback: Float = 0) -> Float {
        guard index < operands.count, let value = operands[index].asNumber else { return fallback }
        return Float(value)
    }

    /// Emit a run at the current text position.
    func show(_ bytes: [UInt8]) {
        guard inText else { return }
        let text = decode(fontName, bytes)
        if text.isEmpty { return }
        // The run's origin is the text-space origin mapped through the text
        // matrix and then the CTM, with the rise applied along y.
        let risen: PdfMatrix = (1, 0, 0, 1, 0, rise)
        let placed = pdfMultiply(pdfMultiply(risen, textMatrix), ctm)
        runs.append(
            PdfTextRun(
                text: text, x: placed.e, y: placed.f,
                // The effective size is the nominal size under the vertical
                // scale of the combined transform.
                fontSize: fontSize * abs(placed.d),
                fontName: fontName, renderingMode: renderingMode))
    }

    /// `Td`: move the line matrix by (tx, ty) in text space.
    func moveLine(_ tx: Float, _ ty: Float) {
        lineMatrix.e += tx * lineMatrix.a + ty * lineMatrix.c
        lineMatrix.f += tx * lineMatrix.b + ty * lineMatrix.d
        textMatrix = lineMatrix
    }

    /// `T*`: the next line, using the leading (falling back to the size).
    func nextLine() {
        let tl = leading != 0 ? leading : fontSize * 1.2
        lineMatrix.e += (-tl) * lineMatrix.c
        lineMatrix.f += (-tl) * lineMatrix.d
        textMatrix = lineMatrix
    }

    for operation in operations {
        let operands = operation.operands
        switch operation.operator {
        case "q":
            stack.append(
                PdfSavedState(
                    ctm: ctm, fontName: fontName, fontSize: fontSize, charSpacing: charSpacing,
                    wordSpacing: wordSpacing, horizontalScale: horizontalScale, leading: leading,
                    rise: rise, renderingMode: renderingMode))
        case "Q":
            if let saved = stack.popLast() {
                ctm = saved.ctm
                fontName = saved.fontName
                fontSize = saved.fontSize
                charSpacing = saved.charSpacing
                wordSpacing = saved.wordSpacing
                horizontalScale = saved.horizontalScale
                leading = saved.leading
                rise = saved.rise
                renderingMode = saved.renderingMode
            }
        case "cm":
            guard operands.count >= 6 else { break }
            let m: PdfMatrix = (
                number(operands, 0, default: 1), number(operands, 1), number(operands, 2),
                number(operands, 3, default: 1), number(operands, 4), number(operands, 5)
            )
            ctm = pdfMultiply(m, ctm)
        case "BT":
            inText = true
            textMatrix = identityMatrix
            lineMatrix = identityMatrix
            renderingMode = 0
        case "ET":
            inText = false
        case "Tf":
            if let name = operands.first?.asName {
                fontName = String(decoding: name, as: UTF8.self)
            }
            fontSize = number(operands, 1, default: fontSize)
        case "TL":
            leading = number(operands, 0, default: leading)
        case "Tc":
            charSpacing = number(operands, 0, default: charSpacing)
        case "Tw":
            wordSpacing = number(operands, 0, default: wordSpacing)
        case "Tz":
            horizontalScale = number(operands, 0, default: horizontalScale)
        case "Ts":
            rise = number(operands, 0, default: rise)
        case "Tr":
            renderingMode = Int(number(operands, 0, default: Float(renderingMode)))
        case "Td":
            guard operands.count >= 2 else { break }
            moveLine(number(operands, 0), number(operands, 1))
        case "TD":
            guard operands.count >= 2 else { break }
            let ty = number(operands, 1)
            // TD also sets the leading, to the negated vertical move.
            leading = -ty
            moveLine(number(operands, 0), ty)
        case "Tm":
            guard operands.count >= 6 else { break }
            textMatrix = (
                number(operands, 0, default: 1), number(operands, 1), number(operands, 2),
                number(operands, 3, default: 1), number(operands, 4), number(operands, 5)
            )
            lineMatrix = textMatrix
        case "T*":
            nextLine()
        case "Tj":
            if let bytes = operands.first?.asStringBytes { show(bytes) }
        case "'":
            // Next line, then show.
            nextLine()
            if let bytes = operands.first?.asStringBytes { show(bytes) }
        case "\"":
            // aw ac string ": set spacings, next line, then show.
            wordSpacing = number(operands, 0, default: wordSpacing)
            charSpacing = number(operands, 1, default: charSpacing)
            nextLine()
            if operands.count >= 3, let bytes = operands[2].asStringBytes { show(bytes) }
        case "TJ":
            guard let array = operands.first?.asArray else { break }
            // Each element is either a string to show or a displacement in
            // thousandths of an em, subtracted from the position.
            for element in array {
                if let bytes = element.asStringBytes {
                    show(bytes)
                    continue
                }
                guard let adjustment = element.asNumber else { continue }
                let shift = Float(-adjustment) / 1000 * fontSize * (horizontalScale / 100)
                textMatrix.e += shift * textMatrix.a
                textMatrix.f += shift * textMatrix.b
            }
        default:
            break
        }
    }
    return runs
}
