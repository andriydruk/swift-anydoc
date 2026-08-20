// Deterministic corruption sweep over the PDF corpus.
//
// Every other format got one — 650 mutants for `.xls`, 1,050 for `.xlsx`,
// 1,075 for `.doc` — and PDF, by far the largest reader here, did not. The
// mutants come from `scripts/gen-pdf-mutants.py`: a seeded xorshift64* over
// each corpus document, producing byte flips, truncations and zeroed runs.
//
// **What is asserted, and what deliberately is not.**
//
// Asserted: this port never crashes and never hangs, and the number of
// mutants on which it disagrees with the reference does not grow. That is a
// ratchet, not a parity claim.
//
// *Not* asserted: identical output on corrupt input. Measured over 1,384
// mutants, 67 disagree — 20 where this port recovers more text than the
// reference, 22 where it recovers less, 9 where the text differs outright,
// and 16 where the reference refuses the file entirely and this port still
// returns something. The split is near-symmetric, which is the signature of
// two different recovery strategies rather than one being uniformly laxer:
// `PdfDocument` rescans for `N 0 obj` headers where lopdf gives up, and
// lopdf accepts some damaged tables this port rejects.
//
// Demanding exact agreement here would mean reimplementing lopdf's error
// paths byte for byte — a large surface, reachable only by files no producer
// emits. The same tolerance is recorded for `.xls`, whose container layer
// diverges on ~18% of whole-file mutants for the same reason. What must not
// happen is a *regression*: the counts below are the ceiling, and a change
// that pushes past them fails here.
//
// Gated on `ANYDOC_PDF_MUTANTS`, holding the mutants and a `.ref` file beside
// each one the reference accepted.
import Foundation
import Testing

@testable import AnyDoc

@Suite struct PdfMutationSweepTests {
    @Test func mutantsNeitherCrashNorDivergeFromTheReference() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_MUTANTS"],
            !root.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }
        let mutants = names.filter { $0.hasSuffix(".pdf") }.sorted()
        #expect(!mutants.isEmpty, "ANYDOC_PDF_MUTANTS is set but holds no mutants")

        var compared = 0
        var threwHere = 0
        var refusedThere = 0
        var inventedContent: [String] = []
        var diverged: [String] = []

        for name in mutants {
            guard let data = manager.contents(atPath: root + "/" + name) else { continue }
            let expected = try? String(
                contentsOfFile: root + "/" + name + ".ref", encoding: .utf8)

            let ours: String?
            do { ours = try pdfMarkdown([UInt8](data)) } catch { ours = nil }

            guard let expected else {
                // The reference refused this one. Throwing is fine; returning
                // text is not.
                refusedThere += 1
                if let ours, !ours.isEmpty { inventedContent.append(name) }
                continue
            }
            if ours == nil {
                threwHere += 1
                continue
            }
            compared += 1
            if ours != expected { diverged.append(name) }
        }

        print(
            "pdf mutation sweep: \(mutants.count) mutants — \(compared) compared, "
                + "\(diverged.count) diverged, \(refusedThere) refused by the reference, "
                + "\(threwHere) threw here where it did not")
        for name in inventedContent.prefix(5) { print("    invented content: \(name)") }
        for name in diverged.prefix(5) { print("    diverged: \(name)") }

        // The ratchet. Measured at 51 and 16 over 1,384 mutants; these are
        // ceilings, not targets, and lowering them is progress.
        #expect(diverged.count <= 51, "divergences grew: \(diverged.count)")
        #expect(inventedContent.count <= 16, "invented content grew: \(inventedContent.count)")
        // Reaching this line at all is the crash-and-hang assertion: a mutant
        // that trapped or spun would never get here.
        #expect(compared > 0)
    }
}
