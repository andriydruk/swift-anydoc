// Ported from src/formats/csv.rs tests.
import Testing
@testable import AnyDoc

@Suite struct CsvTests {
    @Test func quotedFieldsKeepPadding() throws {
        let doc = try parseCsv(Array("a,b\n\"  padded  \",x\n".utf8))
        guard case .table(let t) = doc.blocks[0],
            case .origin(let cell) = t.grid[1][0],
            case .paragraph(let inlines) = cell.blocks[0],
            case .text(let text, _) = inlines[0]
        else {
            Issue.record("unexpected document shape")
            return
        }
        #expect(text == "  padded  ")
    }

    @Test func quotedDelimitersDoNotSkewSniffing() {
        #expect(sniffDelimiter(Array("a;b;c\n\"1,5\";\"2,5\";x\n\"3,0\";y;z\n".utf8)) == UInt8(ascii: ";"))
        #expect(sniffDelimiter(Array("a,b,c\n1,2,3\n".utf8)) == UInt8(ascii: ","))
        #expect(sniffDelimiter(Array("a\tb\n1\t2\n".utf8)) == 0x09)
    }

    @Test func multilineQuotedFieldDoesNotBreakSniffing() {
        // A quoted field spanning more physical lines than a 20-line sample
        // window; the record-based sample must still see semicolons.
        let longField = "\"" + Array(repeating: "line", count: 30).joined(separator: "\n") + "\""
        let text = "a;b;c\n\(longField);2;3\nx;y;z\n"
        #expect(sniffDelimiter(Array(text.utf8)) == UInt8(ascii: ";"))
    }

    @Test func utf16BomDecodes() throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for u in "x,y\ncafé,90\n".utf16 {
            bytes.append(UInt8(u & 0xFF))
            bytes.append(UInt8(u >> 8))
        }
        let doc = try parseCsv(bytes)
        #expect(!doc.blocks.isEmpty)
    }

    @Test func csvRecordSemantics() {
        // Empty lines yield no record; a trailing delimiter yields a trailing
        // empty field; quotes mid-field are literal; a closing quote followed
        // by ordinary bytes resumes the field (csv crate lenient mode).
        func records(_ s: String) -> [[String]] {
            var reader = CsvRecordReader(bytes: Array(s.utf8), delimiter: UInt8(ascii: ","))
            var out: [[String]] = []
            while let r = reader.next() { out.append(r) }
            return out
        }
        #expect(records("a,b\n\nc,d\n") == [["a", "b"], ["c", "d"]])
        #expect(records("a,\n") == [["a", ""]])
        #expect(records("a\"b,c\n") == [["a\"b", "c"]])
        #expect(records("\"a\"\"b\",c\n") == [["a\"b", "c"]])
        #expect(records("\"a\"x,c\n") == [["ax", "c"]])
        #expect(records("\"multi\nline\",x\n") == [["multi\nline", "x"]])
        #expect(records("\"unterminated\n") == [["unterminated\n"]])
        #expect(records("a,b\r\nc,d\r\n") == [["a", "b"], ["c", "d"]])
    }
}
