import Testing

@testable import AnyDoc

/// The control-byte rule at the bottom of the decode ladder.
///
/// When no `/ToUnicode`, no `/Differences` and no embedded `cmap` can read a
/// font's bytes, each byte is read on its own — **and a byte below `0x20` is
/// dropped rather than rendered**.
///
/// The rule matters far past the character it removes. An undecodable CID
/// font's codes are not characters at all, and rendering them writes literal
/// NULs and control codes into the Markdown: invisible to a reader, and text
/// to every downstream check. That is this project's named worst failure
/// mode — confident nonsense — and this is where it is stopped.
///
/// Measured against the reference byte by byte in wave 120: `<0001>` yields
/// nothing, `<00410042>` yields `AB`, and it is **not** specific to CID
/// fonts — a simple font drawing `41 00 42 02` gives `AB` there too, which
/// is why `decode-control-bytes.pdf` exists beside `detector-mixed-fonts.pdf`
/// in the corpus.
@Suite struct PdfDecodeControlBytesTests {
    /// The last resort, as the pipeline applies it.
    private func lastResort(_ bytes: [UInt8], useCp1252: Bool = true) -> String {
        var out = String.UnicodeScalarView()
        for byte in bytes where byte >= 0x20 {
            out.append(pdfDecodeSingleByte(byte, useCp1252: useCp1252))
        }
        return String(out)
    }

    @Test func aRunOfOnlyControlBytesDecodesToNothing() {
        #expect(lastResort([0x00, 0x01]).isEmpty)
        #expect(lastResort([0x00]).isEmpty)
        #expect(lastResort([0x1F]).isEmpty)
    }

    @Test func printableBytesSurviveAndControlsAreRemoved() {
        #expect(lastResort([0x41, 0x00, 0x42, 0x02]) == "AB")
        #expect(lastResort([0x00, 0x41, 0x00, 0x42]) == "AB")
    }

    /// `0x20` itself is kept: the boundary is "below 0x20", and a space is
    /// text. Getting this off by one would silently join every word.
    @Test func spaceIsNotAControlByte() {
        #expect(lastResort([0x41, 0x20, 0x42]) == "A B")
    }

    /// The bytes that survive still go through the Windows-1252 or Latin-1
    /// table rather than becoming their own code points — the C1 range is
    /// the only place the two differ, and it is where smart punctuation
    /// lives.
    @Test func survivingBytesUseTheCodepageNotTheirOwnValue() {
        // 0x92 is a right single quote in Windows-1252 and a C1 control in
        // Latin-1, which is the whole reason the choice is made per font.
        #expect(lastResort([0x92], useCp1252: true) == "\u{2019}")
        #expect(lastResort([0x92], useCp1252: false) == "\u{0092}")
    }

    /// A CID font never takes the Windows-1252 reading — its codes are not
    /// bytes — while an unnamed simple font does.
    @Test func theCodepageChoiceFollowsTheFont() {
        #expect(pdfShouldUseCp1252(baseFontName: "Helvetica", isType0CidFont: false))
        #expect(!pdfShouldUseCp1252(baseFontName: "Helvetica", isType0CidFont: true))
        #expect(pdfShouldUseCp1252(baseFontName: nil, isType0CidFont: false))
        // A subset tag is stripped at the *last* `+`, and symbol fonts opt out.
        #expect(!pdfShouldUseCp1252(baseFontName: "ABCDEF+SymbolMT", isType0CidFont: false))
    }
}
