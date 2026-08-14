import Foundation
import Testing

@testable import AnyDoc

/// Differential check of the reading-order leaves against `page_x_bounds`,
/// `group_rows`, `side_is_prose` and `aligned_row_split`.
@Suite struct PdfReadingOrderProbeTests {
    @Test func readingOrderLeavesMatchTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_GRID_PROBE"], !path.isEmpty
        else { return }
        guard
            let caseText = try? String(contentsOfFile: path + "/reading-cases.txt", encoding: .utf8),
            let expectedText = try? String(
                contentsOfFile: path + "/reading-rust.txt", encoding: .utf8)
        else { return }

        let cases = caseText.split(separator: "\n").map(String.init)
        let expected = expectedText.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
        #expect(cases.count == expected.count, "case and answer counts disagree")

        var mismatches: [String] = []
        var verdicts: [String: Int] = [:]
        for (index, line) in cases.enumerated() where index < expected.count {
            guard let ours = answer(for: line) else { continue }
            verdicts[String(ours.prefix(2)), default: 0] += 1
            if ours != expected[index] {
                mismatches.append("\(line)\n    ours: \(ours)\n    rust: \(expected[index])")
            }
        }
        let shape = verdicts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        print("pdf reading-order probe: \(cases.count) cases compared — \(shape)")
        let report = mismatches.prefix(5).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) reading-order divergences:\n\(report)")
    }

    private func answer(for line: String) -> String? {
        let parts = line.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
        guard let tag = parts.first else { return nil }
        switch tag {
        case "B":
            guard let bar = parts.firstIndex(of: "|"), let semi = parts.firstIndex(of: ";")
            else { return nil }
            let images: [PdfImageRegion] = parts[(bar + 1)..<semi].compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                    let x1 = Float(f[2]), let y1 = Float(f[3])
                else { return nil }
                return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
            }
            guard let bounds = pdfPageXBounds(items(parts[(semi + 1)...]), images)
            else { return "b -" }
            return "b \(twoPlaces(bounds.xMin)):\(twoPlaces(bounds.xMax))"
        case "G":
            guard let semi = parts.firstIndex(of: ";") else { return nil }
            let rows = pdfGroupRows(items(parts[(semi + 1)...]))
            var out = "gr \(rows.count)"
            for row in rows {
                out += " \(row.items.count)@\(twoPlaces(row.y))"
                for item in row.items { out += ",\(onePlace(item.x))" }
            }
            return out
        case "W":
            guard let semi = parts.firstIndex(of: ";") else { return nil }
            return "w \(pdfSideIsProse(items(parts[(semi + 1)...])) ? 1 : 0)"
        case "L":
            guard let bar = parts.firstIndex(of: "|"), let semi = parts.firstIndex(of: ";"),
                parts.count > 2
            else { return nil }
            let images: [PdfImageRegion] = parts[(bar + 1)..<semi].compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                    let x1 = Float(f[2]), let y1 = Float(f[3])
                else { return nil }
                return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
            }
            guard let band = pdfLocalFlowBelowFullWidthImage(
                items(parts[(semi + 1)...]), images, xMin: Float(parts[1]) ?? 0,
                xMax: Float(parts[2]) ?? 612)
            else { return "lf -" }
            return "lf \(twoPlaces(band.splitX)),\(twoPlaces(band.yBottom)),"
                + "\(twoPlaces(band.yTop))"
        case "P2":
            guard let bar = parts.firstIndex(of: "|"), let semi = parts.firstIndex(of: ";"),
                parts.count > 3
            else { return nil }
            let images: [PdfImageRegion] = parts[(bar + 1)..<semi].compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                    let x1 = Float(f[2]), let y1 = Float(f[3])
                else { return nil }
                return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
            }
            guard let band = pdfPairedColumnImages(
                items(parts[(semi + 1)...]), images, splitX: Float(parts[1]) ?? 300,
                xMin: Float(parts[2]) ?? 0, xMax: Float(parts[3]) ?? 600)
            else { return "p2 -" }
            return "p2 \(twoPlaces(band.splitX)),\(twoPlaces(band.yBottom)),"
                + "\(twoPlaces(band.yTop))"
        case "I":
            guard let bar = parts.firstIndex(of: "|"), let semi = parts.firstIndex(of: ";"),
                parts.count > 1
            else { return nil }
            let images: [PdfImageRegion] = parts[(bar + 1)..<semi].compactMap {
                let f = $0.split(separator: ",")
                guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                    let x1 = Float(f[2]), let y1 = Float(f[3])
                else { return nil }
                return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
            }
            let pageItems = items(parts[(semi + 1)...])
            let split = parts[1] == "-" ? nil : Float(parts[1])
            guard let band = pdfInferImageAnchoredFlow(pageItems, images, detectedSplit: split)
            else { return "i -" }
            var out = "i \(twoPlaces(band.splitX)),\(twoPlaces(band.yBottom)),"
                + "\(twoPlaces(band.yTop))"
            for node in pdfBuildRegionGraph(pageItems, band: band) {
                out += " \(node.kind == .fullWidth ? "f" : "c"):\(node.items.count)"
                    + "@\(onePlace(node.items.first?.x ?? 0))"
            }
            return out
        case "GL":
            guard let bar = parts.firstIndex(of: "|"), let semi = parts.firstIndex(of: ";"),
                parts.count > 3
            else { return nil }
            func regions(_ fields: ArraySlice<String>) -> [PdfImageRegion] {
                fields.compactMap {
                    let f = $0.split(separator: ",")
                    guard f.count >= 4, let x0 = Float(f[0]), let y0 = Float(f[1]),
                        let x1 = Float(f[2]), let y1 = Float(f[3])
                    else { return nil }
                    return PdfImageRegion(x0: x0, y0: y0, x1: x1, y1: y1)
                }
            }
            let regionFields = parts[(bar + 1)..<semi]
            var charts: [PdfImageRegion] = []
            var images: [PdfImageRegion] = []
            if let slash = regionFields.firstIndex(of: "/") {
                charts = regions(regionFields[regionFields.startIndex..<slash])
                images = regions(regionFields[(slash + 1)...])
            } else {
                charts = regions(regionFields)
            }
            let grouped = pdfGroupPageIntoLines(
                items(parts[(semi + 1)...]), adaptiveThreshold: Float(parts[1]) ?? 0.10,
                hasTable: parts[2] == "1", chartRegions: charts, imageRegions: images,
                filterPageNumbers: parts[3] == "1")
            var out = "gl \(grouped.count)"
            for line in grouped {
                out += " \(line.items.count)@\(onePlace(line.y))"
                for item in line.items { out += ",\(onePlace(item.x))" }
            }
            return out
        case "A":
            guard let semi = parts.firstIndex(of: ";"), parts.count > 2 else { return nil }
            let rows = pdfGroupRows(items(parts[(semi + 1)...]))
            guard let first = rows.first,
                let split = pdfAlignedRowSplit(
                    first, xMin: Float(parts[1]) ?? 0, xMax: Float(parts[2]) ?? 612)
            else { return "a -" }
            return "a \(twoPlaces(split))"
        default:
            return nil
        }
    }

    /// `x,y,width,text` tuples, tildes standing in for spaces.
    private func items(_ fields: ArraySlice<String>) -> [PdfLayoutItem] {
        fields.compactMap { field in
            let f = field.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 4, let x = Float(f[0]), let y = Float(f[1]), let width = Float(f[2])
            else { return nil }
            return PdfLayoutItem(
                text: f[3].replacingOccurrences(of: "~", with: " "), x: x, y: y, width: width,
                fontSize: 12, fontName: "F1")
        }
    }

    private func twoPlaces(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let scaled = (Double(value) * 100).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    private func onePlace(_ value: Float) -> String {
        let scaled = (Double(value) * 10).rounded(.toNearestOrAwayFromZero)
        let whole = Int(scaled / 10)
        let fraction = abs(Int(scaled) % 10)
        let sign = (scaled < 0 && whole == 0) ? "-" : ""
        return "\(sign)\(whole).\(fraction)"
    }
}
