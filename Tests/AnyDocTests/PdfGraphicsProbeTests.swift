import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the graphics-path walker against the reference's
/// own, run inside a vendored pdf-inspector.
///
/// The reference does not hand out its four path lists separately: it
/// publishes one `rects` list whose provenance depends on what the page drew
/// — `re` rectangles when there are any, otherwise filled-subpath rectangles,
/// otherwise clip rectangles. `pdfSelectedRectangles` reproduces that choice,
/// and the corpus carries one file per branch so all three are compared. The
/// `lines` list is compared directly.
///
/// **Not covered here:** `paintedRectangles`, which the reference keeps to
/// itself for underline detection. Unit tests pin it instead.
///
///   scripts/gen-pdf-corpus.py /tmp/pdfcorpus
///   for f in /tmp/pdfcorpus/*.pdf; do
///     pdfinspector/target/release/graphicsprobe "$f" > "$f.graphics" 2>/dev/null
///   done
///   ANYDOC_PDF_CORPUS=/tmp/pdfcorpus swift test --filter PdfGraphicsProbe
@Suite struct PdfGraphicsProbeTests {
    /// Corpus files whose divergence is a stage this port has not wired
    /// yet, listed by name so the exclusion shrinks as the gaps close.
    /// `PdfEndToEndTests` tracks the same files, so nothing goes unmeasured.
    /// Empty: every corpus file now agrees. Kept as the place to name a
    /// file whose divergence is a stage that is knowingly unported, so an
    /// exclusion always has to be written down rather than assumed.
    static let unwiredGaps: Set<String> = []

    /// Format a float the way the probe does, so the two dumps compare as
    /// text rather than through a tolerance nobody chose deliberately.
    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    @Test func graphicsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"], !path.isEmpty
        else { return }
        let directory = URL(fileURLWithPath: path)

        var compared = 0
        var mismatches: [String] = []
        // The `unwiredGaps` files exercise stages this port has not wired
        // yet, so they are expected to differ here. `PdfEndToEndTests`
        // tracks the same files by name, so nothing goes unmeasured.
        for file in walkFiles(directory).filter({
            $0.pathExtension == "pdf"
                && !PdfGraphicsProbeTests.unwiredGaps.contains($0.lastPathComponent)
        }).sorted(by: {
            $0.path < $1.path
        }) {
            let dumpPath = file.appendingPathExtension("graphics")
            guard let expected = try? String(contentsOf: dumpPath, encoding: .utf8),
                expected.hasPrefix("#PAGE")
            else { continue }
            guard var document = try? PdfDocument(bytes: [UInt8](try Data(contentsOf: file)))
            else { continue }

            var ours: [String] = []
            for (index, page) in pdfPages(&document).enumerated() {
                let graphics = pdfExtractGraphics(pdfPageOperations(&document, page))
                // The probe reports rotation, which this port does not
                // implement; the corpus is all upright, so it is asserted
                // rather than reproduced.
                ours.append("#PAGE \(index + 1) rotated=false")
                for rectangle in pdfSelectedRectangles(graphics) {
                    ours.append(
                        "rect \(format(rectangle.x)) \(format(rectangle.y)) "
                            + "\(format(rectangle.width)) \(format(rectangle.height))")
                }
                for line in graphics.lines {
                    ours.append(
                        "line \(format(line.x1)) \(format(line.y1)) "
                            + "\(format(line.x2)) \(format(line.y2))")
                }
            }

            let theirs = expected.split(separator: "\n").map(String.init)
            if ours != theirs {
                var diff: [String] = []
                for index in 0..<max(ours.count, theirs.count) {
                    let a = index < ours.count ? ours[index] : "<none>"
                    let b = index < theirs.count ? theirs[index] : "<none>"
                    if a != b { diff.append("    ours:  \(a)\n    rust:  \(b)") }
                }
                mismatches.append(
                    "\(file.lastPathComponent)\n\(diff.joined(separator: "\n"))")
            }
            compared += 1
        }
        print("pdf graphics probe: \(compared) files compared")
        let report = mismatches.prefix(6).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) graphics divergences:\n\(report)")
    }
}

/// Differential check of geometric underline and strikeout detection.
///
/// The reference marks these inside its extraction pass, so the items come
/// back already decorated and the probe just dumps the flags. This is also
/// the only end-to-end check of `paintedRectangles`, which the graphics probe
/// cannot see.
///
///   for f in <corpus>/*.pdf; do
///     graphicsprobe --underline "$f" > "$f.underline"
///   done
@Suite struct PdfUnderlineProbeTests {
    private func format(_ value: Float) -> String { String(format: "%.3f", value) }

    @Test func underlineFlagsMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"], !path.isEmpty
        else { return }
        let directory = URL(fileURLWithPath: path)

        var compared = 0
        var mismatches: [String] = []
        // The `unwiredGaps` files exercise stages this port has not wired
        // yet, so they are expected to differ here. `PdfEndToEndTests`
        // tracks the same files by name, so nothing goes unmeasured.
        for file in walkFiles(directory).filter({
            $0.pathExtension == "pdf"
                && !PdfGraphicsProbeTests.unwiredGaps.contains($0.lastPathComponent)
        }).sorted(by: {
            $0.path < $1.path
        }) {
            let dumpPath = file.appendingPathExtension("underline")
            guard let expected = try? String(contentsOf: dumpPath, encoding: .utf8),
                expected.hasPrefix("#PAGE")
            else { continue }
            guard var document = try? PdfDocument(bytes: [UInt8](try Data(contentsOf: file)))
            else { continue }

            var ours: [String] = []
            for (index, page) in pdfPages(&document).enumerated() {
                // Form XObjects are spliced in, as the pipeline does: the
                // reference walks into them, so a probe that did not would
                // report every form's text as missing.
                let (operations, formFonts) = pdfPageOperationsWithForms(&document, page)
                let graphics = pdfExtractGraphics(operations)
                // The reference's own order: extract, mark decoration, then
                // merge fragments into words, then absorb scripts.
                var items = pdfLayoutItems(pdfPageTextRuns(&document, page))
                var styles = pdfPageFontStyles(&document, page)
                for (name, font) in formFonts { styles[name] = pdfFontStyle(&document, font) }
                pdfApplyFontStyles(&items, styles)
                pdfMarkUnderlines(
                    &items, rectangles: pdfUnderlineInk(graphics), lines: graphics.lines)
                items = pdfMergeSubscriptItems(pdfMergeTextItems(items))
                ours.append("#PAGE \(index + 1)")
                for item in items {
                    let text = item.text.rustTrim()
                    ours.append(
                        "item \(item.isUnderline ? 1 : 0) \(item.isStrikeout ? 1 : 0) "
                            + "\(format(item.width)) \(text)")
                }
            }

            let theirs = expected.split(separator: "\n").map(String.init)
            if ours != theirs {
                var diff: [String] = []
                for index in 0..<max(ours.count, theirs.count) {
                    let a = index < ours.count ? ours[index] : "<none>"
                    let b = index < theirs.count ? theirs[index] : "<none>"
                    if a != b { diff.append("    ours:  \(a)\n    rust:  \(b)") }
                }
                mismatches.append("\(file.lastPathComponent)\n\(diff.joined(separator: "\n"))")
            }
            compared += 1
        }
        print("pdf underline probe: \(compared) files compared")
        let report = mismatches.prefix(6).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) underline divergences:\n\(report)")
    }
}
