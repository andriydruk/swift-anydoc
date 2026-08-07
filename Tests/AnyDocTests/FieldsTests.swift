// Ported from src/shared/fields.rs tests.
import Testing
@testable import AnyDoc

@Suite struct FieldsTests {
    @Test func quotedUrl() {
        #expect(
            hyperlinkTarget(#" HYPERLINK "https://e.com/a b" "#)
                == .external("https://e.com/a b"))
    }

    @Test func caseInsensitiveKeyword() {
        #expect(
            hyperlinkTarget(#"hyperlink "https://e.com""#)
                == .external("https://e.com"))
    }

    @Test func anchorOnly() {
        #expect(
            hyperlinkTarget(#"HYPERLINK \l "sec2""#)
                == .anchor("sec2"))
    }

    @Test func urlPlusAnchor() {
        #expect(
            hyperlinkTarget(#"HYPERLINK "https://e.com/p" \l "frag""#)
                == .external("https://e.com/p#frag"))
    }

    @Test func switchWithArgumentNotMistakenForUrl() {
        #expect(
            hyperlinkTarget(#"HYPERLINK \o "tooltip text" "https://e.com""#)
                == .external("https://e.com"))
    }

    @Test func escapedQuotesInTarget() {
        #expect(
            hyperlinkTarget(#"HYPERLINK "https://e.com/\"q\"""#)
                == .external(#"https://e.com/"q""#))
    }

    @Test func relativeTarget() {
        #expect(
            hyperlinkTarget(#"HYPERLINK "docs/readme.docx""#)
                == .relative("docs/readme.docx"))
    }

    @Test func arglessSwitchDoesNotSwallowFollowingSwitch() {
        #expect(
            hyperlinkTarget(#"HYPERLINK "https://e.com/p" \o \l "frag""#)
                == .external("https://e.com/p#frag"))
    }

    @Test func nonHyperlinkFieldsIgnored() {
        #expect(hyperlinkTarget("PAGEREF _Toc123 \\h") == nil)
    }
}
