import Foundation
import Testing

@testable import AnyDoc

/// Reports which differential gates were set for this run.
///
/// Every probe suite in this package is gated on an environment variable
/// naming a generated corpus, and a suite whose variable is unset returns
/// before comparing anything — reporting as a pass. That is the right
/// behaviour for a fresh checkout, which cannot build the oracles, but it
/// means `swift test` reports green whether or not a single comparison ran.
///
/// Six of the seven gates were unset for more than thirty waves before wave
/// 98 checked. This suite makes the state visible at the end of every run:
/// it never fails, it just says what was and was not compared.
///
/// `scripts/run-probes.sh` sets all seven.
@Suite struct PdfProbeCoverageTests {
    /// Every gate, with what it turns on.
    private static let gates: [(variable: String, covers: String)] = [
        ("ANYDOC_GRID_PROBE", "48 suites — layout, tables, headings, markdown"),
        ("ANYDOC_PDF_CORPUS", "object graph vs lopdf, graphics and underline"),
        ("ANYDOC_FONT_CORPUS", "font descriptor style flags"),
        ("ANYDOC_MCID_CORPUS", "marked-content id tracking"),
        ("ANYDOC_STRUCT_CORPUS", "structure-tree parsing"),
        ("ANYDOC_CLASSIFY_PROBE", "line classifiers and cleanup"),
        ("ANYDOC_NFKC_DUMP", "NFKC over every codepoint"),
    ]

    @Test func reportDifferentialCoverage() {
        let environment = ProcessInfo.processInfo.environment
        var set: [String] = []
        var unset: [(String, String)] = []
        for gate in Self.gates {
            if let value = environment[gate.variable], !value.isEmpty {
                set.append(gate.variable)
            } else {
                unset.append((gate.variable, gate.covers))
            }
        }

        if unset.isEmpty {
            print("pdf differential coverage: all \(Self.gates.count) gates set")
            return
        }
        print(
            "pdf differential coverage: \(set.count) of \(Self.gates.count) gates set — "
                + "\(unset.count) suite group(s) compared NOTHING this run:")
        for (variable, covers) in unset { print("    unset \(variable) — \(covers)") }
        print("    run scripts/run-probes.sh <work-dir> to set all of them")
    }
}
