// Which corpus documents no oracle can tell apart.
//
// A fixture earns its place by being able to *disagree*. Three waves running
// found fixtures that could not: wave 152's `--fontstyle` oracle scored a
// column of zeros, wave 157's list drew a bullet StandardEncoding leaves
// unassigned so the classifiers were never reached, and wave 158's
// `xref-stream-narrow-w` was misaligned by one byte, so both sides failed to
// read it and agreed on nothing at all for fifty waves.
//
// This makes the question standing rather than manual: group the corpus by
// the tuple of every oracle dump, and report the groups where two documents
// are identical in all of them. Such a group is not automatically wrong —
// most of this corpus's are deliberate — but it is the list to read when a
// fixture stops earning its keep.
//
// **It reports and does not fail.** Which groups are intentional is a
// judgement about intent that no assertion can make, and a list that fails
// would be silenced rather than read.
import Foundation
import Testing

@testable import AnyDoc

@Suite struct PdfCorpusDiscriminationTests {
    /// Every dump `gen-pdf-oracles.sh` writes beside a document.
    private static let dumps = [
        ".md", ".expected", ".graphics", ".underline",
        ".detectdoc", ".pagefonts", ".pageanalysis", ".fontstyle",
    ]

    @Test func reportDocumentsNoOracleTellsApart() throws {
        guard let root = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"],
            !root.isEmpty
        else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }
        let documents = names.filter { $0.hasSuffix(".pdf") }.sorted()
        #expect(!documents.isEmpty, "ANYDOC_PDF_CORPUS names no PDFs")

        var bySignature: [String: [String]] = [:]
        for document in documents {
            var signature = ""
            for dump in Self.dumps {
                let path = root + "/" + document + dump
                let contents = manager.contents(atPath: path).map { [UInt8]($0) } ?? []
                // Length and a cheap checksum: enough to separate documents
                // without hashing megabytes of graphics dumps.
                signature += "\(contents.count):\(contents.reduce(UInt32(17)) { $0 &* 31 &+ UInt32($1) })|"
            }
            bySignature[signature, default: []].append(String(document.dropLast(4)))
        }

        let groups = bySignature.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted {
            $0[0] < $1[0]
        }
        print(
            "pdf corpus discrimination: \(documents.count) documents, "
                + "\(groups.count) group(s) no oracle separates")
        for group in groups { print("    " + group.joined(separator: " ")) }
    }
}
