// Ported from src/shared/assets.rs tests.
import Testing
@testable import AnyDoc

@Suite struct AssetsTests {
    @Test func repeatedOriginPartsShareOneAsset() throws {
        var sink = AssetSink()
        let a = try sink.add(
            mediaType: "image/png", originPart: "media/one.png", bytes: [UInt8](repeating: 1, count: 64))
        let b = try sink.add(
            mediaType: "image/png", originPart: "media/one.png", bytes: [UInt8](repeating: 1, count: 64))
        #expect(a == b)
        #expect(sink.assets.count == 1)
        #expect(sink.total == 64, "repeated references must not re-count bytes")
    }

    @Test func repeatedReferencesCannotTripTheCap() throws {
        // Preload the counter to just under the cap (avoids large real
        // allocations, which would feed the R22 memory test's counter).
        var sink = AssetSink()
        sink.total = Limits.maxAssetTotalBytes - 10
        for _ in 0..<8 {
            _ = try sink.add(
                mediaType: "image/png", originPart: "media/big.png",
                bytes: [UInt8](repeating: 0, count: 8))
        }
    }

    @Test func crossingTheCapIsAHardError() {
        var sink = AssetSink()
        sink.total = Limits.maxAssetTotalBytes - 10
        do {
            _ = try sink.add(
                mediaType: "image/png", originPart: "media/big.png",
                bytes: [UInt8](repeating: 0, count: 11))
            Issue.record("expected a resource-limit error")
        } catch let error as ConvertError {
            guard case .resourceLimit(let limit, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(limit == "max_asset_total_bytes")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mediaTypesComeFromExtensions() {
        #expect(mediaTypeFor("word/media/image1.PNG") == "image/png")
        #expect(mediaTypeFor("a/b.jpeg") == "image/jpeg")
        #expect(mediaTypeFor("plain") == "application/octet-stream")
    }
}
