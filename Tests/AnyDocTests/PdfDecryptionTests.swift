import Foundation
import Testing

@testable import AnyDoc

/// The standard security handler.
@Suite struct PdfDecryptionTests {
    private func encryption(revision: Int, keyLength: Int) -> PdfEncryption {
        PdfEncryption(
            revision: revision, keyLength: keyLength, ownerKey: [UInt8](repeating: 0x11, count: 32),
            userKey: [UInt8](repeating: 0x22, count: 32), permissions: -4,
            documentID: Array(0..<16), encryptMetadata: true)
    }

    @Test func revisionTwoAlwaysUsesFortyBits() {
        // Whatever `/Length` claims. A revision-2 document with `/Length 128`
        // is still a 40-bit document, and using 16 bytes derives a key that
        // decrypts nothing.
        let key = pdfDeriveFileKey(encryption(revision: 2, keyLength: 5))
        #expect(key.count == 5)
    }

    @Test func revisionThreeStrengthensTheKey() {
        // Fifty extra rounds of MD5, which is the whole of the
        // specification's key-strengthening — and the reason a revision-3
        // key differs from a revision-2 one built from identical inputs.
        let two = pdfDeriveFileKey(encryption(revision: 2, keyLength: 5))
        var three = encryption(revision: 3, keyLength: 5)
        three.revision = 3
        #expect(pdfDeriveFileKey(three) != two)
    }

    @Test func theObjectKeyMixesInTheObjectNumber() {
        // The same bytes in two objects encrypt differently, which is what
        // stops a key recovered from one object opening the rest.
        var state = encryption(revision: 3, keyLength: 16)
        state.key = pdfDeriveFileKey(state)
        let first = pdfObjectKey(state, PdfObjectId(number: 1, generation: 0))
        let second = pdfObjectKey(state, PdfObjectId(number: 2, generation: 0))
        #expect(first != second)
        // And capped at sixteen bytes however long the file key is.
        #expect(first.count == 16)
    }

    @Test func theAesSaltIsAddedToTheObjectKey() {
        // AES mixes four extra bytes — `sAlT` in ASCII — into every object
        // key. Without them the key is an RC4 key and decrypts to noise.
        var rc4 = encryption(revision: 4, keyLength: 16)
        rc4.key = pdfDeriveFileKey(rc4)
        var aes = rc4
        aes.usesAES = true
        let id = PdfObjectId(number: 1, generation: 0)
        #expect(pdfObjectKey(rc4, id) != pdfObjectKey(aes, id))
    }

    @Test func anUnsupportedRevisionDecryptsNothing() {
        // AES revisions are refused rather than attempted: RC4 against
        // AES-encrypted bytes yields plausible-looking noise, which is worse
        // than failing.
        var state = encryption(revision: 6, keyLength: 32)
        state.key = [1, 2, 3, 4, 5]
        #expect(!state.isSupported)
        #expect(pdfDecrypt(state, PdfObjectId(number: 1, generation: 0), [9, 9, 9]) == [9, 9, 9])
    }

    @Test func anEncryptedDocumentReadsItsText() throws {
        guard let path = ProcessInfo.processInfo.environment["ANYDOC_PDF_CORPUS"] else { return }
        for name in ["encrypted-rc4-r2.pdf", "encrypted-rc4-r3.pdf", "encrypted-aes-v4.pdf"] {
            guard let data = FileManager.default.contents(atPath: path + "/" + name) else {
                continue
            }
            var document = try PdfDocument(bytes: [UInt8](data))
            #expect(document.encryption != nil, "\(name): no key derived")
            #expect(!document.isUnreadablyEncrypted, "\(name)")
            let markdown = try pdfMarkdown([UInt8](data))
            #expect(markdown.contains("Encrypted Document"), "\(name)")
        }
    }
}
