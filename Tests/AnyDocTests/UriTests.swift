// Ported from src/shared/uri.rs tests.
import Testing
@testable import AnyDoc

@Suite struct UriTests {
    @Test func schemesFollowRfc3986() {
        #expect(hasScheme("https://e.com"))
        #expect(hasScheme("mailto:x@y"))
        #expect(hasScheme("a:relative-scheme-uri"), "one-character schemes are valid")
        #expect(hasScheme("view-source:x"))
        #expect(!hasScheme("1http:x"), "schemes must start with a letter")
        #expect(!hasScheme("no scheme here"))
        #expect(!hasScheme(":empty"))
        #expect(!hasScheme("path/with:colon"), "slash before the colon is not a scheme")
    }

    @Test func drivePathsAreNotUris() {
        #expect(isDrivePath(#"C:\docs\a.doc"#))
        #expect(isDrivePath("c:/docs/a.doc"))
        #expect(!isDrivePath("cs:whatever"))
        #expect(!isAbsoluteUri(#"C:\docs\a.doc"#))
        #expect(isAbsoluteUri("https://e.com"))
    }
}
