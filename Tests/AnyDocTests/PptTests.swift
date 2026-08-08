// Ported from src/formats/ppt/styletext.rs's layout rules, plus the record
// walk's bounds. The end-to-end paths are covered by the fixture corpus.
import Testing

@testable import AnyDoc

/// Build a TextPFException/TextCFException pair the way a
/// `TxMasterStyleAtom` level stores them.
private func masterLevelBytes(pfMask: UInt32, pfExtra: [UInt8], cfMask: UInt32, cfExtra: [UInt8])
    -> [UInt8]
{
    le32(pfMask) + pfExtra + le32(cfMask) + cfExtra
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

@Suite struct PptStyleTextTests {
    /// The bullet flag is only *specified* when its own mask bit is set,
    /// even though three other mask bits also make the field present.
    @Test func bulletFlagIsTriState() {
        // hasBullet set: the value is meaningful.
        var body = le32(1) + le16(0) + le32(0x0001) + le16(0x0001)
        var runs = parseStyleText(body[...], textLen: 0)
        #expect(runs.paragraphs.first?.bullet == true)

        body = le32(1) + le16(0) + le32(0x0001) + le16(0x0000)
        runs = parseStyleText(body[...], textLen: 0)
        #expect(runs.paragraphs.first?.bullet == false)

        // Only bulletHasFont set: the field is present but says nothing
        // about whether there is a bullet.
        body = le32(1) + le16(0) + le32(0x0002) + le16(0x0001)
        runs = parseStyleText(body[...], textLen: 0)
        #expect(runs.paragraphs.first?.bullet == nil)

        // No bullet bits at all: no field, no value.
        body = le32(1) + le16(0) + le32(0x0000)
        runs = parseStyleText(body[...], textLen: 0)
        #expect(runs.paragraphs.first?.bullet == nil)
    }

    /// Character style bits are per-bit tri-state: bold and italic are each
    /// specified only when their own mask bit is set.
    @Test func characterStyleBitsAreIndependentlyTriState() {
        func charRun(mask: UInt32, style: UInt16) -> PptCharProps? {
            // One paragraph run with a zero count terminates the paragraph
            // list, then the character run follows.
            let body = le32(0) + le16(0) + le32(0) + le32(4) + le32(mask) + le16(style)
            return parseStyleText(body[...], textLen: 4).chars.first
        }
        // Both bits masked and set.
        #expect(charRun(mask: 0x0003, style: 0x0003)?.bold == true)
        #expect(charRun(mask: 0x0003, style: 0x0003)?.italic == true)
        // Both masked, neither set: explicitly off, not inherited.
        #expect(charRun(mask: 0x0003, style: 0x0000)?.bold == false)
        #expect(charRun(mask: 0x0003, style: 0x0000)?.italic == false)
        // Only bold masked: italic inherits even though its bit is set.
        #expect(charRun(mask: 0x0001, style: 0x0003)?.bold == true)
        #expect(charRun(mask: 0x0001, style: 0x0003)?.italic == nil)
    }

    /// A truncated exception aborts styling rather than the text: the runs
    /// parsed so far are kept.
    @Test func truncatedExceptionsKeepEarlierRuns() {
        // One complete paragraph run, then a mask claiming fields that run
        // past the end of the atom.
        let body = le32(5) + le16(0) + le32(0) + le32(5) + le16(1) + le32(0xFFFF_FFFF)
        let runs = parseStyleText(body[...], textLen: 10)
        #expect(runs.paragraphs.count == 1)
        #expect(runs.paragraphs.first?.count == 5)
    }

    /// A run claiming zero characters terminates its list — otherwise a
    /// crafted atom would loop.
    @Test func zeroCountRunsTerminate() {
        let body = le32(0) + le16(0) + le32(0) + le32(0) + le32(0)
        let runs = parseStyleText(body[...], textLen: 1000)
        #expect(runs.paragraphs.count == 1)
        #expect(runs.chars.count == 1)
    }

    /// Every optional TextPFException field shifts the ones after it, so the
    /// walker's arithmetic has to agree field for field.
    @Test func fullyMaskedParagraphExceptionConsumesEveryField() {
        // Every field the walker knows, in the order it consumes them:
        // bulletFlags, bulletChar, bulletFontRef, bulletSize, bulletColor,
        // textAlignment, lineSpacing, spaceBefore, spaceAfter, leftMargin,
        // indent, defaultTabSize.
        let mask: UInt32 = 0x0000_FDF1
        var extra = le16(0x0001)  // bulletFlags
        extra += le16(0) + le16(0) + le16(0)  // bulletChar, bulletFontRef, bulletSize
        extra += le32(0)  // bulletColor
        // textAlignment, lineSpacing, spaceBefore, spaceAfter, leftMargin,
        // indent, defaultTabSize.
        extra += le16(0) + le16(0) + le16(0) + le16(0) + le16(0) + le16(0) + le16(0)
        // A character run follows; it is only reached if the paragraph
        // exception consumed exactly the right number of bytes. Paragraph
        // runs cover textLen + 1, the implicit final paragraph mark, which
        // is what ends the paragraph loop.
        let body = le32(5) + le16(0) + le32(mask) + extra + le32(4) + le32(0x0001) + le16(0x0001)
        let runs = parseStyleText(body[...], textLen: 4)
        #expect(runs.paragraphs.first?.bullet == true)
        #expect(runs.chars.first?.bold == true)
    }

    /// Tab stops are a count-prefixed array, so the skip is data-dependent.
    @Test func tabStopArraysAreSkippedByLength() {
        let mask: UInt32 = 0x0010_0000
        let extra = le16(2) + [UInt8](repeating: 0, count: 8)
        let body = le32(5) + le16(0) + le32(mask) + extra + le32(4) + le32(0x0001) + le16(0x0001)
        let runs = parseStyleText(body[...], textLen: 4)
        #expect(runs.chars.first?.bold == true)
    }

    /// A `TxMasterStyleAtom` for a body-family text type (instance >= 5)
    /// carries a leading depth field on every level.
    @Test func masterStyleLevelsHonorTheInstanceLayout() {
        let level = masterLevelBytes(
            pfMask: 0x0001, pfExtra: le16(0x0001), cfMask: 0x0001, cfExtra: le16(0x0001))
        // Instance 1: no leading depth field.
        var body = le16(1) + level
        var levels = parseMasterStyle(body[...], instance: 1)
        #expect(levels.count == 1)
        #expect(levels.first?.bullet == true)
        #expect(levels.first?.bold == true)

        // Instance 5: each level is preceded by a depth field.
        body = le16(1) + le16(0) + level
        levels = parseMasterStyle(body[...], instance: 5)
        #expect(levels.count == 1)
        #expect(levels.first?.bullet == true)
        #expect(levels.first?.bold == true)
    }

    /// The level count is capped: a crafted atom cannot force unbounded work.
    @Test func masterStyleLevelCountIsCapped() {
        let level = masterLevelBytes(pfMask: 0, pfExtra: [], cfMask: 0, cfExtra: [])
        var body = le16(9999)
        for _ in 0..<20 { body += level }
        #expect(parseMasterStyle(body[...], instance: 1).count <= 10)
    }

    @Test func emptyBodiesYieldNothing() {
        #expect(parseMasterStyle([][...], instance: 1).isEmpty)
        #expect(parseStyleText([][...], textLen: 0).paragraphs.isEmpty)
    }
}

@Suite struct PptRecordTests {
    /// Record nesting past the cap is an attack shape, not a document.
    @Test func runawayNestingHitsTheDepthLimit() {
        // A container whose body is another container, all the way down.
        var body: [UInt8] = []
        for _ in 0..<(Limits.maxRecordDepth + 4) {
            var record: [UInt8] = [0x0F, 0x00, 0xE8, 0x03]
            record += le32(UInt32(body.count))
            record += body
            body = record
        }
        var extractor = PptExtractor()
        #expect(throws: ConvertError.self) { try extractor.walk(body[...]) }
    }

    /// A record whose declared length runs past its buffer ends the walk
    /// rather than reading beyond it.
    @Test func overlongRecordsEndTheWalk() throws {
        let body: [UInt8] = [0x0F, 0x00, 0xE8, 0x03] + le32(0xFFFF_FFFF)
        var extractor = PptExtractor()
        try extractor.walk(body[...])
        #expect(extractor.intoBlocks().isEmpty)
    }
}
