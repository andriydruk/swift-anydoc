import Testing

@testable import AnyDoc

/// What the descriptor, the embedded program and the CMap key are each for.
///
/// The probe pins these against the reference; these say what the answers
/// *mean*, and cover the boundaries the corpus reaches only once.
@Suite struct PdfFontFileStyleTests {

    // MARK: - the CFF Name INDEX

    /// A minimal bare-CFF program whose Name INDEX carries one name.
    private func cff(_ name: String, headerSize: UInt8 = 4, offsetSize: UInt8 = 1) -> [UInt8] {
        let bytes = Array(name.utf8)
        var data: [UInt8] = [1, 0, headerSize, offsetSize]
        data.append(contentsOf: [UInt8](repeating: 0, count: max(Int(headerSize) - 4, 0)))
        data.append(contentsOf: [0, 1, offsetSize])
        for value in [1, 1 + bytes.count] {
            for shift in stride(from: Int(offsetSize) - 1, through: 0, by: -1) {
                data.append(UInt8((value >> (shift * 8)) & 0xFF))
            }
        }
        data.append(contentsOf: bytes)
        return data
    }

    @Test func cffNameIndexYieldsTheFirstPostScriptName() {
        #expect(pdfCffFontName(cff("Amplitude-LightItalic")) == "Amplitude-LightItalic")
    }

    @Test func cffNameKeepsTheSubsetTag() {
        // The tag is the caller's problem, not this reader's — it hands back
        // the name exactly as the font stores it.
        #expect(pdfCffFontName(cff("XXXXXX+Amplitude-LightItalic"))
            == "XXXXXX+Amplitude-LightItalic")
    }

    @Test func cffNameFollowsTheDeclaredHeaderSize() {
        // The Name INDEX begins at hdrSize, not at a fixed offset, so a
        // producer that pads the header must still be read correctly.
        #expect(pdfCffFontName(cff("Cardo-Italic", headerSize: 16)) == "Cardo-Italic")
    }

    @Test func cffNameReadsMultiByteOffsets() {
        let long = String(repeating: "L", count: 400)
        #expect(pdfCffFontName(cff(long, offsetSize: 2)) == long)
        #expect(pdfCffFontName(cff(long, offsetSize: 3)) == long)
    }

    @Test func cffNameRejectsAnythingButMajorVersionOne() {
        var data = cff("Vera-Bold")
        data[0] = 2
        #expect(pdfCffFontName(data) == nil)
    }

    @Test func cffNameRejectsSfntAndOpenTypeContainers() {
        // These are what the deferred TrueType branch would read. Refusing
        // them is what keeps the deferral from producing a *wrong* answer
        // rather than merely a missing one.
        #expect(pdfCffFontName([0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 40)) == nil)
        #expect(pdfCffFontName(Array("OTTO".utf8) + [UInt8](repeating: 0, count: 40)) == nil)
    }

    @Test func cffNameRejectsAnEmptyIndex() {
        var data = cff("Roman")
        data[4] = 0
        data[5] = 0
        #expect(pdfCffFontName(data) == nil)
    }

    @Test func cffNameRejectsAnIllegalOffsetSize() {
        for size in [UInt8(0), 5, 255] {
            var data = cff("Roman")
            data[6] = size
            #expect(pdfCffFontName(data) == nil, "offset size \(size) should be rejected")
        }
    }

    @Test func cffNameRejectsAZeroFirstOffset() {
        // Offsets are 1-based from the byte before the object data, so zero
        // is not a valid start rather than merely an empty name.
        var data = cff("Roman")
        data[7] = 0
        #expect(pdfCffFontName(data) == nil)
    }

    @Test func cffNameRejectsAnInvertedRange() {
        var data = cff("Roman")
        data[8] = 1  // end == start would be empty; below start is inverted
        data[7] = 5
        #expect(pdfCffFontName(data) == nil)
    }

    @Test func cffNameSurvivesEveryTruncation() {
        let full = cff("Charter-BoldItalic")
        for length in 0..<full.count {
            _ = pdfCffFontName(Array(full[0..<length]))
        }
        #expect(pdfCffFontName(full) == "Charter-BoldItalic")
    }

    @Test func cffNameIsLossyRatherThanRejectingOnBadUtf8() {
        var data: [UInt8] = [1, 0, 4, 1, 0, 1, 1, 1, 4]
        data.append(contentsOf: [0xFF, 0xFE, 0x41])
        #expect(pdfCffFontName(data)?.contains("A") == true)
    }

    // MARK: - descriptor flags

    private func document(_ objects: [String]) throws -> PdfDocument {
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try PdfDocument(bytes: Array(out.utf8))
    }

    /// A document whose object 4 is the font dictionary, with the catalog
    /// and page tree ahead of it so the file parses.
    private func fontDocument(_ font: String, _ extra: [String] = []) throws -> (
        PdfDocument, PdfDictionary
    ) {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            font,
        ]
        objects.append(contentsOf: extra)
        var document = try self.document(objects)
        let dictionary = document.object(PdfObjectId(number: 4, generation: 0)).asDictionary
        return (document, dictionary ?? PdfDictionary())
    }

    private func flags(_ font: String, _ extra: [String] = []) throws -> PdfFontStyle {
        var (document, dictionary) = try fontDocument(font, extra)
        var cache = PdfFontStyleCache()
        return pdfDescriptorStyleFlags(&document, dictionary, cache: &cache)
    }

    @Test func fourDegreesOfSlantIsItalicAndTheBarIsInclusive() throws {
        // The reference tests `>= 4.0`, so exactly four degrees counts. An
        // earlier version of this port used `>`, which differed on precisely
        // this value.
        #expect(try flags("<< /FontDescriptor << /ItalicAngle 4 >> >>").italic)
        #expect(try flags("<< /FontDescriptor << /ItalicAngle -4 >> >>").italic)
        #expect(try !flags("<< /FontDescriptor << /ItalicAngle 3.9 >> >>").italic)
        #expect(try !flags("<< /FontDescriptor << /ItalicAngle 0 >> >>").italic)
    }

    @Test func flagsBitsSevenAndNineteenCarryItalicAndBold() throws {
        #expect(try flags("<< /FontDescriptor << /Flags 64 >> >>").italic)
        #expect(try flags("<< /FontDescriptor << /Flags 262144 >> >>").bold)
        let both = try flags("<< /FontDescriptor << /Flags 262208 >> >>")
        #expect(both.italic && both.bold)
        // Neighbouring bits mean other things and must not leak in.
        #expect(try flags("<< /FontDescriptor << /Flags 4294967295 >> >>").bold)
        #expect(try flags("<< /FontDescriptor << /Flags 63 >> >>") == PdfFontStyle())
    }

    @Test func flagsMustBeAnIntegerAndAreNotResolved() throws {
        // `as_i64` accepts only `Object::Integer`, and the value is read
        // without following a reference — so both of these read as absent.
        #expect(try flags("<< /FontDescriptor << /Flags 64.0 >> >>") == PdfFontStyle())
        #expect(
            try flags("<< /FontDescriptor << /Flags 5 0 R >> >>", ["64"]) == PdfFontStyle())
    }

    @Test func italicAngleIsNotResolvedEither() throws {
        #expect(
            try !flags("<< /FontDescriptor << /ItalicAngle 5 0 R >> >>", ["30"]).italic)
    }

    @Test func aFontWithNoDescriptorHasNoFlags() throws {
        #expect(try flags("<< /Type /Font /BaseFont /Helvetica-Bold >>") == PdfFontStyle())
    }

    @Test func aDescriptorThatIsNotADictionaryIsIgnored() throws {
        #expect(try flags("<< /FontDescriptor 42 >>") == PdfFontStyle())
    }

    @Test func aType0FontFallsBackToItsDescendantsDescriptor() throws {
        let style = try flags(
            "<< /Subtype /Type0 /DescendantFonts [5 0 R] >>",
            ["<< /FontDescriptor << /ItalicAngle 15 >> >>"])
        #expect(style.italic)
    }

    @Test func aType0FontWithItsOwnDescriptorKeepsIt() throws {
        // The reference's `or_else` runs only when the font dictionary has
        // no descriptor of its own, so the descendant's italic angle is not
        // consulted here even though it is the more specific one.
        let style = try flags(
            "<< /Subtype /Type0 /FontDescriptor << /ItalicAngle 0 >> /DescendantFonts [5 0 R] >>",
            ["<< /FontDescriptor << /ItalicAngle 15 >> >>"])
        #expect(!style.italic)
    }

    // MARK: - the embedded program

    private func cffStream(_ name: String) -> String {
        let data = cff(name)
        let text = String(decoding: data, as: UTF8.self)
        return "<< /Length \(data.count) >>\nstream\n\(text)\nendstream"
    }

    @Test func theEmbeddedProgramRescuesADescriptorThatClaimsUpright() throws {
        // The descriptor says nothing; the CFF Name INDEX says italic. This
        // is the case the whole embedded branch exists for.
        let style = try flags(
            "<< /FontDescriptor << /FontFile3 5 0 R >> >>",
            [cffStream("ABCDEF+Amplitude-LightItalic")])
        #expect(style.italic)
        #expect(!style.bold)
    }

    @Test func theEmbeddedProgramCanOnlyAddFlags() throws {
        // An upright program does not take away an italic the descriptor
        // already declared.
        let style = try flags(
            "<< /FontDescriptor << /ItalicAngle 20 /FontFile3 5 0 R >> >>",
            [cffStream("ABCDEF+Plain")])
        #expect(style.italic)
    }

    @Test func aFontFileReferenceThatResolvesToNothingIsHarmless() throws {
        #expect(try flags("<< /FontDescriptor << /FontFile3 99 0 R >> >>") == PdfFontStyle())
    }

    @Test func fontFileTwoWinsOverFontFileThree() throws {
        var descriptor = PdfDictionary()
        descriptor["FontFile2"] = .reference(PdfObjectId(number: 7, generation: 0))
        descriptor["FontFile3"] = .reference(PdfObjectId(number: 9, generation: 0))
        #expect(pdfFontFileReference(descriptor)?.number == 7)
        descriptor["FontFile2"] = nil
        #expect(pdfFontFileReference(descriptor)?.number == 9)
    }

    @Test func aDirectlyEmbeddedFontFileHasNoObjectNumber() throws {
        // The callers want a key, and an inline stream has none.
        var descriptor = PdfDictionary()
        descriptor["FontFile2"] = .integer(3)
        #expect(pdfFontFileReference(descriptor) == nil)
    }

    // MARK: - the CMap lookup key

    private func key(_ font: String, _ extra: [String] = []) throws -> UInt32? {
        var (document, dictionary) = try fontDocument(font, extra)
        return pdfFontFileObjectNumber(&document, dictionary)
    }

    @Test func aSimpleFontsKeyIsItsEmbeddedProgram() throws {
        #expect(try key("<< /FontDescriptor << /FontFile2 9 0 R >> >>") == 9)
        #expect(try key("<< /FontDescriptor << >> >>") == nil)
        #expect(try key("<< /Subtype /TrueType >>") == nil)
    }

    @Test func onlyTheIdentityEncodingsGetACompositeKey() throws {
        let descendant = "<< /FontDescriptor << /FontFile2 9 0 R >> >>"
        #expect(
            try key("<< /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
                [descendant]) == 9)
        #expect(
            try key("<< /Subtype /Type0 /Encoding /Identity-V /DescendantFonts [5 0 R] >>",
                [descendant]) == 9)
        // Any other CMap needs a different route entirely, so there is no
        // key rather than a wrong one.
        #expect(
            try key("<< /Subtype /Type0 /Encoding /WinAnsiEncoding /DescendantFonts [5 0 R] >>",
                [descendant]) == nil)
        #expect(
            try key("<< /Subtype /Type0 /DescendantFonts [5 0 R] >>", [descendant]) == nil)
    }

    @Test func aCompositeFontWithNoProgramFallsBackToItsDescendant() throws {
        #expect(
            try key("<< /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
                ["<< /FontDescriptor << >> >>"]) == 5)
    }

    @Test func theDescendantFallbackNeedsADescriptorFirst() throws {
        // The fallback sits *after* the descriptor has been required, so a
        // descendant carrying none yields nothing at all — not its own
        // object number. Easy to miss and easy to get wrong.
        #expect(
            try key("<< /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
                ["<< /Subtype /CIDFontType2 >>"]) == nil)
    }

    @Test func singleLevelResolutionDoesNotFollowChains() throws {
        // The reference's `resolve_dict` follows exactly one reference, so a
        // descriptor reached through two of them is not found.
        #expect(try flags("<< /FontDescriptor 5 0 R >>", ["6 0 R", "<< /Flags 64 >>"])
            == PdfFontStyle())
        #expect(try flags("<< /FontDescriptor 5 0 R >>", ["<< /Flags 64 >>"]).italic)
    }
}
