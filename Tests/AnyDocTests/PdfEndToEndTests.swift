import Foundation
import Testing

@testable import AnyDoc

/// Whole-document comparison: a PDF's bytes through this port's pipeline,
/// against the same bytes through the reference's `process_pdf_mem`.
///
/// This is the bar `PLAN.md` §2 names — byte-identical Markdown from the
/// reference binary — and wave 99 is the first time it could be run at all,
/// because until then nothing in `Sources` turned a document into Markdown.
///
/// **It is expected to diverge, and by how much is the point.** The port's
/// pipeline has no detector, no table or image detection, and no structure
/// tree, so a document needing any of those will differ. Counting which
/// files match, and why the rest do not, is how the remaining work gets
/// ordered — so this suite reports the tally rather than failing on it, and
/// fails only if a file that *did* match stops matching.
@Suite struct PdfEndToEndTests {
    /// Files known to convert byte-identically. Adding to this list is the
    /// measure of progress; a file leaving it is a regression.
    private static let matching: Set<String> = [
        "annotations.pdf",
        "arith-kerning.pdf",
        "arith-leading.pdf",
        "arith-negative.pdf",
        "arith-nested.pdf",
        "arith-render.pdf",
        "arith-spacing.pdf",
        "arith-ts.pdf",
        "arith-tz.pdf",
        "bad-xref-offsets.pdf",
        "cid-font.pdf",
        "classic-xref.pdf",
        "content-array.pdf",
        "content-shapes.pdf",
        "encrypted-aes-v4.pdf",
        "encrypted-rc4-r2.pdf",
        "encrypted-rc4-r3.pdf",
        "filter-ascii85.pdf",
        "filter-chained.pdf",
        "filter-lzw.pdf",
        "filter-none.pdf",
        "font-actualtext.pdf",
        "font-cid-bfchar.pdf",
        "font-cid-bfrange.pdf",
        "font-cid-collapse.pdf",
        "font-differences.pdf",
        "font-embedded-cmap.pdf",
        "font-no-widths.pdf",
        "font-opentype-cmap.pdf",
        "gap-chart.pdf",
        "gap-newspaper.pdf",
        "gap-rotated.pdf",
        "gap-tagged.pdf",
        "tagged-table.pdf", "tagged-table-sparse.pdf",
        "rect-guided-calendar.pdf", "two-column-prose.pdf", "path-drawn-table.pdf",
        "detector-identityh-bare.pdf", "detector-identityh-unicode-w.pdf",
        "detector-type3-only.pdf", "detector-mixed-fonts.pdf",
        "decode-control-bytes.pdf", "chart-bars.pdf", "letterspaced-heading.pdf", "encrypted-aes-256.pdf", "table-continuation.pdf",
        "decode-c1-controls.pdf", "decode-symbol-pua.pdf",
        "decode-texcm-symbols.pdf", "garbled-text-document.pdf", "font-cid-to-gid.pdf",
        "image-small.pdf", "image-template.pdf", "image-tiled.pdf",
        "image-in-form.pdf", "vector-text.pdf", "empty-page.pdf",
        "mixed-image-and-text.pdf", "ratio-exactly-threshold.pdf",
        "gap-xobject-text.pdf",
        "graphics-clips.pdf",
        "graphics-fills.pdf",
        "graphics-rects.pdf",
        "incremental-update.pdf",
        "indirect-length.pdf",
        "lying-length.pdf",
        "md-captions.pdf",
        "md-cleanup.pdf",
        "md-dropcap.pdf",
        "md-headings.pdf",
        "md-lists.pdf",
        "md-multipage.pdf",
        "md-styles.pdf",
        "md-table-lines.pdf",
        "md-table-rects.pdf",
        "merge-fragments.pdf",
        "merge-thresholds.pdf",
        "object-stream.pdf",
        "two-column.pdf",
        "underline-basic.pdf",
        "underline-fraction.pdf",
        "underline-segmented.pdf",
        "underline-table.pdf",
        "xref-stream-narrow-w.pdf",
        "xref-stream-predictor.pdf",
        "xref-stream.pdf",
    ]

    @Test func documentsConvertAsTheReferenceDoes() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"], !path.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return }

        var matched: [String] = []
        var diverged: [String] = []
        var failed: [String] = []
        var regressions: [String] = []

        for name in names.filter({ $0.hasSuffix(".pdf") }).sorted() {
            // The reference's own answer, produced beside the PDF. A file it
            // refuses has no `.md` and is not compared.
            guard let expected = try? String(contentsOfFile: path + "/" + name + ".md", encoding: .utf8)
            else { continue }
            guard let data = manager.contents(atPath: path + "/" + name) else { continue }

            let ours: String
            do {
                ours = try pdfMarkdown([UInt8](data))
            } catch {
                failed.append(name)
                if Self.matching.contains(name) { regressions.append("\(name): threw \(error)") }
                continue
            }

            if ours == expected {
                matched.append(name)
            } else {
                diverged.append(name)
                if Self.matching.contains(name) {
                    regressions.append(
                        "\(name): was byte-identical, now differs\n"
                            + "      ours: \(ours.prefix(120).debugDescription)\n"
                            + "      rust: \(expected.prefix(120).debugDescription)")
                }
            }
        }

        let total = matched.count + diverged.count + failed.count
        print(
            "pdf end-to-end: \(matched.count)/\(total) byte-identical, "
                + "\(diverged.count) diverged, \(failed.count) threw")
        if !diverged.isEmpty {
            print("    diverged: \(diverged.prefix(12).joined(separator: " "))")
        }
        if !failed.isEmpty { print("    threw: \(failed.joined(separator: " "))") }
        if ProcessInfo.processInfo.environment["ANYDOC_LIST_MATCHING"] != nil {
            for name in matched { print("MATCH \(name)") }
        }
        // Set ANYDOC_SHOW_DIFF to print the first differing line of every
        // divergence — which is how the remaining gaps get diagnosed.
        if ProcessInfo.processInfo.environment["ANYDOC_SHOW_DIFF"] != nil {
            for name in diverged {
                guard
                    let expected = try? String(
                        contentsOfFile: path + "/" + name + ".md", encoding: .utf8),
                    let data = manager.contents(atPath: path + "/" + name),
                    let ours = try? pdfMarkdown([UInt8](data))
                else { continue }
                let theirLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
                let ourLines = ours.split(separator: "\n", omittingEmptySubsequences: false)
                print("DIFF \(name)")
                for index in 0..<max(theirLines.count, ourLines.count) {
                    let theirs = index < theirLines.count ? String(theirLines[index]) : "<none>"
                    let mine = index < ourLines.count ? String(ourLines[index]) : "<none>"
                    if theirs != mine {
                        print("  line \(index + 1)\n    rust: \(theirs.prefix(90))")
                        print("    ours: \(mine.prefix(90))")
                        break
                    }
                }
            }
        }

        let report = regressions.joined(separator: "\n")
        #expect(
            regressions.isEmpty,
            "\(regressions.count) file(s) left the matching set:\n\(report)")
        // Every file matches again — including the five `gap-*` documents
        // built to fail — so any divergence at all is a regression.
        #expect(
            diverged.isEmpty && failed.isEmpty,
            "\(diverged.count) diverged, \(failed.count) threw — the corpus was whole")
    }
}
