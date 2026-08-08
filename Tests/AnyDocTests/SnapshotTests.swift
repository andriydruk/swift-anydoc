// Fixture corpus snapshot harness.
//
// One golden file per fixture (converted from anydoc's insta snapshots by
// scripts/import-goldens.py) holds the expected conversion result: the
// Markdown output, or the terminal error rendered as `ERROR: <message>`.
// Comparison is byte-exact modulo one trailing newline (which insta
// normalizes on save); the trailing-newline contract is asserted separately.
//
// Formats not yet ported are skipped and counted, so the sweep stays green
// while the port progresses format by format.
import Foundation
import Testing
@testable import AnyDoc

/// Formats the Swift port implements so far. Grows phase by phase; a format
/// listed here has every one of its fixtures compared byte-for-byte.
let implementedFormats: Set<Format> = [.csv, .docx, .epub, .pptx, .odt, .ods, .odp, .excel, .rtf, .ppt, .doc]

/// Extensions still awaiting a parser inside an otherwise implemented
/// format. `Format.excel` covers both the SpreadsheetML package and the
/// legacy binary workbook; only the former is ported.
let unimplementedExtensions: Set<String> = ["xlsb"]

private let testsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AnyDocTests
    .deletingLastPathComponent()  // Tests

let fixtureRoot = testsDir.appendingPathComponent("Fixtures")
let goldenRoot = testsDir.appendingPathComponent("Golden")

/// Recursively collect every file under `dir`, sorted for determinism.
func walkFiles(_ dir: URL) -> [URL] {
    let fm = FileManager.default
    var out: [URL] = []
    let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for entry in entries.sorted(by: { $0.path < $1.path }) {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: entry.path, isDirectory: &isDir)
        if isDir.boolValue {
            out.append(contentsOf: walkFiles(entry))
        } else {
            out.append(entry)
        }
    }
    return out
}

/// Convert one fixture the way the Rust snapshot harness does: the Markdown,
/// or the terminal error as `ERROR: <display>`.
func convertForSnapshot(_ path: String) -> String {
    do {
        return try AnyDoc.markdown(contentsOf: path)
    } catch let error as ConvertError {
        return "ERROR: \(error.message)"
    } catch {
        return "ERROR: \(error)"
    }
}

private func trimTrailingNewlines(_ s: String) -> Substring {
    var out = Substring(s)
    while out.hasSuffix("\n") { out = out.dropLast() }
    return out
}

@Suite struct SnapshotCorpus {
    @Test func corpus() throws {
        var compared = 0
        var skipped = 0
        for fixture in walkFiles(fixtureRoot) {
            let rel = fixture.path.replacingOccurrences(of: fixtureRoot.path + "/", with: "")
            if rel.hasPrefix("abuse/") || rel.hasSuffix(".md") {
                continue
            }
            guard let format = Format(path: fixture.path) else {
                continue
            }
            let ext = fixture.pathExtension.lowercased()
            guard implementedFormats.contains(format), !unimplementedExtensions.contains(ext) else {
                skipped += 1
                continue
            }
            let goldenName = rel.replacingOccurrences(of: "/", with: "__") + ".golden"
            let goldenPath = goldenRoot.appendingPathComponent(goldenName)
            let golden = try String(contentsOf: goldenPath, encoding: .utf8)
            let output = convertForSnapshot(fixture.path)
            #expect(
                trimTrailingNewlines(output) == trimTrailingNewlines(golden),
                "fixture \(rel) diverges from the Rust reference output")
            // The renderer's own contract: empty output, or exactly one
            // trailing newline (insta normalizes this away in goldens).
            #expect(output.isEmpty || (output.hasSuffix("\n") && !output.hasSuffix("\n\n"))
                    || output.hasPrefix("ERROR:"),
                "fixture \(rel): output must end with exactly one newline")
            compared += 1
        }
        print("snapshot corpus: \(compared) compared, \(skipped) skipped (formats not yet ported)")
        #expect(compared > 0, "no fixtures were compared — harness misconfigured")
    }
}
