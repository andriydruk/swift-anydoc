// Ported from src/shared/list.rs tests.
import Testing
@testable import AnyDoc

private func entry(
    _ level: Int, _ instance: UInt64, _ marker: MarkerKind, _ number: UInt64, _ text: String
) -> ListEntry {
    ListEntry(
        level: level,
        key: ListKey(instance: instance, marker: marker),
        number: number,
        label: nil,
        blocks: [.paragraph([.plain(text)])])
}

private func lists(_ entries: [ListEntry]) -> [Block] {
    buildLists(entries)
}

@Suite struct ListBuilderTests {
    @Test func contiguousNumbersStayOneList() throws {
        let out = lists([
            entry(0, 1, .decimal, 1, "a"),
            entry(0, 1, .decimal, 2, "b"),
        ])
        #expect(out.count == 1)
        guard case .list(let l) = out.first else {
            Issue.record("expected a list block")
            return
        }
        #expect(l.ordered)
        #expect(l.start == 1)
        #expect(l.items.count == 2)
    }

    @Test func restartSplitsWithNewStart() throws {
        let out = lists([
            entry(0, 1, .decimal, 1, "a"),
            entry(0, 1, .decimal, 10, "restarted"),
        ])
        #expect(out.count == 2)
        guard out.count == 2, case .list(let l) = out[1] else {
            Issue.record("expected a second list block")
            return
        }
        #expect(l.start == 10)
    }

    @Test func distinctInstancesSplit() {
        let out = lists([
            entry(0, 1, .decimal, 1, "a"),
            entry(0, 2, .decimal, 1, "b"),
        ])
        #expect(out.count == 2)
    }

    @Test func markerChangeSplits() throws {
        let out = lists([
            entry(0, 1, .decimal, 1, "a"),
            entry(0, 1, .bullet, 0, "b"),
        ])
        #expect(out.count == 2)
        guard out.count == 2, case .list(let l) = out[1] else {
            Issue.record("expected a second list block")
            return
        }
        #expect(!l.ordered)
    }

    @Test func nestingPreserved() throws {
        let out = lists([
            entry(0, 1, .decimal, 1, "outer"),
            entry(1, 1, .lowerRoman, 1, "inner"),
            entry(0, 1, .decimal, 2, "outer2"),
        ])
        #expect(out.count == 1)
        guard case .list(let l) = out.first else {
            Issue.record("expected a list block")
            return
        }
        #expect(l.items.count == 2)
        if case .list(let sub) = l.items.first?.blocks.last {
            #expect(sub.ordered)
        } else {
            Issue.record("expected a nested list in the first item")
        }
    }
}
