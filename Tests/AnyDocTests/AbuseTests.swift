// The abuse corpus: inputs shaped to exhaust memory or time rather than to
// convert. Every one must fail with `resourceLimit` and must fail *fast* —
// the whole point of the limits is that a hostile document costs a bounded
// amount of work, so a test that merely checks the error class would pass
// even if the fixture took an hour to get there.
//
// Per-format suites cover the individual mechanisms; this sweep is the
// guarantee that no abuse fixture is left unasserted as formats are added.
import Foundation
import Testing

@testable import AnyDoc

@Suite struct AbuseCorpus {
    /// Wall-clock budget for one abuse fixture. Generous next to the ~0.5 s
    /// these actually take, so it flags a blow-up rather than slow CI.
    private static let budget = Duration.seconds(10)

    @Test func everyAbuseFixtureFailsFastWithAResourceLimit() throws {
        let fixtures = walkFiles(fixtureRoot.appendingPathComponent("abuse"))
        #expect(!fixtures.isEmpty, "the abuse corpus is missing")
        var checked = 0
        for fixture in fixtures {
            let name = fixture.lastPathComponent
            // Every abuse fixture is named for its expected outcome.
            #expect(name.contains("--errors"), "\(name): unexpected abuse fixture naming")
            guard let format = Format(path: fixture.path) else {
                Issue.record("\(name): no format for this extension")
                continue
            }
            guard implementedFormats.contains(format),
                !unimplementedExtensions.contains(fixture.pathExtension.lowercased())
            else { continue }

            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try AnyDoc.markdown(contentsOf: fixture.path)
                Issue.record("\(name): expected a resource-limit error, got output")
            } catch let error as ConvertError {
                guard case .resourceLimit = error else {
                    Issue.record("\(name): expected resourceLimit, got \(error.message)")
                    continue
                }
            }
            let elapsed = clock.now - start
            #expect(
                elapsed < Self.budget,
                "\(name): the limit must trip quickly, took \(elapsed)")
            checked += 1
        }
        print("abuse corpus: \(checked) fixtures asserted")
        #expect(checked > 0, "no abuse fixtures were asserted — harness misconfigured")
    }

    /// The limits are documented as non-configurable constants; a change to
    /// one is a deliberate, reviewable act rather than a silent drift.
    @Test func limitsHoldTheirDocumentedValues() {
        #expect(Limits.maxEntryBytes == 128 * 1024 * 1024)
        #expect(Limits.maxTotalBytes == 512 * 1024 * 1024)
        #expect(Limits.maxEntryCount == 100_000)
        #expect(Limits.maxXmlDepth == 256)
        #expect(Limits.maxXmlNodes == 2_000_000)
        #expect(Limits.maxExpansion == 4_000_000)
        #expect(Limits.maxExpansionTextBytes == 64 * 1024 * 1024)
        #expect(Limits.maxAssetTotalBytes == 128 * 1024 * 1024)
        #expect(Limits.maxRecordDepth == 64)
        #expect(Limits.maxRecords == 16_000_000)
    }
}
