// PPTX abuse-fixture behavior. The Rust pptx module (mod.rs, cascade.rs)
// carries no inline unit tests; functional parity is asserted by the snapshot
// corpus. This suite covers the resource-limit contract, which the corpus
// excludes (abuse fixtures are skipped there).
import Foundation
import Testing
@testable import AnyDoc

@Suite struct PptxTests {
    /// The huge-span abuse deck declares an absurd `gridSpan`/`rowSpan` on a
    /// tiny table. The span area must be charged against the expansion budget
    /// *before* any covered position materializes, so the conversion fails
    /// with `resourceLimit` quickly and in bounded memory instead of
    /// expanding the grid.
    @Test func hugeSpanHitsExpansionBudget() throws {
        let path = fixtureRoot.appendingPathComponent("abuse/hugespan--errors.pptx").path
        let bytes = try readFile(path)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try AnyDoc.markdown(bytes, format: .pptx)
            Issue.record("expected a resourceLimit error, got success")
        } catch let error as ConvertError {
            #expect(error.code == "resourceLimit",
                "expected resourceLimit, got \(error.code): \(error.message)")
        }
        // Generous wall-time bound: the budget trips before expansion, so
        // even a slow CI machine stays far under this.
        #expect(clock.now - start < .seconds(10), "conversion must fail fast, not expand")
    }
}
