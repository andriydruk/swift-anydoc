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
        for file in walkFiles(directory).filter({ $0.pathExtension == "pdf" }).sorted(by: {
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
