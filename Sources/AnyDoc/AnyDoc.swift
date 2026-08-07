/// anydoc converts documents to GitHub-Flavored Markdown.
///
/// Pure-Swift port of [firecrawl/anydoc](https://github.com/firecrawl/anydoc):
/// each format parses into a shared document model and renders through a
/// single Markdown serializer, so output behaves identically no matter which
/// format goes in. The Rust crate is the executable specification — outputs
/// are validated byte-for-byte against it.
public enum AnyDoc {
    /// Convert a document file to Markdown. The format is detected from the
    /// file content (`Format.detect(from:)`); the extension is the fallback
    /// for signature-less formats (CSV) and unrecognizable containers.
    public static func markdown(contentsOf path: String) throws -> String {
        let bytes = try readFile(path)
        guard let format = Format.detect(from: bytes) ?? Format(path: path) else {
            throw ConvertError.unsupported("unrecognized file content and extension: \(path)")
        }
        return try markdown(bytes, format: format)
    }

    /// Convert an in-memory document to Markdown. Pass a `Format` to select
    /// the parser, or `nil` to detect it from the content, which
    /// signature-less formats (CSV) have to name explicitly.
    public static func markdown(_ bytes: [UInt8], format: Format? = nil) throws -> String {
        let format = try resolveFormat(bytes, format)
        // PDFs convert to Markdown directly without the document model.
        if format == .pdf {
            throw ConvertError.unsupported("PDF conversion is not implemented yet in swift-anydoc")
        }
        return documentToMarkdown(try document(bytes, format: format))
    }

    /// Parse an in-memory document into the document model. Pass a `Format`
    /// to select the parser, or `nil` to detect it from the content.
    ///
    /// Unsupported for `Format.pdf`: PDF conversion produces Markdown
    /// directly and has no document-model form; use `markdown(_:format:)`.
    public static func document(_ bytes: [UInt8], format: Format? = nil) throws -> Document {
        let format = try resolveFormat(bytes, format)
        switch format {
        case .csv:
            return try parseCsv(bytes)
        case .docx:
            return try parseDocx(bytes)
        case .pdf:
            throw ConvertError.unsupported("PDF has no document-model form")
        case .doc, .odt, .ppt, .pptx, .rtf, .epub, .excel, .ods, .odp:
            throw ConvertError.unsupported(
                "format \(format) is not implemented yet in swift-anydoc")
        }
    }

    private static func resolveFormat(_ bytes: [UInt8], _ format: Format?) throws -> Format {
        guard let format = format ?? Format.detect(from: bytes) else {
            throw ConvertError.unsupported(
                "unrecognized file content: name the format explicitly")
        }
        return format
    }
}
