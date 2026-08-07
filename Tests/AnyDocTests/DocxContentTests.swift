// Ported from src/formats/docx/content.rs tests.
import Testing
@testable import AnyDoc

@Suite struct DocxContentTests {
    private func text(_ value: String) -> Piece {
        .inlines([.plain(value)])
    }

    private func assertText(_ block: Block, _ expected: String) {
        guard case .paragraph(let inlines) = block else {
            Issue.record("expected paragraph: \(block)")
            return
        }
        #expect(inlinesToPlainText(inlines) == expected)
    }

    @Test func headingAttachmentsKeepSourceOrder() {
        var blocks: [Block] = []
        var runs = Runs()
        emitParagraph(
            .heading(level: 2, label: nil, base: .plain),
            [text("before"), .blocks([.rule]), text("after")],
            &blocks,
            &runs)
        guard blocks.count == 3,
            case .heading(_, _, let content) = blocks[0],
            case .rule = blocks[1]
        else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(inlinesToPlainText(content) == "before")
        assertText(blocks[2], "after")
    }

    @Test func listAttachmentsKeepSourceOrderInsideTheItem() {
        var blocks: [Block] = []
        var runs = Runs()
        emitParagraph(
            .listItem(
                ilvl: 0,
                key: ListKey(instance: 1, marker: .bullet),
                number: 0,
                label: nil),
            [text("before"), .blocks([.rule]), text("after")],
            &blocks,
            &runs)
        runs.flush(&blocks)
        guard blocks.count == 1, case .list(let list) = blocks[0] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        let item = list.items[0].blocks
        guard item.count == 3, case .rule = item[1] else {
            Issue.record("unexpected item: \(item)")
            return
        }
        assertText(item[0], "before")
        assertText(item[2], "after")
    }

    @Test func aBookmarkOnlyParagraphKeepsItsAnchor() {
        // `inlinesAreEmpty` is true of a lone anchor, but dropping the
        // paragraph would strip the target a link resolves against.
        var blocks: [Block] = []
        var runs = Runs()
        emitParagraph(
            .plain,
            [.inlines([.anchor("mark")])],
            &blocks,
            &runs)
        guard blocks.count == 1, case .paragraph(let inlines) = blocks[0] else {
            Issue.record("\(blocks)")
            return
        }
        guard inlines.count == 1, case .anchor = inlines[0] else {
            Issue.record("\(inlines)")
            return
        }
    }

    @Test func anEmptyListItemCarriesNoBlocks() {
        var blocks: [Block] = []
        var runs = Runs()
        emitParagraph(
            .listItem(
                ilvl: 0,
                key: ListKey(instance: 1, marker: .bullet),
                number: 0,
                label: nil),
            [],
            &blocks,
            &runs)
        runs.flush(&blocks)
        guard blocks.count == 1, case .list(let list) = blocks[0] else {
            Issue.record("\(blocks)")
            return
        }
        #expect(list.items[0].blocks.isEmpty, "\(list.items[0].blocks)")
    }

    @Test func attachmentsSplitStyledRunsInPlace() {
        var blocks: [Block] = []
        var runs = Runs()
        emitParagraph(
            .styled(.code),
            [text("before"), .blocks([.rule]), text("after")],
            &blocks,
            &runs)
        runs.flush(&blocks)
        guard blocks.count == 3,
            case .codeBlock(_, let before) = blocks[0],
            case .rule = blocks[1],
            case .codeBlock(_, let after) = blocks[2]
        else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(before == "before")
        #expect(after == "after")
    }
}
