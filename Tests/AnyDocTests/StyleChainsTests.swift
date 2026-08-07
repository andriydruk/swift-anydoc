// Ported from src/shared/chain.rs tests.
import Testing
@testable import AnyDoc

@Suite struct StyleChainsTests {
    @Test func deepChainWalksToRoot() throws {
        let defs: [(String, Bool?)] = (0..<30).map { i in ("s\(i)", i == 0 ? true : nil) }
        var chains = StyleChains<Bool?>()
        for (i, (id, d)) in defs.enumerated() {
            let parent = i == 0 ? nil : defs[i - 1].0
            chains.insert(id, d, parent: parent)
        }
        let hit = try chains.walk("s29") { $0 }
        #expect(hit == true)
    }

    @Test func childSettingWinsOverParent() throws {
        var chains = StyleChains<Bool?>()
        chains.insert("base", true, parent: nil)
        chains.insert("kid", false, parent: "base")
        #expect(try chains.walk("kid") { $0 } == false)
    }

    @Test func cycleIsHardError() {
        var chains = StyleChains<Bool?>()
        chains.insert("a", nil, parent: "b")
        chains.insert("b", nil, parent: "a")
        #expect(throws: ConvertError.self) {
            try chains.walk("a") { $0 }
        }
    }

    @Test func danglingParentEndsTheWalk() throws {
        var chains = StyleChains<Bool?>()
        chains.insert("kid", true, parent: "ghost")
        #expect(try chains.walk("kid") { $0 } == true)
    }

    @Test func visitsEveryDefinitionWhenProbeNeverHits() throws {
        var chains = StyleChains<Bool?>()
        chains.insert("base", false, parent: nil)
        chains.insert("kid", true, parent: "base")
        var seen = 0
        let result: ()? = try chains.walk("kid") { _ in
            seen += 1
            return nil
        }
        #expect(result == nil)
        #expect(seen == 2)
    }
}
