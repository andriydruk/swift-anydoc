// Ported from src/shared/delta.rs tests.
import Testing
@testable import AnyDoc

@Suite struct DeltaTests {
    @Test func explicitOffBeatsInheritedOn() {
        let base = StyleDelta(bold: true)
        let child = StyleDelta(bold: false)
        #expect(base.merge(child).resolve() == .plain)
    }

    @Test func unsetInherits() {
        let base = StyleDelta(bold: true, italic: true)
        let child = StyleDelta(italic: false)
        let resolved = base.merge(child).resolve()
        #expect(resolved.bold && !resolved.italic)
    }
}
