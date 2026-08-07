// Ported from src/shared/blockstyle.rs tests.
import Testing
@testable import AnyDoc

@Suite struct BlockStyleTests {
    @Test func producerStyleNamesMapToContainers() {
        for name in ["Quote", "Intense Quote", "Block Text", "Quotations", "QUOTATIONS"] {
            #expect(blockStyleFromName(name) == .quote, "\(name)")
        }
        for name in ["HTML Preformatted", "Source Code", "Preformatted Text"] {
            #expect(blockStyleFromName(name) == .code, "\(name)")
        }
        // ODF internal names encode the spaces.
        #expect(blockStyleFromName("Preformatted_20_Text") == .code)
        for name in ["Normal", "Body Text", "heading 1", ""] {
            #expect(blockStyleFromName(name) == nil, "\(name)")
        }
    }

    @Test func consecutiveParagraphsFoldIntoOneContainer() throws {
        var out: [Block] = []
        var run = StyledRun()
        run.push(.code, [.plain("fn main() {")], &out)
        run.push(.code, [.plain("}")], &out)
        run.push(.quote, [.plain("first")], &out)
        run.push(.quote, [.plain("second")], &out)
        run.flush(&out)
        #expect(out.count == 2, "\(out)")
        guard case .codeBlock(_, let text) = out[0] else {
            Issue.record("expected code block: \(out)")
            return
        }
        #expect(text == "fn main() {\n}")
        guard case .blockQuote(let inner) = out[1] else {
            Issue.record("expected block quote: \(out)")
            return
        }
        #expect(inner.count == 2)
    }

    @Test func blankParagraphsAroundACodeRunAreDropped() throws {
        var out: [Block] = []
        var run = StyledRun()
        run.push(.code, [.plain("")], &out)
        run.push(.code, [.plain("a")], &out)
        run.push(.code, [.plain("")], &out)
        run.push(.code, [.plain("b")], &out)
        run.push(.code, [.plain("")], &out)
        run.flush(&out)
        guard out.count == 1, case .codeBlock(_, let text) = out[0] else {
            Issue.record("expected one code block: \(out)")
            return
        }
        #expect(text == "a\n\nb")
    }
}
