/// Graphics-path extraction, ported from the path operators of
/// pdf-inspector's `extractor/content_stream.rs`.
///
/// A PDF draws rules, cell borders and underlines as paths, not as anything
/// the text layer knows about. Recovering them means running the same
/// content stream a second time and watching the path machinery: `re` for
/// rectangles, `m`/`l`/`h` for subpaths, and the painting operators that say
/// whether any of it actually put ink on the page.
///
/// That last distinction is the whole point of keeping four separate lists.
/// A rectangle used as a clip path (`re W n`) draws nothing, so it must not
/// be mistaken for a rule; a filled subpath is a rule even though no `re`
/// appeared. Downstream — underline detection, and eventually table
/// detection — each want a different subset.

/// An axis-aligned rectangle in device space.
struct PdfRect: Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
}

/// A straight segment in device space, with the width it is stroked at.
struct PdfLineSegment: Equatable {
    var x1: Float
    var y1: Float
    var x2: Float
    var y2: Float
    /// The stroke width after the transform, which is what decides whether a
    /// segment is a hairline rule or a drawn shape.
    var strokeWidth: Float
}

/// Everything the path machinery produced on one page.
struct PdfPageGraphics: Equatable {
    /// Every `re`, painted or not. Table detection wants these.
    var rectangles: [PdfRect] = []
    /// The subset of `rectangles` that a painting operator confirmed.
    var paintedRectangles: [PdfRect] = []
    /// Axis-aligned rectangles recovered from filled subpaths, which is how
    /// many producers draw a cell background or a rule.
    var filledRectangles: [PdfRect] = []
    /// Rectangles used only as clip paths. They draw nothing, but many PDFs
    /// define table cells this way, so they are kept separately.
    var clipRectangles: [PdfRect] = []
    /// Every stroked segment.
    var lines: [PdfLineSegment] = []
}

/// Points closer than this are the same point, for deciding whether a
/// subpath needs an explicit closing segment.
private let pdfPathClosureEpsilon: Float = 0.01

/// How far a corner may sit off the bounding box and still count as
/// axis-aligned.
private let pdfAxisAlignedEpsilon: Float = 0.5

/// A degenerate rectangle — a rule drawn as a filled sliver, say — is not a
/// rectangle for the fill and clip paths' purposes.
private let pdfMinimumRectangleSide: Float = 1.0

/// A point in device space.
private func pdfTransformPoint(_ x: Float, _ y: Float, _ ctm: PdfMatrix) -> (Float, Float) {
    (x * ctm.a + y * ctm.c + ctm.e, x * ctm.b + y * ctm.d + ctm.f)
}

/// A stroke width in device space.
///
/// Width is measured perpendicular to the path, so the transform is applied
/// to the normal rather than to the width directly — a matrix that scales x
/// and y differently gives a vertical rule and a horizontal one different
/// widths from the same `w`.
private func pdfTransformedStrokeWidth(
    _ lineWidth: Float, _ ctm: PdfMatrix, _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float
) -> Float {
    let userWidth = abs(lineWidth)
    let dx = x2 - x1
    let dy = y2 - y1
    let length = (dx * dx + dy * dy).squareRoot()
    if length <= .ulpOfOne { return userWidth }
    let nx = -dy / length
    let ny = dx / length
    let ndx = nx * ctm.a + ny * ctm.c
    let ndy = nx * ctm.b + ny * ctm.d
    return userWidth * (ndx * ndx + ndy * ndy).squareRoot()
}

/// The bounding rectangle of four segments, if they form an axis-aligned
/// rectangle big enough to matter.
private func pdfRectangleFromSegments(
    _ segments: [(Float, Float, Float, Float)], _ ctm: PdfMatrix
) -> PdfRect? {
    guard segments.count == 4 else { return nil }
    var xs: [Float] = []
    var ys: [Float] = []
    for (x1, y1, x2, y2) in segments {
        xs.append(x1)
        xs.append(x2)
        ys.append(y1)
        ys.append(y2)
    }
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
    else { return nil }
    let width = maxX - minX
    let height = maxY - minY
    // Every corner must lie on an edge of the bounding box, or the four
    // segments are some other quadrilateral.
    let axisAligned =
        xs.allSatisfy { abs($0 - minX) < pdfAxisAlignedEpsilon || abs($0 - maxX) < pdfAxisAlignedEpsilon }
        && ys.allSatisfy {
            abs($0 - minY) < pdfAxisAlignedEpsilon || abs($0 - maxY) < pdfAxisAlignedEpsilon
        }
    guard axisAligned, width > pdfMinimumRectangleSide, height > pdfMinimumRectangleSide
    else { return nil }

    // Only the diagonal of the transform is applied to the extents, exactly
    // as the reference does it: a rotated CTM would give a wrong size here,
    // and neither implementation handles that case.
    let (x, y) = pdfTransformPoint(minX, minY, ctm)
    return PdfRect(x: x, y: y, width: width * ctm.a, height: height * ctm.d)
}

/// Walk a page's operations for paths.
func pdfExtractGraphics(
    _ operations: [PdfOperation], initialCtm: PdfMatrix = (1, 0, 0, 1, 0, 0)
) -> PdfPageGraphics {
    var graphics = PdfPageGraphics()
    var ctm = initialCtm
    var lineWidth: Float = 1
    var stack: [(PdfMatrix, Float)] = []

    // Segments of the subpath being built, in user space.
    var pendingSegments: [(Float, Float, Float, Float)] = []
    // Subpaths already closed by `h`, kept for `f` and `W` to inspect.
    var pendingSubpaths: [[(Float, Float, Float, Float)]] = []
    // `re` rectangles awaiting a painting operator's confirmation.
    var pendingRectangles: [PdfRect] = []
    var subpathStart: (Float, Float)?
    var currentPoint: (Float, Float)?

    func number(_ operands: [PdfObject], _ index: Int, default fallback: Float = 0) -> Float {
        guard index < operands.count, let value = operands[index].asNumber else { return fallback }
        return Float(value)
    }

    /// The segment back to the subpath's start, if the path is not already
    /// there. `h`, `s`, `b` and `b*` all need it.
    func closeSubpath() {
        guard let (cx, cy) = currentPoint, let (sx, sy) = subpathStart else { return }
        if abs(cx - sx) > pdfPathClosureEpsilon || abs(cy - sy) > pdfPathClosureEpsilon {
            pendingSegments.append((cx, cy, sx, sy))
        }
    }

    /// Emit the pending segments as stroked lines.
    func strokePendingSegments() {
        for (x1, y1, x2, y2) in pendingSegments {
            let (dx1, dy1) = pdfTransformPoint(x1, y1, ctm)
            let (dx2, dy2) = pdfTransformPoint(x2, y2, ctm)
            graphics.lines.append(
                PdfLineSegment(
                    x1: dx1, y1: dy1, x2: dx2, y2: dy2,
                    strokeWidth: pdfTransformedStrokeWidth(lineWidth, ctm, x1, y1, x2, y2)))
        }
        pendingSegments = []
    }

    /// A painting operator confirms any `re` rectangles that reached it and
    /// ends the current path.
    func finishPath() {
        graphics.paintedRectangles += pendingRectangles
        pendingRectangles = []
        pendingSegments = []
        pendingSubpaths = []
        subpathStart = nil
        currentPoint = nil
    }

    for operation in operations {
        let operands = operation.operands
        switch operation.operator {
        case "q":
            stack.append((ctm, lineWidth))
        case "Q":
            if let saved = stack.popLast() {
                ctm = saved.0
                lineWidth = saved.1
            }
        case "cm":
            guard operands.count >= 6 else { break }
            let m: PdfMatrix = (
                number(operands, 0, default: 1), number(operands, 1), number(operands, 2),
                number(operands, 3, default: 1), number(operands, 4), number(operands, 5)
            )
            ctm = pdfMultiply(m, ctm)
        case "w":
            lineWidth = number(operands, 0, default: 1)

        case "re":
            guard operands.count >= 4 else { break }
            let rx = number(operands, 0)
            let ry = number(operands, 1)
            let rw = number(operands, 2)
            let rh = number(operands, 3)
            let (x, y) = pdfTransformPoint(rx, ry, ctm)
            let rectangle = PdfRect(x: x, y: y, width: rw * ctm.a, height: rh * ctm.d)
            // Held pending until a paint operator confirms it, and also
            // recorded unconditionally — the two lists answer different
            // questions.
            pendingRectangles.append(rectangle)
            graphics.rectangles.append(rectangle)

        case "m":
            guard operands.count >= 2 else { break }
            let point = (number(operands, 0), number(operands, 1))
            subpathStart = point
            currentPoint = point
        case "l":
            guard operands.count >= 2, let (cx, cy) = currentPoint else { break }
            let point = (number(operands, 0), number(operands, 1))
            pendingSegments.append((cx, cy, point.0, point.1))
            currentPoint = point
        case "h":
            closeSubpath()
            currentPoint = subpathStart
            // A closed subpath is set aside so `f` and `W` can look at it.
            if !pendingSegments.isEmpty {
                pendingSubpaths.append(pendingSegments)
                pendingSegments = []
            }

        case "S", "s":
            if operation.operator == "s" { closeSubpath() }
            strokePendingSegments()
            finishPath()
        case "B", "B*", "b", "b*":
            if operation.operator == "b" || operation.operator == "b*" { closeSubpath() }
            strokePendingSegments()
            finishPath()

        case "f", "F", "f*":
            // Segments never closed by `h` still describe a subpath.
            if !pendingSegments.isEmpty {
                pendingSubpaths.append(pendingSegments)
                pendingSegments = []
            }
            for subpath in pendingSubpaths {
                var segments = subpath
                // Three segments plus an implied closing one is a rectangle
                // drawn without `h`.
                if segments.count == 3 {
                    let (x0, y0, _, _) = segments[0]
                    let (_, _, endX, endY) = segments[2]
                    if abs(endX - x0) > pdfPathClosureEpsilon
                        || abs(endY - y0) > pdfPathClosureEpsilon
                    {
                        segments.append((endX, endY, x0, y0))
                    }
                }
                if let rectangle = pdfRectangleFromSegments(segments, ctm) {
                    graphics.filledRectangles.append(rectangle)
                }
            }
            finishPath()

        case "W", "W*":
            // Many producers define table cells as clip paths. `h` has
            // already moved a closed subpath aside, so look there when
            // nothing is pending.
            var segments = pendingSegments.isEmpty ? (pendingSubpaths.last ?? []) : pendingSegments
            if segments.count == 3, let (sx, sy) = subpathStart {
                let (_, _, endX, endY) = segments[2]
                if abs(endX - sx) > pdfPathClosureEpsilon || abs(endY - sy) > pdfPathClosureEpsilon
                {
                    segments.append((endX, endY, sx, sy))
                }
            }
            if let rectangle = pdfRectangleFromSegments(segments, ctm) {
                graphics.clipRectangles.append(rectangle)
            }
        // The path is deliberately left intact: the `n` that follows ends it.

        case "n":
            // End the path without painting. Any `re` that got here was only
            // ever a clip path, so it drew no ink and is discarded rather
            // than confirmed.
            pendingRectangles = []
            pendingSegments = []
            pendingSubpaths = []
            subpathStart = nil
            currentPoint = nil

        default:
            break
        }
    }
    return graphics
}

/// Rectangles within half a point of each other on every side are the same
/// rectangle.
private let pdfRectangleDedupTolerance: Float = 0.5

/// The reference wants at least this many distinct clip rectangles before it
/// will treat them as a grid; below that they are page furniture.
private let pdfMinimumClipRectangles = 4

/// Fills this many times more numerous than clips mean the clips are
/// section wrappers and the fills are the real cell backgrounds.
private let pdfFillOverClipRatio = 3

/// Sort and deduplicate on a half-point grid.
///
/// Some producers wrap every text block in a full-page clip path, giving
/// thousands of identical rectangles that would otherwise look like a very
/// fine grid. Note the reference *sorts* as part of this, so the deduplicated
/// list comes back in coordinate order rather than document order.
func pdfDedupRectangles(_ rectangles: [PdfRect]) -> [PdfRect] {
    guard rectangles.count > 1 else { return rectangles }
    // The sort key truncates toward zero, as Rust's `as i32` does, so it is
    // not the same as rounding — reproduced rather than improved.
    func key(_ r: PdfRect) -> (Int32, Int32, Int32, Int32) {
        (Int32(r.x * 2), Int32(r.y * 2), Int32(r.width * 2), Int32(r.height * 2))
    }
    let sorted = rectangles.sorted { key($0) < key($1) }
    var result: [PdfRect] = []
    for rectangle in sorted {
        // `dedup_by` compares against the last *kept* element.
        if let last = result.last,
            abs(rectangle.x - last.x) < pdfRectangleDedupTolerance,
            abs(rectangle.y - last.y) < pdfRectangleDedupTolerance,
            abs(rectangle.width - last.width) < pdfRectangleDedupTolerance,
            abs(rectangle.height - last.height) < pdfRectangleDedupTolerance
        {
            continue
        }
        result.append(rectangle)
    }
    return result
}

/// The single rectangle list downstream detection consumes.
///
/// `re` rectangles win outright when the page has any. Otherwise the page
/// drew its structure some other way, and the fallback picks between filled
/// and clipped rectangles — preferring fills when they clearly outnumber the
/// clips, since then the clips are wrappers and the fills are the content.
func pdfSelectedRectangles(_ graphics: PdfPageGraphics) -> [PdfRect] {
    if !graphics.rectangles.isEmpty { return graphics.rectangles }

    let clips = pdfDedupRectangles(graphics.clipRectangles)
    let fills = graphics.filledRectangles
    if !fills.isEmpty, fills.count >= clips.count * pdfFillOverClipRatio { return fills }
    if clips.count >= pdfMinimumClipRectangles { return clips }
    if !fills.isEmpty { return fills }
    return clips
}
