// Ported from src/shared/binary.rs tests, plus the OLE stream reader and
// CompObj (user type / ProgID) coverage over real fixtures.
import Testing
@testable import AnyDoc

@Suite struct BinaryTests {
    @Test func integerReadsRejectOverflowingOffsets() {
        #expect(getU16([1, 2, 3, 4], Int.max) == nil)
        #expect(getU32([1, 2, 3, 4], Int.max) == nil)
        #expect(getU16([1, 2, 3, 4], -1) == nil)
        #expect(getU16([1, 2], 0) == 0x0201)
        #expect(getU32([1, 2, 3, 4], 0) == 0x0403_0201)
    }

    @Test func oleStreamsReadWithMissingPartErrors() throws {
        let ole = try CompoundFile(bytes: try fixtureBytes("doc/text.doc"))
        let wordDoc = try readOleStream(ole, "WordDocument")
        #expect(wordDoc.count == 8239)
        do {
            _ = try readOleStream(ole, "NoSuchStream")
            Issue.record("expected a missing-part error")
        } catch let error as ConvertError {
            #expect(error.message == "missing required part: NoSuchStream")
        }
        do {
            _ = try readOleStream(ole, "ObjectPool")
            Issue.record("a storage is not a stream")
        } catch let error as ConvertError {
            #expect(error.code == "missingPart")
        }
    }

    @Test func compObjParsesRealFixtures() throws {
        // text.doc carries a full CompObj: user type, clipboard-format name,
        // and ProgID.
        let doc = oleObjectInfo(try fixtureBytes("doc/text.doc"))
        #expect(doc?.userType == "Microsoft Word-Dokument")
        #expect(doc?.progId == "Word.Document.8")
        // sheet.xls names a clipboard format ("Biff8") but a zero-length
        // ProgID, which must be ignored.
        let xls = oleObjectInfo(try fixtureBytes("xls/sheet.xls"))
        #expect(xls?.userType == "Microsoft Excel 97-Tabelle")
        #expect(xls?.progId == nil)
        // pres.ppt has no clipboard format and no ProgID.
        let ppt = oleObjectInfo(try fixtureBytes("ppt/pres.ppt"))
        #expect(ppt?.userType == "MS PowerPoint 97")
        #expect(ppt?.progId == nil)
    }

    @Test func extractedDocxOlePartIsNotACompoundFile() throws {
        // word/embeddings/oleObject1.bin from the handmade-ole.docx fixture:
        // a synthetic 64-byte payload, not a CFB container, so it carries no
        // CompObj. The golden's "Embedded object: Excel.Sheet.12" comes from
        // the o:OLEObject ProgID attribute in document.xml, which the docx
        // frontend reads.
        let bytes = try testResourceBytes("ole-object.bin")
        #expect(bytes.count == 64)
        #expect(Array(bytes.prefix(16)) == Array("DOCX-OLE-PAYLOAD".utf8))
        #expect(oleObjectInfo(bytes) == nil)
    }

    @Test func compObjYieldsTheExcelProgId() throws {
        // The same object as the docx fixture's, as a real OLE payload: a
        // compound file whose CompObj names ProgID Excel.Sheet.12.
        let ole = makeCfb([("\u{01}CompObj", compObjStream(progId: "Excel.Sheet.12"))])
        let info = oleObjectInfo(ole)
        #expect(info?.progId == "Excel.Sheet.12")
        #expect(info?.userType == "Microsoft Excel Worksheet")
    }

    @Test func compObjIgnoresInvalidProgIdLengths() throws {
        // MS-OLEDS: a ProgID length of zero or over 40 means the field and
        // everything after it are ignored.
        let long = String(repeating: "x", count: 41)
        let ole = makeCfb([("\u{01}CompObj", compObjStream(progId: long))])
        let info = oleObjectInfo(ole)
        #expect(info?.userType == "Microsoft Excel Worksheet")
        #expect(info?.progId == nil)
    }
}

/// A CompObj stream per MS-OLEDS 2.3.8: 28-byte header, ANSI user type,
/// standard clipboard format, ANSI ProgID.
private func compObjStream(progId: String) -> [UInt8] {
    var out: [UInt8] = [0x01, 0x00, 0xFE, 0xFF]  // Reserved1
    out.append(contentsOf: [0x03, 0x0A, 0x00, 0x00])  // Version
    out.append(contentsOf: [UInt8](repeating: 0, count: 20))  // Reserved2
    func ansi(_ s: String) {
        let bytes = Array(s.utf8) + [0]
        let len = UInt32(bytes.count)
        out.append(UInt8(len & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(contentsOf: bytes)
    }
    ansi("Microsoft Excel Worksheet")
    out.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // standard format marker
    out.append(contentsOf: [0x0E, 0x00, 0x00, 0x00])  // CF_ENHMETAFILE
    ansi(progId)
    return out
}
