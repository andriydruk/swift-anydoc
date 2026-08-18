/// The text-showing subset of the content-stream interpreter
/// (ISO 32000-1 §9.4), producing positioned text runs.
///
/// Covers the state machine and the text-space arithmetic: the graphics
/// stack, the text and line matrices, the operators that move or show text,
/// and the glyph advance. With the font metrics supplied, a run's start and
/// its width are both exact, which is what layout needs to group runs into
/// lines and detect word gaps.

/// One shown string with the position it started at, in device space.
struct PdfTextRun {
    var text: String
    /// Origin in device space, y increasing upward as PDF defines it.
    var x: Float
    var y: Float
    /// Effective font size, scaled by the text and current transform.
    var fontSize: Float
    /// How far the run advances, in device space along the writing
    /// direction. Zero when the font's metrics were unavailable.
    var width: Float
    /// The resource name of the font in effect (`/F1`), for later lookup.
    var fontName: String
    /// Text rendering mode; 3 is invisible, used for OCR overlays.
    var renderingMode: Int
    /// The marked-content id in effect when the run was drawn, which is what
    /// links it to a node of the structure tree.
    var mcid: Int?
    /// A placeholder for a raster image rather than drawn text. Its `text`
    /// is `[Image: Name]` and its box is the image's, so a layout-aware
    /// consumer can find the figure without re-parsing the document.
    var isImage = false
    /// The image's height. Text runs leave this zero; only an image needs a
    /// box rather than a baseline.
    var height: Float = 0
    /// Whether this run was drawn sideways — the text matrix's x-axis points
    /// mostly *down* the page rather than across it. Counted per run so the
    /// page can be judged as a whole; one rotated caption on an upright page
    /// is not a rotated page.
    var isRotated = false
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
    var leading: Float
    var rise: Float
    var renderingMode: Int
}

/// Walk a page's operations and emit its text runs in content order.
///
/// `decode` maps a shown string's bytes to text using the font in effect;
/// it is the caller's hook into the font tables.
/// - Parameter includeInvisible: whether text drawn in rendering mode 3 is
///   returned. It is not, by default, matching the reference's own Markdown
///   path: mode 3 is how an OCR layer hides itself behind a scanned image,
///   and emitting it duplicates every word on the page. The advance still
///   happens, so the text that *is* visible stays in place.
func pdfExtractTextRuns(
    _ operations: [PdfOperation],
    initialCtm: PdfMatrix = identityMatrix,
    includeInvisible: Bool = false,
    imageNames: Set<[UInt8]> = [],
    metrics: (String) -> PdfFontWidths? = { _ in nil },
    /// Resolves a `BDC` properties dictionary given by reference. Supplied by
    /// the caller because the extractor holds no document; without it an
    /// indirect properties dictionary simply yields no marked-content id.
    resolveProperties: (PdfObjectId) -> PdfDictionary? = { _ in nil },
    decode: (String, [UInt8]) -> String
) -> [PdfTextRun] {
    var runs: [PdfTextRun] = []
    var stack: [PdfSavedState] = []
    var ctm = initialCtm
    var textMatrix = identityMatrix
    var lineMatrix = identityMatrix
    var inText = false

    var fontName = ""
    /// Twelve, not zero, before any `Tf` — the reference's default. It shows
    /// only when an item is emitted before a font is set, which an
    /// `/ActualText` section with no glyphs can do.
    var fontSize: Float = 12
    var charSpacing: Float = 0
    var wordSpacing: Float = 0
    var leading: Float = 0
    var rise: Float = 0
    var renderingMode = 0

    func number(_ operands: [PdfObject], _ index: Int, default fallback: Float = 0) -> Float {
        guard index < operands.count, let value = operands[index].asNumber else { return fallback }
        return Float(value)
    }

    /// Emit a run at the current text position and advance past it.
    ///
    /// The advance happens whether or not the run was emitted: an invisible
    /// or undecodable string still moves the cursor, and skipping it would
    /// misplace everything after it in the text object.
    func show(_ bytes: [UInt8]) {
        guard inText else { return }
        let font = metrics(fontName)
        // Text-space width, then the horizontal scale the state applies.
        let textWidth = font.map {
            pdfStringWidth(
                bytes, $0, fontSize: fontSize, charSpacing: charSpacing,
                wordSpacing: wordSpacing)
        } ?? 0
        let advance = textWidth

        if suppressGlyphExtraction {
            captureActualTextGlyph()
            textMatrix.e += advance * textMatrix.a
            textMatrix.f += advance * textMatrix.b
            return
        }

        let text = decode(fontName, bytes)
        if !text.isEmpty, includeInvisible || renderingMode != 3 {
            // The run's origin is the text-space origin mapped through the
            // text matrix and then the CTM, with the rise applied along y.
            let risen: PdfMatrix = (1, 0, 0, 1, 0, rise)
            let placed = pdfMultiply(pdfMultiply(risen, textMatrix), ctm)
            // The advance is a text-space distance, so it scales the same
            // way the text matrix scales x.
            let deviceScale = (textMatrix.a * ctm.a + textMatrix.b * ctm.c).magnitude
            var emitted = PdfTextRun(
                text: text, x: placed.e, y: placed.f,
                // The effective size is the nominal size under the
                // combined transform's scale — see `pdfEffectiveFontSize`,
                // which is *not* simply the vertical component.
                fontSize: pdfEffectiveFontSize(fontSize, placed),
                // **Absolute.** A negative font size, or a transform that
                // mirrors the x-axis, makes the advance run backwards; the
                // run still occupies that much of the page. A negative width
                // reaches column and table detection as a box with its edges
                // swapped, so it corrupts layout on documents whose Markdown
                // still looks right — which is why `neg-font-size.pdf` had to
                // be measured through `--underline` to see it at all.
                width: abs(advance * deviceScale),
                fontName: fontName, renderingMode: renderingMode,
                mcid: currentMcid())
            // The vote: the combined matrix's x-axis points across the page
            // for upright text and down it for sideways text.
            emitted.isRotated = placed.a.magnitude < placed.b.magnitude
            runs.append(emitted)
        }
        textMatrix.e += advance * textMatrix.a
        textMatrix.f += advance * textMatrix.b
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
        // After the move, not before: the `BDC` matrix is on the old line.
        captureActualTextGlyph()
    }

    // Marked content, one entry per nesting level.
    var markedContentStack: [(actualText: String?, mcid: Int?)] = []
    /// While an `/ActualText` section is open the glyphs inside it are *not*
    /// extracted: the section declares what the text really says, and the
    /// glyphs are whatever the font happened to draw. They still advance the
    /// text matrix, because the section's width comes from how far they moved
    /// it.
    var suppressGlyphExtraction = false
    /// The text matrix and rise at the `BDC`, and at the first glyph inside
    /// it. The first glyph's position is preferred: a `Td` between the two may
    /// have moved to the correct line, leaving the `BDC` position on the
    /// previous one.
    var actualTextStartMatrix: PdfMatrix?
    var actualTextStartRise: Float = 0
    var actualTextGlyphMatrix: PdfMatrix?
    var actualTextGlyphRise: Float?

    /// Record where the first glyph of an open `/ActualText` section sits.
    func captureActualTextGlyph() {
        if suppressGlyphExtraction && actualTextGlyphMatrix == nil {
            actualTextGlyphMatrix = textMatrix
            actualTextGlyphRise = rise
        }
    }
    /// The innermost id that was actually set.
    ///
    /// A `BMC`, or a `BDC` whose property dictionary carries no `/MCID`,
    /// pushes an entry with none — and content inside it still belongs to
    /// whatever enclosing element did declare one, so the search runs
    /// outwards rather than stopping at the top of the stack.
    func currentMcid() -> Int? {
        for entry in markedContentStack.reversed() {
            if let mcid = entry.mcid { return mcid }
        }
        return nil
    }

    for operation in operations {
        let operands = operation.operands
        switch operation.operator {
        case "BMC":
            markedContentStack.append((actualText: nil, mcid: nil))
        case "BDC":
            var mcid: Int?
            var actualText: String?
            if operands.count >= 2 {
                let properties: PdfDictionary?
                switch operands[1] {
                case .dictionary(let dictionary): properties = dictionary
                case .reference(let id): properties = resolveProperties(id)
                default: properties = nil
                }
                if let value = properties?["MCID"], case .integer(let id) = value {
                    mcid = Int(id)
                }
                if let value = properties?["ActualText"], case .string(let bytes, _) = value {
                    actualText = pdfDecodeTextString(bytes)
                }
            }
            if actualText != nil {
                suppressGlyphExtraction = true
                actualTextStartMatrix = textMatrix
                actualTextStartRise = rise
                // Reset: the first glyph *inside this section* is what counts.
                actualTextGlyphMatrix = nil
                actualTextGlyphRise = nil
            }
            markedContentStack.append((actualText: actualText, mcid: mcid))
        case "EMC":
            guard let entry = markedContentStack.popLast() else { break }
            guard let actualText = entry.actualText else { break }

            let glyphMatrix = actualTextGlyphMatrix
            let glyphRise = actualTextGlyphRise
            let startMatrix = actualTextStartMatrix
            actualTextGlyphMatrix = nil
            actualTextGlyphRise = nil
            actualTextStartMatrix = nil

            if let origin = glyphMatrix ?? startMatrix {
                let effectiveRise = glyphRise ?? actualTextStartRise
                let risen: PdfMatrix = (1, 0, 0, 1, 0, effectiveRise)
                let placed = pdfMultiply(pdfMultiply(risen, origin), ctm)
                // The width is how far the suppressed glyphs moved the text
                // matrix, taken along x only and scaled into device space.
                let delta = textMatrix.e - origin.e
                let scaleX = origin.a * ctm.a + origin.b * ctm.c
                if !actualText.rustTrim().isEmpty {
                    runs.append(
                        PdfTextRun(
                            text: pdfExpandLigatures(actualText),
                            x: placed.e, y: placed.f,
                            fontSize: pdfEffectiveFontSize(
                                baseSize: fontSize,
                                textMatrix: [
                                    placed.a, placed.b, placed.c, placed.d, placed.e, placed.f,
                                ]),
                            width: abs(delta * scaleX),
                            fontName: fontName, renderingMode: renderingMode,
                            // The section's own id, or the enclosing one.
                            mcid: entry.mcid ?? currentMcid()))
                }
            }
            // Another section may still be open around this one.
            suppressGlyphExtraction = markedContentStack.contains { $0.actualText != nil }
        case "q":
            stack.append(
                PdfSavedState(
                    ctm: ctm, fontName: fontName, fontSize: fontSize, charSpacing: charSpacing,
                    wordSpacing: wordSpacing, leading: leading,
                    rise: rise, renderingMode: renderingMode))
        case "Q":
            if let saved = stack.popLast() {
                ctm = saved.ctm
                fontName = saved.fontName
                fontSize = saved.fontSize
                charSpacing = saved.charSpacing
                wordSpacing = saved.wordSpacing
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
        case "Do":
            // An image XObject leaves a **positional placeholder** in the
            // item stream rather than pixels: downstream consumers — the
            // column detector, chart masking, a figure-OCR router — need to
            // know where the figure is, and re-parsing the document to find
            // out would be absurd. The name is carried in the reference's
            // `[Image: Im0]` form, which its Markdown emitter recognises.
            //
            // Form XObjects never reach here: `pdfPageOperationsWithForms`
            // has already inlined their content streams, so a `Do` that
            // survives to this point names an image or nothing at all.
            guard let name = operands.first?.asName, imageNames.contains(name) else { break }
            let box = pdfImageBoundingBox(ctm)
            var run = PdfTextRun(
                text: "[Image: \(String(decoding: name, as: UTF8.self))]",
                x: box.x, y: box.y, fontSize: 0, width: box.width, fontName: "",
                renderingMode: 0, mcid: currentMcid())
            run.isImage = true
            run.height = box.height
            runs.append(run)

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
        // `aw ac string "` and `scale Tz` are both **entirely unimplemented**
        // in the reference's content-stream walker: it has arms for `Tj`,
        // `TJ` and `'` but none for `"`, and none for `Tz` either. So `"`
        // shows nothing, sets neither spacing and does not move to the next
        // line; and horizontal scaling never reaches any advance.
        //
        // Both are upstream bugs — the glyphs are on the page, and condensed
        // text really is narrower — and both were measured against the
        // reference rather than assumed: under `50 Tz` it reports a 9-glyph
        // run as 54pt, not 27pt, and text after a `"` carries none of that
        // operator's spacings. Output has to match, so they are reproduced.
        // See PLAN.md.
        case "\"", "Tz":
            break
        case "TJ":
            guard let array = operands.first?.asArray else { break }
            captureActualTextGlyph()
            // A TJ array is one run, not one run per string: the writer
            // splits a line into fragments and positions them with
            // displacements, and a displacement wide enough to be a space
            // *is* the space. Emitting each fragment separately and hoping
            // the gap heuristic recovers the word boundaries loses them,
            // because the fragments abut exactly.
            let font = metrics(fontName)
            // The threshold is four tenths of the font's own space, in the
            // thousandths TJ counts in, with a floor for fonts that report
            // an implausibly narrow space.
            let spaceThreshold: Float =
                font.map { max(Float($0.spaceWidth) * $0.unitsScale * 1000 * 0.4, 80) } ?? 120

            // A gap several spaces wide is not a word break but a hole the
            // writer left — for a glyph placed separately, or a column
            // boundary. The array splits there, so a run never spans a slot
            // that something else occupies.
            let columnGapThreshold = spaceThreshold * 4

            let origin = textMatrix
            var pieces = ""
            var advance: Float = 0
            // Where the segment being accumulated began, as an advance from
            // the array's origin.
            var segmentStart: Float = 0

            func flushSegment() {
                defer {
                    pieces = ""
                    segmentStart = advance
                }
                guard inText, !pieces.isEmpty else { return }
                let risen: PdfMatrix = (1, 0, 0, 1, 0, rise)
                let at: PdfMatrix = (
                    origin.a, origin.b, origin.c, origin.d,
                    origin.e + segmentStart * origin.a,
                    origin.f + segmentStart * origin.b
                )
                // Inside an `/ActualText` section the glyphs are not the
                // text, so nothing is emitted — but the matrix still advances
                // below, which is where the section's width comes from.
                guard !suppressGlyphExtraction else { return }
                guard includeInvisible || renderingMode != 3 else { return }
                let placed = pdfMultiply(pdfMultiply(risen, at), ctm)
                let deviceScale = (origin.a * ctm.a + origin.b * ctm.c).magnitude
                runs.append(
                    PdfTextRun(
                        text: pieces, x: placed.e, y: placed.f,
                        fontSize: fontSize * abs(placed.d),
                        width: abs((advance - segmentStart) * deviceScale),
                        fontName: fontName, renderingMode: renderingMode,
                        mcid: currentMcid()))
            }

            for element in array {
                if let bytes = element.asStringBytes {
                    pieces += decode(fontName, bytes)
                    advance +=
                        (font.map {
                            pdfStringWidth(
                                bytes, $0, fontSize: fontSize, charSpacing: charSpacing,
                                wordSpacing: wordSpacing)
                        } ?? 0)
                    continue
                }
                guard let adjustment = element.asNumber else { continue }
                let value = Float(adjustment)
                if value < -columnGapThreshold, !pieces.isEmpty {
                    flushSegment()
                    advance += -value / 1000 * fontSize
                    segmentStart = advance
                    continue
                }
                if value < -spaceThreshold, !pieces.isEmpty, !pieces.hasSuffix(" ") {
                    pieces += " "
                }
                advance += -value / 1000 * fontSize
            }
            flushSegment()
            // The reference advances the matrix only when the font had
            // metrics — without them it leaves the array's displacements
            // unapplied entirely, so following text overlaps. Reproduced: it
            // is what decides the width of an enclosing `/ActualText`
            // section, which is measured from how far the matrix moved.
            if font != nil {
                textMatrix.e = origin.e + advance * origin.a
                textMatrix.f = origin.f + advance * origin.b
            }
        default:
            break
        }
    }
    return runs
}

/// The size text is actually rendered at, under a transform.
///
/// The two axes are measured as whole vectors — `√(a²+b²)` and `√(c²+d²)` —
/// and the **larger** wins. Reading the vertical component alone agrees for
/// ordinary upright text, where `b` and `c` are zero and `d` is the vertical
/// scale, and collapses to nothing the moment the text is rotated: a quarter
/// turn puts the scale entirely into `b` and `c` and leaves `d` at zero, so
/// every rotated run reports size zero and can never be a heading.
func pdfEffectiveFontSize(_ baseSize: Float, _ matrix: PdfMatrix) -> Float {
    let scaleX = (matrix.a * matrix.a + matrix.b * matrix.b).squareRoot()
    let scaleY = (matrix.c * matrix.c + matrix.d * matrix.d).squareRoot()
    return baseSize * max(scaleX, scaleY)
}

/// The device-space box an image XObject paints into.
///
/// A `Do` paints the **unit square** through the current transform, so the
/// box is that square's four corners transformed and bounded. Taking only
/// two corners would be wrong the moment the transform rotates or flips —
/// and a negative scale, which is how a producer flips an image vertically,
/// is common enough that the shortcut fails on real documents.
func pdfImageBoundingBox(_ ctm: PdfMatrix) -> (x: Float, y: Float, width: Float, height: Float) {
    let corners = [
        pdfTransformPoint(0, 0, ctm), pdfTransformPoint(1, 0, ctm),
        pdfTransformPoint(1, 1, ctm), pdfTransformPoint(0, 1, ctm),
    ]
    let xs = corners.map(\.0)
    let ys = corners.map(\.1)
    let xMinimum = xs.min() ?? 0
    let yMinimum = ys.min() ?? 0
    return (xMinimum, yMinimum, (xs.max() ?? 0) - xMinimum, (ys.max() ?? 0) - yMinimum)
}
