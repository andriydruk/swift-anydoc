// Ported from src/formats/sheet/mod.rs and calamine's formats.rs tests, plus
// coverage for the Rust-compatible float formatting the whole spreadsheet
// path depends on (PLAN §2, gotcha 1).
import Testing
@testable import AnyDoc

@Suite struct NumberFormatTests {
    /// calamine's `test_is_date_format`, itself ported from openpyxl.
    @Test func customFormatCodesClassify() {
        let cases: [(String, CellFormat)] = [
            ("DD/MM/YY", .dateTime),
            ("H:MM:SS;@", .dateTime),
            ("#,##0\\ [$\\u20bd-46D]", .other),
            ("m\"M\"d\"D\";@", .dateTime),
            ("[h]:mm:ss", .timeDelta),
            ("\"Y: \"0.00\"m\";\"Y: \"-0.00\"m\";\"Y: <num>m\";@", .other),
            ("#,##0\\ [$''u20bd-46D]", .other),
            ("\"$\"#,##0_);[Red](\"$\"#,##0)", .other),
            ("[$-404]e\"\\xfc\"m\"\\xfc\"d\"\\xfc\"", .dateTime),
            ("0_ ;[Red]\\-0\\ ", .other),
            ("\\Y000000", .other),
            ("#,##0.0####\" YMD\"", .other),
            ("[h]", .timeDelta),
            ("[ss]", .timeDelta),
            ("[s].000", .timeDelta),
            ("[m]", .timeDelta),
            ("[mm]", .timeDelta),
            ("[Blue]\\+[h]:mm;[Red]\\-[h]:mm;[Green][h]:mm", .timeDelta),
            ("[>=100][Magenta][s].00", .timeDelta),
            ("[h]:mm;[=0]\\-", .timeDelta),
            ("[>=100][Magenta].00", .other),
            ("[>=100][Magenta]General", .other),
            ("ha/p\\\\m", .dateTime),
            ("#,##0.00\\ _M\"H\"_);[Red]#,##0.00\\ _M\"S\"_)", .other),
            // The `*` fill operator repeats the next character, so that
            // character is a literal even when it looks like a date token.
            ("#,##0*y", .other),
            ("0\"x\"*d", .other),
            ("*-#,##0", .other),
            ("*-yyyy-mm-dd", .dateTime),
        ]
        for (code, expected) in cases {
            #expect(
                detectCustomNumberFormat(code) == expected,
                "format code \(rustDebugString(code)) classified wrongly")
        }
    }

    @Test func reservedFormatIdsClassify() {
        for id in 14...22 {
            #expect(builtinFormatById(String(id)) == .dateTime)
        }
        #expect(builtinFormatById("45") == .dateTime)
        #expect(builtinFormatById("47") == .dateTime)
        #expect(builtinFormatById("46") == .timeDelta)
        for id in [0, 1, 13, 23, 44, 48, 49, 164] {
            #expect(builtinFormatById(String(id)) == .other)
        }
        // The id is matched as written, so a padded spelling is not id 14.
        #expect(builtinFormatById("014") == .other)
        #expect(builtinFormatById(" 14") == .other)
    }
}

@Suite struct SheetValueTests {
    @Test func stringCellsAreNotTrimmed() {
        #expect(formatSheetValue(.string("  padded  ")) == "  padded  ")
    }

    @Test func tinyFloatsSurvive() {
        #expect(formatSheetFloat(0.0000004) == "0.0000004")
        #expect(formatSheetFloat(12.0) == "12")
        #expect(formatSheetFloat(1.5) == "1.5")
    }

    @Test func floatsRenderAtSpreadsheetPrecision() {
        #expect(formatSheetFloat(3554.7000000000003) == "3554.7")
        #expect(formatSheetFloat(5649.5599999999995) == "5649.56")
        #expect(formatSheetFloat(346_289_529.491_800_1) == "346289529.4918")
        // Small values stay exact: 15 significant digits reaches far below 1.
        #expect(formatSheetFloat(0.0000004) == "0.0000004")
        #expect(formatSheetFloat(1.0) == "1")
    }

    /// Rust's `Display` writes every float positionally — no exponent, no
    /// trailing `.0` — which is where Swift's own formatting diverges.
    @Test func floatsNeverUseExponentNotation() {
        #expect(formatSheetFloat(1e21) == "1000000000000000000000")
        #expect(formatSheetFloat(1e-7) == "0.0000001")
        #expect(formatSheetFloat(1e-21) == "0.000000000000000000001")
        #expect(formatSheetFloat(0.0) == "0")
        #expect(formatSheetFloat(-0.0) == "-0")
        #expect(formatSheetFloat(-1.5) == "-1.5")
        #expect(formatSheetFloat(0.1) == "0.1")
        #expect(formatSheetFloat(0.1 + 0.2) == "0.3")
    }

    @Test func timeOfDaySerialsCarryNoDate() {
        // 09:04:54 as a fraction of a day, with the float noise a serial
        // carries in practice.
        #expect(formatTimeOfDay(32_694.184 / 86_400.0) == "09:04:54")
        #expect(formatTimeOfDay(0.0) == "00:00:00")
    }

    @Test func durationsRenderAsClockTime() {
        // 26h30m15s = 1.104340277... days
        let days = (26.0 * 3600.0 + 30.0 * 60.0 + 15.0) / 86_400.0
        #expect(formatDurationDays(days) == "26:30:15")
        #expect(formatDurationDays(-0.5) == "-12:00:00")
    }

    @Test func serialsRenderAsDates() {
        func dateTime(_ value: Double) -> String {
            formatSheetValue(.dateTime(ExcelDateTime(value: value, isDuration: false, is1904: false)))
        }
        #expect(dateTime(46096) == "2026-03-15")
        #expect(dateTime(45943.541) == "2025-10-13 12:59:02")
        // Excel's mythical 1900-02-29: serials below 60 shift by a day.
        #expect(dateTime(59) == "1900-02-28")
        #expect(dateTime(60) == "1900-02-28")
        #expect(dateTime(61) == "1900-03-01")
        // The 1904 epoch offsets the same serial by 1462 days.
        #expect(
            formatSheetValue(
                .dateTime(ExcelDateTime(value: 46096, isDuration: false, is1904: true)))
                == "2030-03-16")
    }

    @Test func extremeSerialsFallBackToTheNumber() {
        // Beyond the calendar's range there is no date to print, so the raw
        // serial stands in rather than a wrapped-around date.
        let huge = ExcelDateTime(value: 1e18, isDuration: false, is1904: false)
        #expect(formatSheetValue(.dateTime(huge)) == "1000000000000000000")
        let nan = ExcelDateTime(value: .nan, isDuration: false, is1904: false)
        #expect(formatSheetValue(.dateTime(nan)) == "NaN")
    }

    @Test func cellErrorsPrintTheirVariantName() {
        #expect(formatSheetValue(.error("Ref")) == "#Ref")
        #expect(formatSheetValue(.bool(true)) == "TRUE")
        #expect(formatSheetValue(.bool(false)) == "FALSE")
        #expect(formatSheetValue(.empty) == "")
    }
}

@Suite struct XlsxReferenceTests {
    @Test func cellReferencesParse() {
        #expect(parseCellReference("A1").map { [$0.row, $0.col] } == [0, 0])
        #expect(parseCellReference("D11").map { [$0.row, $0.col] } == [10, 3])
        #expect(parseCellReference("Z1").map { [$0.row, $0.col] } == [0, 25])
        #expect(parseCellReference("AA1").map { [$0.row, $0.col] } == [0, 26])
        #expect(parseCellReference("XFD1048576").map { [$0.row, $0.col] } == [1_048_575, 16_383])
        // Lowercase is accepted; a missing component or a stray character is not.
        #expect(parseCellReference("a1").map { [$0.row, $0.col] } == [0, 0])
        #expect(parseCellReference("A0") == nil)
        #expect(parseCellReference("1") == nil)
        #expect(parseCellReference("A") == nil)
        #expect(parseCellReference("$A$1") == nil)
        #expect(parseCellReference("A1B") == nil)
        // A row reference ignores any column component.
        #expect(parseRowReference("11") == 10)
        #expect(parseRowReference("D11") == 10)
        #expect(parseRowReference("0") == nil)
    }

    @Test func regionReferencesParse() {
        let region = parseRegionReference("B2:D5")
        #expect(region.map { [$0.startRow, $0.startCol, $0.endRow, $0.endCol] } == [1, 1, 4, 3])
        let single = parseRegionReference("C3")
        #expect(single.map { [$0.startRow, $0.startCol, $0.endRow, $0.endCol] } == [2, 2, 2, 2])
        // An inverted range has no positive extent to materialize.
        #expect(parseRegionReference("D5:B2") == nil)
        #expect(parseRegionReference("A1:B2:C3") == nil)
        #expect(parseRegionReference("notaref") == nil)
    }

    @Test func excelUnderscoreEscapesDecode() {
        #expect(decodeOoxmlEscapes("a_x000D_b") == "a\rb")
        #expect(decodeOoxmlEscapes("tab_x0009_here") == "tab\there")
        // Excel escapes the literal sequence by escaping its own underscore.
        #expect(decodeOoxmlEscapes("_x005F_x000D_") == "_x000D_")
        // Anything that is not a well-formed escape is content.
        #expect(decodeOoxmlEscapes("_x00ZZ_") == "_x00ZZ_")
        #expect(decodeOoxmlEscapes("_x00") == "_x00")
        #expect(decodeOoxmlEscapes("plain") == "plain")
    }
}

/// End-to-end merge behavior, over the same minimal workbook shape the
/// reference builds in its own tests: a used range at D11:E12.
@Suite struct XlsxMergeTests {
    private func xlsx(mergeRef: String) -> [UInt8] {
        let sheet = """
            <?xml version="1.0"?><worksheet \
            xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="11"><c r="D11" t="inlineStr"><is><t>x</t></is></c>\
            <c r="E11" t="inlineStr"><is><t>y</t></is></c></row>\
            <row r="12"><c r="D12" t="inlineStr"><is><t>z</t></is></c>\
            <c r="E12" t="inlineStr"><is><t>w</t></is></c></row></sheetData>\
            <mergeCells count="1"><mergeCell ref="\(mergeRef)"/></mergeCells></worksheet>
            """
        let contentTypes = """
            <?xml version="1.0"?><Types \
            xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-\
            officedocument.spreadsheetml.sheet.main+xml"/></Types>
            """
        let rootRels = """
            <?xml version="1.0"?><Relationships \
            xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006\
            /relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """
        let workbook = """
            <?xml version="1.0"?><workbook \
            xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
            """
        let workbookRels = """
            <?xml version="1.0"?><Relationships \
            xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006\
            /relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """
        return makeZip([
            ("[Content_Types].xml", Array(contentTypes.utf8)),
            ("_rels/.rels", Array(rootRels.utf8)),
            ("xl/workbook.xml", Array(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Array(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Array(sheet.utf8)),
        ])
    }

    private func coveredCount(_ doc: Document) throws -> Int {
        guard case .table(let table) = doc.blocks.first else {
            Issue.record("expected a table, got \(String(describing: doc.blocks.first))")
            return -1
        }
        return table.grid.flatMap { $0 }.filter { if case .covered = $0 { true } else { false } }
            .count
    }

    @Test func mergeInsideTheUsedRangeCoversCells() throws {
        // Harness sanity: an in-range merge must actually load and apply.
        #expect(try coveredCount(parseSheet(xlsx(mergeRef: "D11:E11"))) == 1)
    }

    @Test func mergeOutsideTheUsedColumnsIsIgnored() throws {
        // The merge overlaps the used rows but not the used columns; without
        // the intersection step it would saturate onto (0,0) and cover D12.
        #expect(
            try coveredCount(parseSheet(xlsx(mergeRef: "A1:B12"))) == 0,
            "out-of-range merge must not cover cells")
    }

    @Test func mergeSpanningTheWholeSheetIsClampedToIt() throws {
        // A region far past the used range only covers what exists: the whole
        // 2x2 range becomes one cell, so the second row is all-covered and is
        // dropped as trailing empty, leaving a single covered position beside
        // the origin. Verified against the reference on the same input.
        let doc = try parseSheet(xlsx(mergeRef: "D11:XFD1048576"))
        #expect(try coveredCount(doc) == 1)
        #expect(documentToMarkdown(doc) == "|  |  |\n| --- | --- |\n| x |  |\n")
    }
}
