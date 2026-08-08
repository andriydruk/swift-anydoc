import Testing

#if canImport(Foundation)
    import Foundation
#endif

@testable import AnyDoc

/// Differential check of the line classifiers against the reference's own
/// `markdown/classify.rs`, compiled verbatim into a probe binary.
///
/// These predicates are small enough to look obviously right and are not:
/// every one of them has an edge the reference decides by accident of how it
/// was written — an empty `all()` that returns true, a byte-length bound, a
/// `strip_prefix` that does not require the space it looks like it requires.
/// Reading the Rust is how those were found; running it is how they stay
/// found.
///
/// `ANYDOC_CLASSIFY_PROBE` points at a directory holding `classify-cases.txt`
/// (one escaped probe string per line) and `classify-rust.txt` (the probe
/// binary's output). Both are build products; see PLAN.md for the recipe. The
/// suite skips when the variable is unset.
@Suite struct PdfClassifyProbeTests {
    private var probeDirectory: String? {
        #if canImport(Foundation)
            guard let path = ProcessInfo.processInfo.environment["ANYDOC_CLASSIFY_PROBE"],
                !path.isEmpty
            else { return nil }
            return path
        #else
            return nil
        #endif
    }

    /// Undo the probe's escaping: `\p` is a pipe, since pipe separates the
    /// output's fields.
    ///
    /// Scalars throughout, never characters. A backslash followed by a
    /// combining mark is one Swift `Character`, so a grapheme-wise reader
    /// mangles exactly the rows this probe exists to check.
    func unescape<S: StringProtocol>(_ text: S) -> String {
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "p": result.append("|")
            case "\\": result.append("\\")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return String(result)
    }

    func escape(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
            case "|": result.append(contentsOf: "\\p".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// Split a row on the field separator by scalar, for the same reason.
    func fields(of row: Substring) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in row.unicodeScalars {
            if scalar == "|" {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        pieces.append(String(current))
        return pieces
    }

    @Test func classifiersAgreeWithTheReference() throws {
        #if canImport(Foundation)
            guard let directory = probeDirectory else { return }
            let expected = try String(
                contentsOfFile: directory + "/classify-rust.txt", encoding: .utf8)

            var compared = 0
            var mismatches: [String] = []
            for row in expected.split(separator: "\n") {
                // The probe never emits a bare field separator, so splitting
                // on it recovers the fields exactly.
                let fields = fields(of: row)
                guard fields.count == 10 else {
                    mismatches.append("malformed probe row: \(row)")
                    continue
                }
                let text = unescape(fields[0])
                let ours = [
                    pdfIsCaptionLine(text) ? "1" : "0",
                    pdfStartsWithBulletMarker(text) ? "1" : "0",
                    pdfIsListItem(text) ? "1" : "0",
                    escape(pdfFormatListItem(text)),
                    pdfIsCodeLike(text) ? "1" : "0",
                    pdfIsMonospaceFont(text) ? "1" : "0",
                    pdfHasDotLeaders(text) ? "1" : "0",
                    pdfStyleFromFontName(text).bold ? "1" : "0",
                    pdfStyleFromFontName(text).italic ? "1" : "0",
                ]
                let theirs = Array(fields[1...])
                if ours != theirs {
                    let names = [
                        "caption", "bullet", "list", "format", "code", "mono", "leaders",
                        "bold", "italic",
                    ]
                    let differing = zip(names, zip(ours, theirs))
                        .filter { $0.1.0 != $0.1.1 }
                        .map { "\($0.0): ours=\($0.1.0) rust=\($0.1.1)" }
                        .joined(separator: ", ")
                    mismatches.append("\(fields[0]) → \(differing)")
                }
                compared += 1
            }
            print("pdf classify probe: \(compared) strings compared")
            let report = mismatches.prefix(20).joined(separator: "\n")
            #expect(
                mismatches.isEmpty,
                "\(mismatches.count) classifier divergences:\n\(report)")
        #endif
    }
}

/// Differential check of the Markdown cleanup passes against
/// `markdown/postprocess.rs`, compiled verbatim into the same probe binary.
///
/// The reference implements three of these with regexes; this port hand-wrote
/// them to stay dependency-free, which means the hand-written versions have
/// to be shown equivalent rather than assumed so — including where the
/// patterns behave unexpectedly, as `replace_all`'s non-overlapping matches
/// do on `a - b - c`.
@Suite struct PdfPostprocessProbeTests {
    @Test func cleanupPassesAgreeWithTheReference() throws {
        #if canImport(Foundation)
            guard let path = ProcessInfo.processInfo.environment["ANYDOC_CLASSIFY_PROBE"],
                !path.isEmpty
            else { return }
            let expected = try String(
                contentsOfFile: path + "/postprocess-rust.txt", encoding: .utf8)

            let shared = PdfClassifyProbeTests()
            var compared = 0
            var mismatches: [String] = []
            for row in expected.split(separator: "\n") {
                let fields = shared.fields(of: row)
                guard fields.count == 9 else {
                    mismatches.append("malformed probe row: \(row)")
                    continue
                }
                let text = shared.unescape(fields[0])
                let ours = [
                    shared.escape(pdfCollapseConsecutiveSpaces(text)),
                    shared.escape(pdfRemoveSpacesBeforeClosingBrackets(text)),
                    shared.escape(pdfRemoveSpacesBeforeSentencePunctuation(text)),
                    shared.escape(pdfCollapseDotLeaders(text)),
                    shared.escape(pdfFixHyphenation(text)),
                    shared.escape(pdfRemovePageNumbers(text)),
                    pdfIsPageNumberLine(text.rustTrim()) ? "1" : "0",
                    shared.escape(pdfFormatUrls(text)),
                ]
                let theirs = Array(fields[1...])
                if ours != theirs {
                    let names = [
                        "spaces", "brackets", "punctuation", "dot-leaders", "hyphenation",
                        "page-numbers", "is-page-number", "urls",
                    ]
                    let differing = zip(names, zip(ours, theirs))
                        .filter { $0.1.0 != $0.1.1 }
                        .map { "\($0.0): ours=\($0.1.0) rust=\($0.1.1)" }
                        .joined(separator: ", ")
                    mismatches.append("\(fields[0]) → \(differing)")
                }
                compared += 1
            }
            print("pdf cleanup probe: \(compared) strings compared")
            let report = mismatches.prefix(20).joined(separator: "\n")
            #expect(mismatches.isEmpty, "\(mismatches.count) cleanup divergences:\n\(report)")
        #endif
    }
}
