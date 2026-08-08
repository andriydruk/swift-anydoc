// Ported from src/formats/doc/{mod,lists,stsh}.rs tests: the numbering
// sequence rules, the Prm0 table, and the TDefTable layout. The end-to-end
// paths are covered by the fixture corpus.
import Testing

@testable import AnyDoc

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

/// A list whose level 0 is decimal and level 1 lower-alpha.
private func testList(_ lsid: UInt32) -> DocListDef {
    var levels = [DocLevelDef](repeating: DocLevelDef(), count: docListLevels)
    levels[0].marker = .decimal
    levels[1].marker = .lowerAlpha
    return DocListDef(
        lsid: lsid, levels: levels,
        startOverride: Array(repeating: nil, count: docListLevels))
}

@Suite struct DocCounterTests {
    /// Numbering state is keyed by list identity, so two LFOs over one list
    /// continue a single sequence.
    @Test func sharedLsidContinuesAcrossIlfos() {
        var counters = DocCounters()
        let list = testList(7)
        #expect(counters.next(1, list, 0).number == 1)
        #expect(counters.next(2, list, 0).number == 2)
    }

    /// An LFO start-at override restarts the shared sequence, but only the
    /// first time that LFO numbers the level.
    @Test func firstUseOverrideRestartsTheSharedSequence() {
        var counters = DocCounters()
        let list = testList(7)
        var over = testList(7)
        over.startOverride[0] = 10
        #expect(counters.next(1, list, 0).number == 1)
        #expect(counters.next(1, list, 0).number == 2)
        #expect(counters.next(2, over, 0).number == 10)
        #expect(counters.next(2, over, 0).number == 11)
        // Same lsid: the sequence is shared, so this continues from 11.
        #expect(counters.next(1, list, 0).number == 12)
    }

    /// `fNoRestart` with limit 0 means the level never restarts.
    @Test func noRestartLevelSurvivesShallowerItems() {
        var counters = DocCounters()
        var list = testList(7)
        list.levels[1].restart = 0
        #expect(counters.next(1, list, 0).number == 1)
        #expect(counters.next(1, list, 1).number == 1)
        #expect(counters.next(1, list, 0).number == 2)
        #expect(counters.next(1, list, 1).number == 2)
        // The default rule (no fNoRestart) does restart.
        let restarting = testList(8)
        #expect(counters.next(3, restarting, 0).number == 1)
        #expect(counters.next(3, restarting, 1).number == 1)
        #expect(counters.next(3, restarting, 0).number == 2)
        #expect(counters.next(3, restarting, 1).number == 1)
    }

    /// `ilvlRestartLim` names which levels trigger a restart.
    @Test func restartLimitDistinguishesTriggerLevels() {
        var counters = DocCounters()
        var list = testList(7)
        list.levels[2].marker = .decimal
        list.levels[2].restart = 2  // restart only after levels 0 or 1
        #expect(counters.next(1, list, 2).number == 1)
        _ = counters.next(1, list, 1)  // level 1 < 2: triggers a restart
        #expect(counters.next(1, list, 2).number == 1)
        #expect(counters.next(1, list, 2).number == 2)
    }

    /// A composite number text renders the parent levels' live values.
    @Test func compositeLabelRendersParentNumbers() {
        var counters = DocCounters()
        var list = testList(7)
        list.levels[1].pattern.text = [
            .level(0), .literal("-"), .level(1), .literal(")"),
        ]
        _ = counters.next(1, list, 0)
        let advanced = counters.next(1, list, 1)
        #expect(advanced.number == 1)
        #expect(advanced.label == "1-a)")
    }

    /// Number text that matches the renderer's own default produces no
    /// explicit label.
    @Test func defaultNumberTextProducesNoLabel() {
        var counters = DocCounters()
        var list = testList(7)
        list.levels[0].pattern.text = [.level(0), .literal(".")]
        let advanced = counters.next(1, list, 0)
        #expect(advanced.number == 1)
        #expect(advanced.label == nil)
    }
}

@Suite struct DocSprmTests {
    /// `Prm0` packs one (isprm, value) pair; only the sprms the converter
    /// models decode to a grpprl.
    @Test func prm0DecodesModeledSprms() {
        // isprm 0x55 = sprmCFBold (0x0835), val 0x01.
        #expect(prm0Grpprl((0x55 << 1) | (0x01 << 8)) == [0x35, 0x08, 0x01])
        // isprm 0x18 = sprmPFInTable (0x2416).
        #expect(prm0Grpprl((0x18 << 1) | (0x01 << 8)) == [0x16, 0x24, 0x01])
        // isprm 0x05 (sprmPJc) is outside the converted model.
        #expect(prm0Grpprl(0x05 << 1) == nil)
    }

    /// A `sprmTDefTable` operand carries the row's boundaries and its per-cell
    /// merge flags.
    @Test func tdefTableParsesBoundariesAndMergeFlags() {
        var operand: [UInt8] = le16(0)  // cb, unused here
        operand += [2]  // columns
        for boundary in [Int16(0), 4000, 8000] {
            operand += le16(UInt16(bitPattern: boundary))
        }
        // TC80: tcgrf + wWidth + 4 borders.
        func tc80(_ tcgrf: UInt16) -> [UInt8] { le16(tcgrf) + [UInt8](repeating: 0, count: 18) }
        operand += tc80(0x3 << 5)  // vertMerge = restart
        operand += tc80(0x1 << 5)  // vertMerge = continuation

        var grpprl: [UInt8] = [0x08, 0xD6]  // sprmTDefTable
        grpprl += le16(UInt16(operand.count - 1))
        grpprl += operand[2...]
        var delta = PapDelta()
        applyPapSprms(grpprl[...], [], &delta)
        let tap = try! #require(delta.tap)
        #expect(tap.boundaries == [0, 4000, 8000])
        #expect(tap.cells[0].vertRestart && !tap.cells[0].vertCont)
        #expect(tap.cells[1].vertCont && !tap.cells[1].vertRestart)
    }

    /// Character toggles resolve against the style chain: 0x80 keeps the
    /// style's value, 0x81 inverts it.
    @Test func characterTogglesResolveAgainstTheStyleBase() {
        let boldBase = Style(bold: true, italic: false, strike: false, code: false)
        func bold(_ operand: UInt8, base: Style) -> Bool {
            applyChpx(([0x35, 0x08, operand])[...], Style.plain, base).bold
        }
        #expect(bold(0x00, base: boldBase) == false)
        #expect(bold(0x01, base: boldBase) == true)
        #expect(bold(0x80, base: boldBase) == true)  // the style's value
        #expect(bold(0x81, base: boldBase) == false)  // inverted
        #expect(bold(0x80, base: .plain) == false)
        #expect(bold(0x81, base: .plain) == true)
    }

    /// Operand widths come from the sprm's own class bits, so a walk must
    /// stay aligned across a run of them.
    @Test func sprmWalkHonorsOperandWidths() {
        // sprmCFBold (1 byte), sprmPIlfo (2 bytes), sprmPItap (4 bytes).
        var grpprl: [UInt8] = [0x35, 0x08, 0x01]
        grpprl += [0x0B, 0x46] + le16(9)
        grpprl += [0x49, 0x66] + le32(3)
        var seen: [UInt16] = []
        walkSprms(grpprl[...]) { sprm, _ in seen.append(sprm) }
        #expect(seen == [0x0835, 0x460B, 0x6649])

        var delta = PapDelta()
        applyPapSprms(grpprl[...], [], &delta)
        #expect(delta.ilfo == 9)
        #expect(delta.itap == 3)
    }

    /// A truncated operand ends the walk rather than reading past it.
    @Test func truncatedOperandsEndTheWalk() {
        // sprmPItap claims four operand bytes but only two are present.
        var seen = 0
        walkSprms(([0x49, 0x66, 0x01, 0x00])[...]) { _, _ in seen += 1 }
        #expect(seen == 0)
    }

    /// `sprmPOutLvl` is doubly optional: it can say "no outline level".
    @Test func outlineLevelIsExplicitlyClearable() {
        var delta = PapDelta()
        applyPapSprms(([0x40, 0x26, 0x02])[...], [], &delta)
        #expect(delta.outline.flatMap { $0 } == 3)
        var cleared = PapDelta()
        applyPapSprms(([0x40, 0x26, 0x09])[...], [], &cleared)
        #expect(cleared.outline != nil)  // the sprm was seen
        #expect(cleared.outline.flatMap { $0 } == nil)  // and said "none"
    }
}

@Suite struct DocEncodingTests {
    /// The FIB's language id selects the ANSI code page compressed pieces
    /// decode in.
    @Test func languageIdsSelectCodepages() {
        #expect(lidEncoding(0x0419).encoding == .windows1251)  // Russian
        #expect(lidEncoding(0x0411).encoding == .shiftJis)  // Japanese
        #expect(lidEncoding(0x041F).encoding == .windows1254)  // Turkish
        #expect(lidEncoding(0x0408).encoding == .windows1253)  // Greek
        #expect(lidEncoding(0x040D).encoding == .windows1255)  // Hebrew
        #expect(lidEncoding(0x041E).encoding == .windows874)  // Thai
        #expect(lidEncoding(0x0409).encoding == .windows1252)  // English
    }

    /// Double-byte pages change how compressed-piece character positions are
    /// counted, so the lead-byte range is tracked even where the decoder is
    /// still substituted.
    @Test func doubleByteCodepagesAreMarked() {
        if case .shiftJis = lidEncoding(0x0411).leadBytes {} else {
            Issue.record("Japanese should use the shift_jis lead-byte range")
        }
        if case .wide = lidEncoding(0x0804).leadBytes {} else {
            Issue.record("Simplified Chinese should use the wide lead-byte range")
        }
        if case .none = lidEncoding(0x0409).leadBytes {} else {
            Issue.record("English is single-byte")
        }
    }
}
