import Foundation
import Testing

@testable import AnyDoc

/// Differential check of NFKC against `unicode-normalization`, the crate the
/// reference uses, over every codepoint.
///
/// The dump also carries the tables this port was generated from, so the
/// comparison is not circular in the way it might appear: the `N` lines are
/// the crate's *answers*, produced by its own algorithm, while the port runs
/// its own three stages over the extracted data.
@Suite struct PdfNfkcProbeTests {
    @Test func nfkcMatchesTheReferenceForEveryCodepoint() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_NFKC_DUMP"], !path.isEmpty,
            let dump = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }

        var compared = 0
        var mismatches: [String] = []
        for line in dump.split(separator: "\n") {
            guard line.hasPrefix("N ") else { continue }
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let codepoint = UInt32(fields[1], radix: 16),
                let scalar = Unicode.Scalar(codepoint)
            else { continue }
            compared += 1

            let expected = fields.dropFirst(2).compactMap { UInt32($0, radix: 16) }
            let ours = Array(pdfNfkc(String(scalar)).unicodeScalars).map(\.value)
            if ours != expected && mismatches.count < 20 {
                mismatches.append(
                    "U+\(String(codepoint, radix: 16, uppercase: true)): "
                        + "ours \(ours.map { String($0, radix: 16) }) "
                        + "rust \(expected.map { String($0, radix: 16) })")
            }
        }
        // Sequences, which are the only thing that exercises canonical
        // ordering and composition blocking.
        var sequences = 0
        for line in dump.split(separator: "\n") {
            guard line.hasPrefix("S ") else { continue }
            let halves = line.dropFirst(2).split(separator: "|")
            guard halves.count == 2 else { continue }
            let input = halves[0].split(separator: " ").compactMap { UInt32($0, radix: 16) }
            let expected = halves[1].split(separator: " ").compactMap { UInt32($0, radix: 16) }
            var view = String.UnicodeScalarView()
            for value in input {
                if let scalar = Unicode.Scalar(value) { view.append(scalar) }
            }
            sequences += 1
            let ours = Array(pdfNfkc(String(view)).unicodeScalars).map(\.value)
            if ours != expected && mismatches.count < 20 {
                mismatches.append(
                    "seq \(input.map { String($0, radix: 16) }): "
                        + "ours \(ours.map { String($0, radix: 16) }) "
                        + "rust \(expected.map { String($0, radix: 16) })")
            }
        }

        print("pdf nfkc probe: \(compared) codepoints and \(sequences) sequences compared")
        #expect(sequences > 1000, "the sequence cases look missing")
        #expect(compared > 1_000_000, "the dump looks truncated")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) nfkc divergences:\n\(report)")
    }
}
